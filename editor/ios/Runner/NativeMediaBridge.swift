import Flutter
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import ProbeCore
import CoreFoundation

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
        store = NativeSessionStore(root: support.appendingPathComponent("NativeMediaSessions", isDirectory: true),
            previewRoot: cache.appendingPathComponent("NativeMediaPreviews", isDirectory: true))
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
                result(["protocolVersion": 1, "formats": ["jpeg", "heic", "mp4", "mov"],
                        "editableFields": ["make", "model", "lens"], "videoStatus": "provisional"])
            case "listSessions":
                Task {
                    do { result(try await store.bridgeList()) }
                    catch { result(Self.flutterError(error)) }
                }
            case "importFiles": try presentFiles(result: result)
            case "importPhotos": try presentPhotos(result: result)
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
                        let url = try await store.exportURL(sessionID: id, processingID: processingID, acknowledgeIncomplete: acknowledgement)
                        try Task.checkCancellation()
                        guard gate.isCurrent(token), !gate.canceled else { throw NativeMediaError.canceled }
                        try presentExport(url: url, token: token)
                        task = nil
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

    private func presentFiles(result: @escaping FlutterResult) throws {
        let controller = try presenter()
        let token = try start(result)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.jpeg, .heic, .mpeg4Movie, .quickTimeMovie], asCopy: false)
        picker.allowsMultipleSelection = false
        let delegate = NativePickerDelegate(token: token)
        delegate.onFiles = { [weak self, weak picker] token, urls in
            guard let self, self.gate.isCurrent(token), !self.gate.canceled else { return }
            guard urls.count == 1 else { self.finish(token, value: Self.flutterError(NativeMediaError.invalidArgument)); return }
            picker?.dismiss(animated: true)
            self.presentedPicker = nil
            self.task = Task {
                do {
                    let session = try await self.store.importFile(urls[0])
                    self.finish(token, value: try await self.store.bridgeMap(session))
                } catch { self.finish(token, value: Self.flutterError(error)) }
            }
        }
        delegate.onCancel = { [weak self] token in self?.finish(token, value: nil) }
        picker.delegate = delegate; pickerDelegate = delegate; presentedPicker = picker
        picker.presentationController?.delegate = delegate
        controller.present(picker, animated: true)
        picker.presentationController?.delegate = delegate
    }

    private func presentPhotos(result: @escaping FlutterResult) throws {
        _ = try presenter()
        let token = try start(result)
        task = Task {
            do {
                var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if authorization == .notDetermined { authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                try Task.checkCancellation()
                guard authorization == .authorized || authorization == .limited else { throw NativeMediaError.permission }
                var configuration = PHPickerConfiguration(photoLibrary: .shared())
                configuration.selectionLimit = 1
                configuration.filter = .any(of: [.images, .videos])
                configuration.preferredAssetRepresentationMode = .current
                let picker = PHPickerViewController(configuration: configuration)
                let delegate = NativePickerDelegate(token: token)
                delegate.onPhotos = { [weak self, weak picker] token, results in
                    guard let self, self.gate.isCurrent(token), !self.gate.canceled else { return }
                    picker?.dismiss(animated: true); self.presentedPicker = nil
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
                delegate.onCancel = { [weak self] token in self?.finish(token, value: nil) }
                picker.delegate = delegate
                pickerDelegate = delegate; presentedPicker = picker
                try presenter().present(picker, animated: true)
                picker.presentationController?.delegate = delegate
                task = nil
            } catch { finish(token, value: Self.flutterError(error)) }
        }
    }

    private func presentExport(url: URL, token: UUID) throws {
        let controller = try presenter()
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
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

    static func arguments(_ value: Any?) throws -> [String: Any] {
        guard let map = value as? [String: Any] else { throw NativeMediaError.invalidArgument }
        return map
    }

    static func identifier(_ map: [String: Any], _ key: String) throws -> UUID {
        guard let raw = map[key] as? String, let id = UUID(uuidString: raw) else { throw NativeMediaError.invalidArgument }
        return id
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

    static func flutterError(_ error: Error) -> FlutterError {
        let code: String, message: String
        if error is CancellationError { return FlutterError(code: "canceled", message: "Operation canceled.", details: nil) }
        switch error {
        case NativeMediaError.busy: code = "busy"; message = "Wait for the current native operation to finish."
        case NativeMediaError.canceled: code = "canceled"; message = "Operation canceled."
        case NativeMediaError.permission: code = "permission"; message = "Allow Photos access to retrieve the selected original resource."
        case NativeMediaError.invalidArgument, ProbeError.invalidPatch: code = "invalid_argument"; message = "Check the session, processing token and camera fields."
        case NativeMediaError.notFound: code = "not_found"; message = "The selected session or current processed output is unavailable."
        case NativeMediaError.storage: code = "storage"; message = "The local media copy or session journal could not be accessed safely."
        case NativeMediaError.unsupported(let detail), ProbeError.unsupported(let detail): code = "unsupported"; message = detail
        case ProbeError.malformed: code = "unsupported"; message = "The selected file has an invalid or unqualified media structure."
        default: code = "processing"; message = "Native metadata processing or independent integrity verification failed. No new output is available."
        }
        return FlutterError(code: code, message: message, details: nil)
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
