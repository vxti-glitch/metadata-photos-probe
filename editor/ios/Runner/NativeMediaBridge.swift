import Flutter
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import ProbeCore
import CoreFoundation
import MapKit
import Darwin

/// A canceled operation retains its lease until the real OS/engine completion.
/// Token checks also make late picker callbacks harmless after dismissal.
@MainActor
final class NativeOperationGate {
    private(set) var token: UUID?
    private(set) var canceled = false
    var busy: Bool { token != nil }
    func begin() throws -> UUID {
        guard token == nil else { throw NativeMediaError.busy }
        let fresh = UUID(); token = fresh; canceled = false
        return fresh
    }
    func requestCancellation() { if token != nil { canceled = true } }
    func isCurrent(_ candidate: UUID) -> Bool { token == candidate }
    @discardableResult func finish(_ candidate: UUID) -> Bool {
        guard token == candidate else { return false }
        token = nil; canceled = false
        return true
    }
}

@MainActor
final class NativeMediaBridge: NSObject {
    private let channel: FlutterMethodChannel
    private let store: NativeSessionStore
    private let gate = NativeOperationGate()
    private var pendingResult: FlutterResult?
    private var task: Task<Void, Never>?
    private var pickerDelegate: NativePickerDelegate?
    private weak var presentedPicker: UIViewController?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.vxtiglitch.metadataeditor/media_v1", binaryMessenger: messenger)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        store = NativeSessionStore(root: support.appendingPathComponent("NativeMediaSessions", isDirectory: true),
            previewRoot: cache.appendingPathComponent("NativeMediaPreviews", isDirectory: true),
            autoExportRoot: documents.appendingPathComponent("Processed Media", isDirectory: true))
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(FlutterError(code: "storage", message: "Native media service is unavailable.", details: nil)); return }
            self.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            switch call.method {
            case "capabilities":
                let fields = Dictionary(uniqueKeysWithValues: MediaKind.allCases.map { ($0.rawValue, MetadataPatch.supportedKeys(for: $0).sorted()) })
                result(["protocolVersion": 1, "formats": MediaKind.allCases.map(\.rawValue),
                        "editableFields": Array(Set(fields.values.flatMap { $0 })).sorted(),
                        "editableFieldsByFormat": fields, "videoStatus": "device-validation-required"])
            case "listSessions":
                Task {
                    do { result(try await store.bridgeList()) }
                    catch { result(Self.flutterError(error)) }
                }
            case "importFiles": try presentFiles(result: result)
            case "importPhotos": try presentPhotos(result: result)
            case "importFilesBatch": try presentFiles(result: result, batch: true)
            case "importPhotosBatch": try presentPhotos(result: result, batch: true)
            case "loadEditorState":
                Task { do { result(try await store.loadEditorState()) } catch { result(Self.flutterError(error)) } }
            case "saveEditorState":
                let arguments = try Self.arguments(call.arguments)
                guard let state = arguments["state"] as? [String: Any] else { throw NativeMediaError.invalidArgument }
                try NativeSessionStore.validateEditorState(state)
                try perform(result: result) { try await self.store.saveEditorState(state); return nil }
            case "importPreset": try presentPresetImport(result: result)
            case "exportPreset":
                let arguments = try Self.arguments(call.arguments)
                guard let preset = arguments["preset"] as? [String: Any] else { throw NativeMediaError.invalidArgument }
                try NativeSessionStore.validatePreset(preset)
                let token = try start(result)
                task = Task {
                    do {
                        let url = try await store.presetExportURL(preset)
                        try Task.checkCancellation()
                        try presentExport(urls: [url], token: token); task = nil
                    } catch { finish(token, value: Self.flutterError(error)) }
                }
            case "processMetadata":
                let arguments = try Self.arguments(call.arguments)
                let id = try Self.identifier(arguments, "sessionId")
                let patch = try Self.metadataPatch(arguments)
                try perform(result: result) {
                    let session = try await self.store.processMetadata(sessionID: id, patch: patch)
                    return try await self.store.bridgeMap(session)
                }
            case "verifyOriginal":
                let arguments = try Self.arguments(call.arguments)
                let id = try Self.identifier(arguments, "sessionId")
                let processingID = try Self.identifier(arguments, "processingId")
                try presentVerification(sessionID: id, processingID: processingID, result: result)
            case "process":
                let arguments = try Self.arguments(call.arguments)
                let id = try Self.identifier(arguments, "sessionId")
                let patch = try Self.patch(arguments)
                try perform(result: result) {
                    let session = try await self.store.process(sessionID: id, patch: patch)
                    return try await self.store.bridgeMap(session)
                }
            case "exportFiles":
                let arguments = try Self.arguments(call.arguments)
                let id = try Self.identifier(arguments, "sessionId")
                let processingID = try Self.identifier(arguments, "processingId")
                guard let raw = arguments["acknowledgeIncomplete"] as? NSNumber,
                      CFGetTypeID(raw) == CFBooleanGetTypeID() else { throw NativeMediaError.invalidArgument }
                let acknowledgement = raw.boolValue
                let token = try start(result)
                task = Task {
                    do {
                        let url = try await store.exportCopyURL(sessionID: id, processingID: processingID, acknowledgeIncomplete: acknowledgement)
                        try Task.checkCancellation()
                        guard gate.isCurrent(token), !gate.canceled else { throw NativeMediaError.canceled }
                        try presentExport(urls: [url], token: token)
                        task = nil
                    } catch { finish(token, value: Self.flutterError(error)) }
                }
            case "exportFilesBatch":
                let arguments = try Self.arguments(call.arguments)
                let parsed = try Self.parseBatchItems(arguments)
                let token = try start(result)
                task = Task {
                    do {
                        var urls: [URL] = []
                        for (id, output, acknowledgment) in parsed {
                            try Task.checkCancellation()
                            urls.append(try await store.exportCopyURL(sessionID: id, processingID: output, acknowledgeIncomplete: acknowledgment))
                        }
                        try Task.checkCancellation()
                        guard gate.isCurrent(token), !gate.canceled else { throw NativeMediaError.canceled }
                        try presentExport(urls: urls, token: token); task = nil
                    } catch { finish(token, value: Self.flutterError(error)) }
                }
            case "shareFiles":
                let arguments = try Self.arguments(call.arguments)
                let id = try Self.identifier(arguments, "sessionId")
                let processingID = try Self.identifier(arguments, "processingId")
                guard let raw = arguments["acknowledgeIncomplete"] as? NSNumber,
                      CFGetTypeID(raw) == CFBooleanGetTypeID() else { throw NativeMediaError.invalidArgument }
                let acknowledgement = raw.boolValue
                let token = try start(result)
                task = Task {
                    do {
                        let url = try await store.exportCopyURL(sessionID: id, processingID: processingID, acknowledgeIncomplete: acknowledgement)
                        try Task.checkCancellation()
                        guard gate.isCurrent(token), !gate.canceled else { throw NativeMediaError.canceled }
                        try presentShare(urls: [url], token: token)
                        task = nil
                    } catch { finish(token, value: Self.flutterError(error)) }
                }
            case "shareFilesBatch":
                let arguments = try Self.arguments(call.arguments)
                let parsed = try Self.parseBatchItems(arguments)
                let token = try start(result)
                task = Task {
                    do {
                        var urls: [URL] = []
                        for (id, output, acknowledgment) in parsed {
                            try Task.checkCancellation()
                            urls.append(try await store.exportCopyURL(sessionID: id, processingID: output, acknowledgeIncomplete: acknowledgment))
                        }
                        try Task.checkCancellation()
                        guard gate.isCurrent(token), !gate.canceled else { throw NativeMediaError.canceled }
                        try presentShare(urls: urls, token: token); task = nil
                    } catch { finish(token, value: Self.flutterError(error)) }
                }
            case "cancel":
                gate.requestCancellation(); task?.cancel()
                // Dismiss only a waiting picker. Once extraction/processing is
                // underway, cancellation waits for its true native completion.
                if task == nil, let picker = presentedPicker, let token = gate.token {
                    picker.dismiss(animated: true) { self.finish(token, value: FlutterError(code: "canceled", message: "Operation canceled.", details: nil)) }
                }
                result(nil)
            case "deleteSession":
                let id = try Self.identifier(Self.arguments(call.arguments), "sessionId")
                try perform(result: result) { try await self.store.delete(id); return nil }
            case "clearSessions":
                try perform(result: result) { try await self.store.clear(); return nil }
            case "openICloud":
                guard !gate.busy else { throw NativeMediaError.busy }
                UIApplication.shared.open(URL(string: "https://www.icloud.com/photos/")!, options: [:]) { opened in
                    result(opened ? nil : FlutterError(code: "unsupported", message: "Safari could not open iCloud Photos.", details: nil))
                }
            case "openUrl":
                guard !gate.busy else { throw NativeMediaError.busy }
                let rawUrl = try Self.string(Self.arguments(call.arguments), "url")
                guard let url = URL(string: rawUrl), url.scheme?.lowercased() == "https" else {
                    throw NativeMediaError.unsupported("Only secure web links can be opened.")
                }
                UIApplication.shared.open(url, options: [:]) { opened in
                    result(opened ? nil : FlutterError(code: "unsupported", message: "Could not open URL.", details: nil))
                }
            case "openLocationPicker":
                guard !gate.busy else { throw NativeMediaError.busy }
                let args = (call.arguments as? [String: Any]) ?? [:]
                let initialLat = (args["latitude"] as? NSNumber)?.doubleValue
                let initialLng = (args["longitude"] as? NSNumber)?.doubleValue
                try presentLocationPicker(initialLat: initialLat, initialLng: initialLng, result: result)
            case "getHostDevice":
                result(Self.detectHostDevice())
            default: result(FlutterMethodNotImplemented)
            }
        } catch { result(Self.flutterError(error)) }
    }

    private func start(_ result: @escaping FlutterResult) throws -> UUID {
        let token = try gate.begin()
        pendingResult = result
        return token
    }

    private func perform(result: @escaping FlutterResult, operation: @escaping @MainActor () async throws -> Any?) throws {
        let token = try start(result)
        task = Task {
            do {
                let value = try await operation()
                // A completed journal deletion is reported even if cancellation
                // arrived during it; imports/process explicitly check before commit.
                finish(token, value: value)
            } catch { finish(token, value: Self.flutterError(error)) }
        }
    }

    private func finish(_ token: UUID, value: Any?) {
        guard gate.finish(token) else { return }
        let completion = pendingResult
        pendingResult = nil; task = nil; pickerDelegate = nil; presentedPicker = nil
        completion?(value)
    }

    private func presenter() throws -> UIViewController {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow),
              var controller = window.rootViewController else { throw NativeMediaError.unsupported("The app has no active presentation window.") }
        while let next = controller.presentedViewController { controller = next }
        guard !controller.isBeingDismissed, !controller.isBeingPresented else { throw NativeMediaError.busy }
        return controller
    }

    private func presentFiles(result: @escaping FlutterResult, batch: Bool = false) throws {
        let controller = try presenter()
        let token = try start(result)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.jpeg, .heic, .png, .mpeg4Movie, .quickTimeMovie], asCopy: false)
        picker.allowsMultipleSelection = batch
        let delegate = NativePickerDelegate(token: token)
        delegate.onFiles = { [weak self, weak picker] token, urls in
            guard let self, self.gate.isCurrent(token), !self.gate.canceled else { return }
            guard !urls.isEmpty, urls.count <= (batch ? 50 : 1) else { self.finish(token, value: Self.flutterError(NativeMediaError.unsupported("Select up to 50 files per import."))); return }
            picker?.dismiss(animated: true)
            self.presentedPicker = nil
            self.task = Task {
                do {
                    if batch {
                        var sessions: [[String: Any]] = [], errors: [[String: String]] = []
                        for url in urls {
                            if Task.isCancelled || self.gate.canceled { break }
                            do {
                                let session = try await self.store.importFile(url)
                                sessions.append(try await self.store.bridgeMap(session))
                            } catch {
                                if error is CancellationError { break }
                                errors.append(["name": String(url.lastPathComponent.prefix(256)), "message": Self.flutterError(error).message ?? "Import failed."])
                            }
                        }
                        self.finish(token, value: ["sessions": sessions, "errors": errors, "canceled": Task.isCancelled || self.gate.canceled])
                        return
                    }
                    let session = try await self.store.importFile(urls[0])
                    self.finish(token, value: try await self.store.bridgeMap(session))
                } catch { self.finish(token, value: Self.flutterError(error)) }
            }
        }
        delegate.onCancel = { [weak self] token in self?.finish(token, value: batch ? ["sessions": [], "errors": [], "canceled": true] : nil) }
        picker.delegate = delegate; pickerDelegate = delegate; presentedPicker = picker
        picker.presentationController?.delegate = delegate
        controller.present(picker, animated: true)
        picker.presentationController?.delegate = delegate
    }

    private func presentPhotos(result: @escaping FlutterResult, batch: Bool = false) throws {
        _ = try presenter()
        let token = try start(result)
        task = Task {
            do {
                var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if authorization == .notDetermined { authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                try Task.checkCancellation()
                guard authorization == .authorized || authorization == .limited else { throw NativeMediaError.permission }
                var configuration = PHPickerConfiguration(photoLibrary: .shared())
                configuration.selectionLimit = batch ? 50 : 1
                configuration.selection = .ordered
                configuration.filter = .any(of: [.images, .videos])
                configuration.preferredAssetRepresentationMode = .current
                let picker = PHPickerViewController(configuration: configuration)
                let delegate = NativePickerDelegate(token: token)
                delegate.onPhotos = { [weak self, weak picker] token, results in
                    guard let self, self.gate.isCurrent(token), !self.gate.canceled else { return }
                    picker?.dismiss(animated: true); self.presentedPicker = nil
                    if batch {
                        self.task = Task {
                            var sessions: [[String: Any]] = [], errors: [[String: String]] = []
                            for selected in results {
                                if Task.isCancelled || self.gate.canceled { break }
                                do {
                                    let resource = try Self.originalResource(selected)
                                    let session = try await self.store.importPhotoResource(resource)
                                    sessions.append(try await self.store.bridgeMap(session))
                                } catch {
                                    if error is CancellationError { break }
                                    errors.append(["name": "Selected Photos item", "message": Self.flutterError(error).message ?? "Import failed."])
                                }
                            }
                            self.finish(token, value: ["sessions": sessions, "errors": errors, "canceled": results.isEmpty || Task.isCancelled || self.gate.canceled])
                        }
                        return
                    }
                    guard !results.isEmpty else { self.finish(token, value: nil); return }
                    guard results.count == 1, let identifier = results[0].assetIdentifier,
                          let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                        self.finish(token, value: Self.flutterError(NativeMediaError.permission)); return
                    }
                    guard !asset.mediaSubtypes.contains(.photoLive) else {
                        self.finish(token, value: Self.flutterError(NativeMediaError.unsupported("Live Photos are outside this editor's scope."))); return
                    }
                    let resourceType: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
                    let originals = PHAssetResource.assetResources(for: asset).filter { $0.type == resourceType }
                    guard originals.count == 1, let original = originals.first else {
                        self.finish(token, value: Self.flutterError(NativeMediaError.unsupported("A unique original Photos resource is required."))); return
                    }
                    self.task = Task {
                        do {
                            let session = try await self.store.importPhotoResource(original)
                            self.finish(token, value: try await self.store.bridgeMap(session))
                        } catch { self.finish(token, value: Self.flutterError(error)) }
                    }
                }
                delegate.onCancel = { [weak self] token in self?.finish(token, value: batch ? ["sessions": [], "errors": [], "canceled": true] : nil) }
                picker.delegate = delegate
                pickerDelegate = delegate; presentedPicker = picker
                try presenter().present(picker, animated: true)
                picker.presentationController?.delegate = delegate
                task = nil
            } catch { finish(token, value: Self.flutterError(error)) }
        }
    }

    private func presentExport(urls: [URL], token: UUID) throws {
        let controller = try presenter()
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        let delegate = NativePickerDelegate(token: token)
        delegate.onFiles = { [weak self] token, urls in
            guard let self, self.gate.isCurrent(token) else { return }
            self.finish(token, value: ["completed": !urls.isEmpty])
        }
        delegate.onCancel = { [weak self] token in self?.finish(token, value: ["completed": false]) }
        picker.delegate = delegate; pickerDelegate = delegate; presentedPicker = picker
        controller.present(picker, animated: true)
        picker.presentationController?.delegate = delegate
    }

    private func presentShare(urls: [URL], token: UUID) throws {
        let controller = try presenter()
        let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        activity.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            guard let self, self.gate.isCurrent(token) else { return }
            self.finish(token, value: ["completed": completed])
        }
        presentedPicker = activity
        controller.present(activity, animated: true)
    }

    private func presentLocationPicker(initialLat: Double?, initialLng: Double?, result: @escaping FlutterResult) throws {
        let controller = try presenter()
        let token = try start(result)
        let pickerVC = LocationPickerViewController(initialLat: initialLat, initialLng: initialLng) { [weak self] coord in
            guard let self, self.gate.isCurrent(token) else { return }
            if let c = coord {
                self.finish(token, value: ["latitude": c.latitude, "longitude": c.longitude])
            } else {
                self.finish(token, value: nil)
            }
        }
        let nav = UINavigationController(rootViewController: pickerVC)
        let delegate = NativePickerDelegate(token: token)
        delegate.onCancel = { [weak self] token in self?.finish(token, value: nil) }
        pickerDelegate = delegate
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presentedPicker = nav
        controller.present(nav, animated: true)
        nav.presentationController?.delegate = delegate
    }

    static func arguments(_ value: Any?) throws -> [String: Any] {
        guard let map = value as? [String: Any] else { throw NativeMediaError.invalidArgument }
        return map
    }

    static func metadataPatch(_ arguments: [String: Any]) throws -> MetadataPatch {
        guard let map = arguments["patch"] as? [String: Any],
              Set(map.keys) == Set(["values", "removals"]) else { throw NativeMediaError.invalidArgument }
        do {
            let data = try JSONSerialization.data(withJSONObject: map)
            guard data.count <= 16_384 else { throw NativeMediaError.invalidArgument }
            let patch = try JSONDecoder().decode(MetadataPatch.self, from: data)
            try patch.validate()
            return patch
        } catch { throw NativeMediaError.invalidArgument }
    }

    static func parseBatchItems(_ arguments: [String: Any]) throws -> [(id: UUID, output: UUID, acknowledged: Bool)] {
        guard let items = arguments["items"] as? [[String: Any]], !items.isEmpty, items.count <= 100 else {
            throw NativeMediaError.invalidArgument
        }
        let parsed = try items.map { item -> (id: UUID, output: UUID, acknowledged: Bool) in
            let id = try Self.identifier(item, "sessionId"), output = try Self.identifier(item, "processingId")
            guard let raw = item["acknowledgeIncomplete"] as? NSNumber,
                  CFGetTypeID(raw) == CFBooleanGetTypeID() else { throw NativeMediaError.invalidArgument }
            return (id, output, raw.boolValue)
        }
        guard Set(parsed.map { $0.id }).count == parsed.count else { throw NativeMediaError.invalidArgument }
        return parsed
    }

    private static func originalResource(_ selected: PHPickerResult) throws -> PHAssetResource {
        guard let identifier = selected.assetIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { throw NativeMediaError.permission }
        guard !asset.mediaSubtypes.contains(.photoLive) else { throw NativeMediaError.unsupported("Live Photos are outside this editor's scope. Choose a still image with Live turned off.") }
        guard asset.mediaType == .image || asset.mediaType == .video else { throw NativeMediaError.unsupported("Choose a photo or video.") }
        let type: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        let resources = PHAssetResource.assetResources(for: asset).filter { $0.type == type }
        guard resources.count == 1, let resource = resources.first else { throw NativeMediaError.unsupported("A unique original Photos resource is required.") }
        return resource
    }

    private func presentPresetImport(result: @escaping FlutterResult) throws {
        try presentSingleFile(types: [.json], result: result) { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?, readError: Error?, preset: [String: Any]?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { selected in
                do {
                    try NativeSessionStore.requireRegularFile(selected, maximumBytes: 32_768)
                    guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: selected)) as? [String: Any] else { throw NativeMediaError.invalidArgument }
                    try NativeSessionStore.validatePreset(parsed); preset = parsed
                } catch { readError = error }
            }
            guard coordinationError == nil, readError == nil, let preset else { throw NativeMediaError.invalidArgument }
            try Task.checkCancellation()
            return preset
        }
    }

    private func presentVerification(sessionID: UUID, processingID: UUID, result: @escaping FlutterResult) throws {
        try presentSingleFile(types: [.jpeg, .heic, .png, .mpeg4Movie, .quickTimeMovie], result: result) { url in
            try await self.store.verifyOriginal(sessionID: sessionID, processingID: processingID, providerURL: url)
        }
    }

    private func presentSingleFile(types: [UTType], result: @escaping FlutterResult,
                                   operation: @escaping @MainActor (URL) async throws -> Any?) throws {
        let controller = try presenter(), token = try start(result)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        let delegate = NativePickerDelegate(token: token)
        delegate.onFiles = { [weak self, weak picker] token, urls in
            guard let self, self.gate.isCurrent(token), !self.gate.canceled else { return }
            picker?.dismiss(animated: true); self.presentedPicker = nil
            guard urls.count == 1 else { self.finish(token, value: Self.flutterError(NativeMediaError.invalidArgument)); return }
            self.task = Task {
                do {
                    let value = try await operation(urls[0]); try Task.checkCancellation()
                    self.finish(token, value: value)
                } catch { self.finish(token, value: Self.flutterError(error)) }
            }
        }
        delegate.onCancel = { [weak self] token in self?.finish(token, value: nil) }
        picker.delegate = delegate; pickerDelegate = delegate; presentedPicker = picker
        controller.present(picker, animated: true); picker.presentationController?.delegate = delegate
    }

    static func identifier(_ map: [String: Any], _ key: String) throws -> UUID {
        guard let raw = map[key] as? String, let id = UUID(uuidString: raw) else { throw NativeMediaError.invalidArgument }
        return id
    }

    static func string(_ map: [String: Any], _ key: String) throws -> String {
        guard let raw = map[key] as? String, !raw.isEmpty else { throw NativeMediaError.invalidArgument }
        return raw
    }

    static func patch(_ arguments: [String: Any]) throws -> CameraPatch {
        guard let map = arguments["patch"] as? [String: Any], let make = map["make"] as? String,
              let model = map["model"] as? String else { throw NativeMediaError.invalidArgument }
        let lens: String?
        if let value = map["lens"], !(value is NSNull) {
            guard let text = value as? String else { throw NativeMediaError.invalidArgument }
            lens = text.isEmpty ? nil : text
        } else { lens = nil }
        let patch = CameraPatch(make: make, model: model, lens: lens)
        try patch.validate()
        return patch
    }

    static func detectHostDevice() -> [String: String] {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        var identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        #if targetEnvironment(simulator)
        if let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simModel.isEmpty {
            identifier = simModel
        }
        #endif
        return hostDevice(identifier: identifier)
    }

    static func hostDevice(identifier: String) -> [String: String] {
        let mapping: [String: (profileId: String, model: String)] = [
            "iPhone12,1": ("apple-iphone-11", "iPhone 11"),
            "iPhone12,3": ("apple-iphone-11-pro", "iPhone 11 Pro"),
            "iPhone12,5": ("apple-iphone-11-pro-max", "iPhone 11 Pro Max"),
            "iPhone12,8": ("apple-iphone-se-2nd-generation", "iPhone SE (2nd generation)"),
            "iPhone13,1": ("apple-iphone-12-mini", "iPhone 12 mini"),
            "iPhone13,2": ("apple-iphone-12", "iPhone 12"),
            "iPhone13,3": ("apple-iphone-12-pro", "iPhone 12 Pro"),
            "iPhone13,4": ("apple-iphone-12-pro-max", "iPhone 12 Pro Max"),
            "iPhone14,2": ("apple-iphone-13-pro", "iPhone 13 Pro"),
            "iPhone14,3": ("apple-iphone-13-pro-max", "iPhone 13 Pro Max"),
            "iPhone14,4": ("apple-iphone-13-mini", "iPhone 13 mini"),
            "iPhone14,5": ("apple-iphone-13", "iPhone 13"),
            "iPhone14,6": ("apple-iphone-se-3rd-generation", "iPhone SE (3rd generation)"),
            "iPhone14,7": ("apple-iphone-14", "iPhone 14"),
            "iPhone14,8": ("apple-iphone-14-plus", "iPhone 14 Plus"),
            "iPhone15,2": ("apple-iphone-14-pro", "iPhone 14 Pro"),
            "iPhone15,3": ("apple-iphone-14-pro-max", "iPhone 14 Pro Max"),
            "iPhone15,4": ("apple-iphone-15", "iPhone 15"),
            "iPhone15,5": ("apple-iphone-15-plus", "iPhone 15 Plus"),
            "iPhone16,1": ("apple-iphone-15-pro", "iPhone 15 Pro"),
            "iPhone16,2": ("apple-iphone-15-pro-max", "iPhone 15 Pro Max"),
            "iPhone17,1": ("apple-iphone-16-pro", "iPhone 16 Pro"),
            "iPhone17,2": ("apple-iphone-16-pro-max", "iPhone 16 Pro Max"),
            "iPhone17,3": ("apple-iphone-16", "iPhone 16"),
            "iPhone17,4": ("apple-iphone-16-plus", "iPhone 16 Plus"),
            "iPhone17,5": ("apple-iphone-16e", "iPhone 16e"),
        ]
        var result = ["brand": "Apple", "model": "iPhone", "hardware": identifier]
        if let matched = mapping[identifier] { result["profileId"] = matched.profileId; result["model"] = matched.model }
        return result
    }

    static func flutterError(_ error: Error) -> FlutterError {
        let code: String, message: String
        if error is CancellationError { return FlutterError(code: "canceled", message: "Operation canceled.", details: nil) }
        switch error {
        case NativeMediaError.busy: code = "busy"; message = "Wait for the current native operation to finish."
        case NativeMediaError.canceled: code = "canceled"; message = "Operation canceled."
        case NativeMediaError.permission: code = "permission"; message = "Allow Photos access to retrieve the selected original resource."
        case NativeMediaError.invalidArgument, ProbeError.invalidPatch: code = "invalid_argument"; message = "Check the selected metadata values and current file."
        case NativeMediaError.notFound: code = "not_found"; message = "The selected session or current processed output is unavailable."
        case NativeMediaError.storage: code = "storage"; message = "The local media copy or session journal could not be accessed safely."
        case NativeMediaError.unsupported(let detail): code = "unsupported"; message = Self.safeUnsupportedMessage(detail)
        case ProbeError.unsupported(let detail): code = "unsupported"; message = Self.safeUnsupportedMessage(detail)
        case ProbeError.malformed: code = "malformed"; message = "The file contains damaged or inconsistent media data. Try its original version."
        case ProbeError.outputExists: code = "storage"; message = "The output copy already exists. Retry processing to create a new copy."
        case ProbeError.sameFile: code = "invalid_argument"; message = "Source and output must be different files."
        case ProbeError.writeFailed: code = "processing"; message = "The metadata writer could not finish creating the edited copy. No new output is available."
        case ProbeError.readbackFailed: code = "readback"; message = "The edited metadata could not be read back as requested. No new output is available."
        case ProbeError.integrityMismatch: code = "integrity"; message = "The edited copy failed media preservation checks. No new output is available."
        default:
            let native = error as NSError
            if native.domain == NSCocoaErrorDomain {
                code = "storage"; message = "The local file could not be read or written. Check available storage and try again."
            } else if native.domain == "PHPhotosErrorDomain" {
                code = "storage"; message = "The selected Photos original could not be retrieved. Check Photos access and its iCloud download."
            } else {
                code = "processing"; message = "Native media processing failed. Retry with the original file. No new output is available."
            }
        }
        // Error descriptions and userInfo may embed filenames, filesystem URLs
        // and metadata. Expose only fixed stage tokens and known numeric codes.
        var diagnostics: [String: Any] = ["stage": code]
        if !(error is NativeMediaError), !(error is ProbeError) {
            let native = error as NSError
            let domains = [NSCocoaErrorDomain, NSOSStatusErrorDomain, "AVFoundationErrorDomain", "PHPhotosErrorDomain"]
            diagnostics["nativeDomain"] = domains.contains(native.domain) ? native.domain : "other"
            diagnostics["nativeCode"] = native.code
        }
        return FlutterError(code: code, message: message, details: diagnostics)
    }

    private static func safeUnsupportedMessage(_ detail: String) -> String {
        // Match known causes without returning interpolated file content.
        if detail.contains("incomplete integrity") { return "Review and acknowledge the incomplete integrity checks before export." }
        if detail.contains("Live Photos") { return "Choose a still image with Live turned off; Live Photos are unsupported." }
        if detail.contains("time zone") { return "Video dates require an explicit time zone. Check the date and time settings." }
        if detail.contains("fragmented") || detail.contains("movie brand") || detail.contains("movie atoms") {
            return "This video's container layout is not supported for lossless metadata editing. Try another original MP4 or MOV."
        }
        if detail.contains("removal") || detail.contains("Removal") || detail.contains("Scrubbing") || detail.contains("location editing") {
            return "This file contains additional metadata that prevents safe removal of the selected fields. Change the edit selection and retry."
        }
        if detail.contains("lens editing") || detail.contains("metadata representation") { return "One or more selected fields are unsupported for this media format." }
        if detail.contains("budget") || detail.contains("exceeds") { return "This file's metadata exceeds the supported processing limits." }
        return "The selected file or operation is unsupported. Try another original JPEG, HEIC, PNG, MP4 or MOV."
    }
}

@MainActor
private final class NativePickerDelegate: NSObject, UIDocumentPickerDelegate, PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    let token: UUID
    var onFiles: ((UUID, [URL]) -> Void)?
    var onPhotos: ((UUID, [PHPickerResult]) -> Void)?
    var onCancel: ((UUID) -> Void)?
    private var completed = false
    init(token: UUID) { self.token = token }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !completed else { return }; completed = true; onFiles?(token, urls)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancel() }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard !completed else { return }; completed = true; onPhotos?(token, results)
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { cancel() }
    private func cancel() { guard !completed else { return }; completed = true; onCancel?(token) }
}

@MainActor
final class LocationPickerViewController: UIViewController, MKMapViewDelegate {
    private let initialLat: Double?
    private let initialLng: Double?
    private let onSelect: (CLLocationCoordinate2D?) -> Void
    private var mapView: MKMapView!
    private var annotation: MKPointAnnotation?

    init(initialLat: Double?, initialLng: Double?, onSelect: @escaping (CLLocationCoordinate2D?) -> Void) {
        self.initialLat = initialLat
        self.initialLng = initialLng
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Select Location"
        view.backgroundColor = UIColor(red: 0x12/255.0, green: 0x12/255.0, blue: 0x14/255.0, alpha: 1.0)

        mapView = MKMapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        view.addSubview(mapView)

        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        mapView.addGestureRecognizer(gesture)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        mapView.addGestureRecognizer(tap)

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Apply", style: .done, target: self, action: #selector(applyTapped))

        if let lat = initialLat, let lng = initialLng, abs(lat) <= 90, abs(lng) <= 180 {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            setPin(at: coord)
            mapView.setRegion(MKCoordinateRegion(center: coord, latitudinalMeters: 2000, longitudinalMeters: 2000), animated: false)
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true) { self.onSelect(nil) }
    }

    @objc private func applyTapped() {
        let coord = annotation?.coordinate ?? mapView.centerCoordinate
        dismiss(animated: true) { self.onSelect(coord) }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended {
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            setPin(at: coord)
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            setPin(at: coord)
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }

    private func setPin(at coord: CLLocationCoordinate2D) {
        if let existing = annotation {
            existing.coordinate = coord
        } else {
            let pin = MKPointAnnotation()
            pin.coordinate = coord
            pin.title = "Target Location"
            mapView.addAnnotation(pin)
            annotation = pin
        }
    }
}
