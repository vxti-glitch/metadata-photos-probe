import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import ProbeCore

enum NativeMediaError: Error {
    case busy, canceled, permission, invalidArgument, notFound, storage, unsupported(String), processing
}

struct NativeProcessing: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let patch: CameraPatch?
    var metadataPatch: MetadataPatch? = nil
    var outputDisplayName: String? = nil
    let outputName: String
    let outputInspection: MediaInspection
    let integrity: IntegrityComparison
    let outputSHA256: String
}

struct NativeSession: Codable, Sendable {
    let id: UUID
    let displayName: String
    let origin: String
    let createdAt: Date
    let sourceName: String
    let sourceSHA256: String
    let inspection: MediaInspection
    let details: [String: String]
    var notes: [String]
    var previewName: String? = nil
    var processing: NativeProcessing?
    var history: [NativeProcessing]

    func bridgeMap(previewPath: String? = nil) throws -> [String: Any] {
        var map: [String: Any] = ["id": id.uuidString, "displayName": displayName,
            "origin": origin, "createdAt": NativeJSON.timestamp(createdAt),
            "inspection": try NativeJSON.object(inspection), "details": details, "notes": notes]
        if let processing {
            let patchObject: Any
            if let patch = processing.metadataPatch { patchObject = try NativeJSON.object(patch) }
            else if let patch = processing.patch { patchObject = try NativeJSON.object(patch) }
            else { throw NativeMediaError.storage }
            var processed: [String: Any] = ["id": processing.id.uuidString,
                "createdAt": NativeJSON.timestamp(processing.createdAt),
                "patch": patchObject,
                "outputInspection": try NativeJSON.object(processing.outputInspection),
                "integrity": try NativeJSON.object(processing.integrity)]
            if let name = processing.outputDisplayName { processed["outputDisplayName"] = name }
            map["processing"] = processed
        }
        if let previewPath { map["previewPath"] = previewPath }
        return map
    }
}

enum NativeJSON {
    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}

/// URL equality includes directory hints/trailing URL separators. Confinement
/// concerns filesystem components instead; resolve links separately before
/// comparing them so identical directory URLs do not produce false failures.
enum NativeFileSystem {
    static func samePath(_ left: URL, _ right: URL) -> Bool {
        left.isFileURL && right.isFileURL
            && left.standardizedFileURL.pathComponents == right.standardizedFileURL.pathComponents
    }
    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        guard candidate.isFileURL, root.isFileURL else { return false }
        let components = candidate.standardizedFileURL.pathComponents
        let parent = root.standardizedFileURL.pathComponents
        return components.count > parent.count && components.starts(with: parent)
    }
}

/// Serializes the local journal. Native-only generated relative names are the
/// sole authority for disk access; Flutter never supplies a URL or filename.
actor NativeSessionStore {
    private struct QualificationKey: Hashable { let session: UUID; let processing: UUID }
    static let maximumSessions = 100
    static let maximumManifestBytes = 2 * 1_048_576
    static let maximumMediaBytes: Int64 = 4 * 1_073_741_824
    private struct Manifest: Codable { let schemaVersion: Int; let sessions: [NativeSession] }
    private let root: URL
    private let previewRoot: URL
    private let mediaSizeLimit: Int64
    private let processOperation: @Sendable (URL, URL, CameraPatch) async throws -> ProcessingResult
    private let metadataProcessOperation: @Sendable (URL, URL, MetadataPatch) async throws -> ProcessingResult
    private var loaded = false
    private var sessions: [NativeSession] = []
    private var qualifiedComparisons = [QualificationKey: IntegrityComparison]()
    // Internal diagnostic only; never exposed through the Flutter channel.
    var cachedQualificationCount: Int { qualifiedComparisons.count }

    init(root: URL, previewRoot: URL? = nil, mediaSizeLimit: Int64 = NativeSessionStore.maximumMediaBytes,
         processOperation: @escaping @Sendable (URL, URL, CameraPatch) async throws -> ProcessingResult = {
        try await MetadataEngine.process(source: $0, output: $1, patch: $2)
    }, metadataProcessOperation: @escaping @Sendable (URL, URL, MetadataPatch) async throws -> ProcessingResult = {
        try await MetadataEngine.processMetadataPatch(source: $0, output: $1, patch: $2)
    }) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.previewRoot = (previewRoot ?? root.deletingLastPathComponent().appendingPathComponent("NativeMediaPreviews", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
        self.processOperation = processOperation
        self.metadataProcessOperation = metadataProcessOperation
        self.mediaSizeLimit = max(1, min(mediaSizeLimit, Self.maximumMediaBytes))
    }

    func list() throws -> [NativeSession] {
        try load()
        return sessions.sorted { $0.createdAt > $1.createdAt }
    }

    func bridgeList() throws -> [[String: Any]] { try list().map { try bridgeMap($0) } }

    func bridgeMap(_ session: NativeSession) throws -> [String: Any] {
        var previewPath: String?
        if let name = session.previewName {
            let url = try confinedPreview(session.id, name: name)
            if FileManager.default.fileExists(atPath: url.path) {
                try Self.requireRegularFile(url, maximumBytes: 2 * 1_048_576)
                previewPath = url.path
            }
        }
        return try session.bridgeMap(previewPath: previewPath)
    }

    func importFile(_ providerURL: URL) async throws -> NativeSession {
        try load()
        guard sessions.count < Self.maximumSessions else { throw NativeMediaError.storage }
        let id = UUID()
        let ext = try allowedExtension(providerURL.pathExtension)
        let directory = try createDirectory(id)
        let target = directory.appendingPathComponent("source.\(ext)")
        var committed = false
        defer { if !committed { try? removeDirectory(id); try? removePreview(id) } }
        let scoped = providerURL.startAccessingSecurityScopedResource()
        defer { if scoped { providerURL.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyError: Error?
        let importLimit = mediaSizeLimit
        NSFileCoordinator().coordinate(readingItemAt: providerURL, options: [], error: &coordinationError) { coordinated in
            do {
                try Self.requireRegularFile(coordinated, maximumBytes: importLimit)
                try FileManager.default.copyItem(at: coordinated, to: target)
            } catch { copyError = error }
        }
        guard coordinationError == nil, copyError == nil else { throw NativeMediaError.storage }
        try Task.checkCancellation()
        let session = try await finalizeImport(id: id, target: target,
            displayName: providerURL.lastPathComponent, origin: "Files",
            notes: ["An immutable copy of the selected Files resource is used. Provider originals are never modified."])
        committed = true
        return session
    }

    func importPhotoResource(_ resource: PHAssetResource) async throws -> NativeSession {
        try load()
        guard sessions.count < Self.maximumSessions else { throw NativeMediaError.storage }
        let type = UTType(resource.uniformTypeIdentifier)
        guard let ext = type?.preferredFilenameExtension else { throw NativeMediaError.unsupported("Unsupported Photos resource type.") }
        let safeExtension = try allowedExtension(ext)
        let id = UUID(), directory = try createDirectory(id)
        let target = directory.appendingPathComponent("source.\(safeExtension)")
        var committed = false
        defer { if !committed { try? removeDirectory(id); try? removePreview(id) } }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let stream = try NativePhotoStream(target: target, maximumBytes: mediaSizeLimit)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let requestID = PHAssetResourceManager.default().requestData(for: resource, options: options,
                    dataReceivedHandler: { stream.accept($0) }, completionHandler: { error in
                        if let failure = stream.finish(error) { continuation.resume(throwing: failure) }
                        else { continuation.resume() }
                    })
                stream.install(requestID)
            }
        }, onCancel: { stream.cancel() })
        try Task.checkCancellation()
        let session = try await finalizeImport(id: id, target: target,
            displayName: resource.originalFilename, origin: "Photos original",
            notes: ["Authorized original Photos resource; current Photos adjustments are not applied.",
                    "Photos library location and importing-app attribution are separate from embedded metadata."])
        committed = true
        return session
    }

    private func finalizeImport(id: UUID, target: URL, displayName: String, origin: String, notes: [String]) async throws -> NativeSession {
        try Self.requireRegularFile(target, maximumBytes: mediaSizeLimit)
        let inspection = try await MetadataEngine.inspect(target)
        try Task.checkCancellation()
        let details = NativeReadableMetadata.details(target, inspection: inspection)
        var session = NativeSession(id: id, displayName: Self.displayName(displayName), origin: origin,
            createdAt: Date(), sourceName: target.lastPathComponent,
            sourceSHA256: try WholeFileDigest.sha256(target), inspection: inspection, details: details,
            notes: notes, processing: nil, history: [])
        // This optional decoded, oriented <=512px PNG is for display only.
        // Source bytes remain the sole input to processing and integrity checks.
        if inspection.kind.isImage {
            let previewName = "\(id.uuidString).png"
            let preview = try confinedPreview(id, name: previewName)
            if NativeReadableMetadata.createPreview(source: target, output: preview) {
                session.previewName = previewName
                session.notes.append("The display preview is a separate image capped at 512 pixels; it is never processed or exported as media.")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
        try persist(sessions + [session])
        return session
    }

    func process(sessionID: UUID, patch: CameraPatch) async throws -> NativeSession {
        try patch.validate()
        return try await processInternal(sessionID: sessionID, cameraPatch: patch, metadataPatch: nil)
    }

    func processMetadata(sessionID: UUID, patch: MetadataPatch) async throws -> NativeSession {
        try patch.validate()
        return try await processInternal(sessionID: sessionID, cameraPatch: nil, metadataPatch: patch)
    }

    private func processInternal(sessionID: UUID, cameraPatch: CameraPatch?, metadataPatch: MetadataPatch?) async throws -> NativeSession {
        try load()
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { throw NativeMediaError.notFound }
        let original = sessions[index]
        guard original.inspection.kind.isImage || cameraPatch?.lens == nil else { throw NativeMediaError.invalidArgument }
        let source = try ownedFile(sessionID, name: original.sourceName)
        guard try WholeFileDigest.sha256(source) == original.sourceSHA256 else { throw NativeMediaError.processing }
        // Persist the loss of active output before starting. If processing fails
        // or the app terminates, an earlier successful result cannot be exported
        // under the new request. Prior successful files remain native history.
        var pending = original
        if let prior = pending.processing { pending.history.append(prior) }
        pending.processing = nil
        let discardedHistory = Array(pending.history.dropLast(10))
        pending.history = Array(pending.history.suffix(10))
        var replacement = sessions
        replacement[index] = pending
        try persist(replacement)
        for prior in discardedHistory {
            try? removeFile(sessionID, name: prior.outputName)
            if let name = prior.outputDisplayName { try? removeExport(name) }
        }
        let processingID = UUID()
        let outputExtension = Self.outputExtension(kind: original.inspection.kind, original: source.pathExtension)
        let outputName = "output-\(processingID.uuidString).\(outputExtension)"
        let output = try confinedFile(sessionID, name: outputName)
        var committed = false
        defer { if !committed { try? removeFile(sessionID, name: outputName) } }
        let result: ProcessingResult
        if let metadataPatch { result = try await metadataProcessOperation(source, output, metadataPatch) }
        else if let cameraPatch { result = try await processOperation(source, output, cameraPatch) }
        else { throw NativeMediaError.invalidArgument }
        try Task.checkCancellation()
        try Self.requireRegularFile(output, maximumBytes: mediaSizeLimit)
        guard try WholeFileDigest.sha256(source) == original.sourceSHA256,
              result.integrity.status != .mismatch else { throw NativeMediaError.processing }
        let processing = NativeProcessing(id: processingID, createdAt: Date(), patch: cameraPatch,
            metadataPatch: metadataPatch, outputDisplayName: try nextOutputDisplayName(extension: outputExtension),
            outputName: outputName, outputInspection: result.outputInspection, integrity: result.integrity,
            outputSHA256: try WholeFileDigest.sha256(output))
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: output.path)
        // Actor reentrancy does not permit replacement work: the bridge gate
        // remains held throughout the await. Verify the session still exists.
        guard let finalIndex = sessions.firstIndex(where: { $0.id == sessionID }), sessions[finalIndex].processing == nil else {
            throw NativeMediaError.processing
        }
        var final = sessions[finalIndex]
        final.processing = processing
        let discarded = Array(final.history.dropLast(10))
        final.history = Array(final.history.suffix(10))
        replacement = sessions; replacement[finalIndex] = final
        try persist(replacement)
        committed = true
        qualifiedComparisons[QualificationKey(session: sessionID, processing: processingID)] = result.integrity
        for prior in discarded {
            try? removeFile(sessionID, name: prior.outputName)
            if let name = prior.outputDisplayName { try? removeExport(name) }
        }
        return final
    }

    func exportURL(sessionID: UUID, processingID: UUID, acknowledgeIncomplete: Bool) async throws -> URL {
        try load()
        guard let session = sessions.first(where: { $0.id == sessionID }), let output = session.processing else { throw NativeMediaError.notFound }
        guard output.id == processingID else { throw NativeMediaError.invalidArgument }
        let qualificationKey = QualificationKey(session: sessionID, processing: output.id)
        var comparison = qualifiedComparisons[qualificationKey] ?? output.integrity
        guard !comparison.checks.isEmpty, comparison.status != .mismatch,
              !comparison.checks.contains(where: { $0.status == .failed }) else { throw NativeMediaError.processing }
        let inconsistent = comparison.status == .verified && (!comparison.limitations.isEmpty || comparison.checks.contains { $0.status == .notChecked })
        guard !inconsistent else { throw NativeMediaError.processing }
        let incomplete = comparison.status == .incomplete || !comparison.limitations.isEmpty
            || comparison.checks.contains(where: { $0.status == .notChecked })
        guard !incomplete || acknowledgeIncomplete else {
            throw NativeMediaError.unsupported("Review and explicitly acknowledge the incomplete integrity checks before export.")
        }
        let url = try ownedFile(sessionID, name: output.outputName)
        guard try WholeFileDigest.sha256(url) == output.outputSHA256 else { throw NativeMediaError.processing }
        let source = try ownedFile(sessionID, name: session.sourceName)
        guard try WholeFileDigest.sha256(source) == session.sourceSHA256 else { throw NativeMediaError.processing }
        if qualifiedComparisons[qualificationKey] == nil {
            // A recovered JSON report is not proof. Reinspect the real immutable
            // media and recompute the canonical comparison once per launch.
            let inspection = try await MetadataEngine.inspect(url)
            guard inspection.kind == session.inspection.kind else { throw NativeMediaError.processing }
            if let patch = output.metadataPatch {
                try patch.validateReadback(inspection)
                comparison = try await MediaIntegrity.compareMetadata(source: source, output: url, patch: patch)
            } else if let patch = output.patch {
                guard inspection.metadata["make"] == patch.make,
                      inspection.metadata["model"] == patch.model,
                      patch.lens == nil || inspection.metadata["lens"] == patch.lens else { throw NativeMediaError.processing }
                comparison = try await MediaIntegrity.compare(source: source, output: url, patch: patch)
            } else { throw NativeMediaError.processing }
            try Task.checkCancellation()
            if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                var replacement = sessions
                replacement[index].processing = NativeProcessing(id: output.id, createdAt: output.createdAt,
                    patch: output.patch, metadataPatch: output.metadataPatch, outputDisplayName: output.outputDisplayName,
                    outputName: output.outputName, outputInspection: inspection,
                    integrity: comparison, outputSHA256: output.outputSHA256)
                try persist(replacement)
            }
            qualifiedComparisons[qualificationKey] = comparison
            guard comparison.status != .mismatch, !comparison.checks.isEmpty,
                  !comparison.checks.contains(where: { $0.status == .failed }) else { throw NativeMediaError.processing }
            let actuallyIncomplete = comparison.status == .incomplete || !comparison.limitations.isEmpty
                || comparison.checks.contains(where: { $0.status == .notChecked })
            guard !actuallyIncomplete || acknowledgeIncomplete else {
                throw NativeMediaError.unsupported("Recovered media has incomplete integrity checks; review and acknowledge them before export.")
            }
        }
        return url
    }

    /// Internal names remain UUID-bound; only qualified exports get consumer names.
    func exportCopyURL(sessionID: UUID, processingID: UUID, acknowledgeIncomplete: Bool) async throws -> URL {
        let source = try await exportURL(sessionID: sessionID, processingID: processingID, acknowledgeIncomplete: acknowledgeIncomplete)
        guard let output = sessions.first(where: { $0.id == sessionID })?.processing,
              output.id == processingID else { throw NativeMediaError.notFound }
        let name: String
        if let saved = output.outputDisplayName { name = saved }
        else {
            name = try nextOutputDisplayName(extension: Self.outputExtension(kind: output.outputInspection.kind, original: source.pathExtension))
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { throw NativeMediaError.notFound }
            var replacement = sessions; replacement[index].processing?.outputDisplayName = name
            try persist(replacement)
        }
        try Self.validateOutputDisplayName(name)
        let folder = try exportsDirectory()
        let target = folder.appendingPathComponent(name)
        guard NativeFileSystem.samePath(target.resolvingSymlinksInPath(), target) else { throw NativeMediaError.storage }
        if FileManager.default.fileExists(atPath: target.path) {
            try Self.requireRegularFile(target, maximumBytes: mediaSizeLimit)
            guard try WholeFileDigest.sha256(target) == output.outputSHA256 else { throw NativeMediaError.storage }
        } else {
            // Same-volume hard link avoids retaining another complete 4 GiB copy.
            // Both app-owned names are immutable; Files exports its own copy.
            try FileManager.default.linkItem(at: source, to: target)
        }
        return target
    }

    func verifyOriginal(sessionID: UUID, processingID: UUID, providerURL: URL) async throws -> [String: Any] {
        let expected = try await exportURL(sessionID: sessionID, processingID: processingID, acknowledgeIncomplete: true)
        let expectedHash = try WholeFileDigest.sha256(expected)
        let expectedBytes = try expected.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let scoped = providerURL.startAccessingSecurityScopedResource()
        defer { if scoped { providerURL.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, readError: Error?
        var actualHash = "", actualBytes = 0
        NSFileCoordinator().coordinate(readingItemAt: providerURL, options: [], error: &coordinationError) { url in
            do {
                try Self.requireRegularFile(url, maximumBytes: mediaSizeLimit)
                actualHash = try WholeFileDigest.sha256(url)
                actualBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            } catch { readError = error }
        }
        guard coordinationError == nil, readError == nil else { throw NativeMediaError.storage }
        try Task.checkCancellation()
        return ["exactMatch": expectedHash == actualHash && expectedBytes == actualBytes,
            "expectedSHA256": expectedHash, "actualSHA256": actualHash,
            "expectedBytes": expectedBytes, "actualBytes": actualBytes]
    }

    func loadEditorState() throws -> [String: Any] {
        try load()
        let url = root.appendingPathComponent("editor-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        try Self.requireRegularFile(url, maximumBytes: 262_144)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let state = object as? [String: Any] else { throw NativeMediaError.storage }
        try Self.validateEditorState(state)
        return state
    }

    func saveEditorState(_ state: [String: Any]) throws {
        try load(); try Self.validateEditorState(state)
        let url = root.appendingPathComponent("editor-state.json")
        if FileManager.default.fileExists(atPath: url.path) { try Self.requireRegularFile(url, maximumBytes: 262_144) }
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        guard data.count <= 262_144 else { throw NativeMediaError.invalidArgument }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func validateEditorState(_ value: Any, depth: Int = 0) throws {
        guard depth <= 12 else { throw NativeMediaError.invalidArgument }
        if let map = value as? [String: Any] {
            guard map.count <= 256 else { throw NativeMediaError.invalidArgument }
            for (key, child) in map {
                guard key.utf8.count <= 128 else { throw NativeMediaError.invalidArgument }
                try validateEditorState(child, depth: depth + 1)
            }
        } else if let list = value as? [Any] {
            guard list.count <= 500 else { throw NativeMediaError.invalidArgument }
            for child in list { try validateEditorState(child, depth: depth + 1) }
        } else if let text = value as? String {
            guard text.utf8.count <= 8192 else { throw NativeMediaError.invalidArgument }
        } else if let number = value as? NSNumber {
            guard number.doubleValue.isFinite else { throw NativeMediaError.invalidArgument }
        } else if !(value is NSNull) { throw NativeMediaError.invalidArgument }
    }

    func presetExportURL(_ preset: [String: Any]) throws -> URL {
        try load(); try Self.validatePreset(preset)
        let url = try exportsDirectory().appendingPathComponent("Metadata-Preset.json")
        if FileManager.default.fileExists(atPath: url.path) { try Self.requireRegularFile(url, maximumBytes: 32_768) }
        try JSONSerialization.data(withJSONObject: preset, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    static func validatePreset(_ preset: [String: Any]) throws {
        try validateEditorState(preset)
        guard preset["schemaVersion"] as? Int == 1,
              let id = preset["id"] as? String, UUID(uuidString: id) != nil,
              let name = preset["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 128, let raw = preset["patch"] as? [String: Any] else { throw NativeMediaError.invalidArgument }
        let bytes = try JSONSerialization.data(withJSONObject: raw)
        guard bytes.count <= 16_384 else { throw NativeMediaError.invalidArgument }
        try JSONDecoder().decode(MetadataPatch.self, from: bytes).validate()
    }

    private func exportsDirectory() throws -> URL {
        let folder = root.appendingPathComponent("Exports", isDirectory: true).standardizedFileURL
        guard NativeFileSystem.isDescendant(folder, of: root),
              NativeFileSystem.samePath(folder.resolvingSymlinksInPath(), folder) else { throw NativeMediaError.storage }
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw NativeMediaError.storage }
        return folder
    }

    private func nextOutputDisplayName(extension ext: String) throws -> String {
        let safe = try allowedExtension(ext).uppercased()
        var used = Set(sessions.flatMap { $0.history + ($0.processing.map { [$0] } ?? []) }.compactMap(\.outputDisplayName))
        let folder = try exportsDirectory()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard names.count <= 1200 else { throw NativeMediaError.storage }
        used.formUnion(names)
        let start = Int.random(in: 1000...9999)
        for offset in 0..<9000 {
            let digits = 1000 + (start - 1000 + offset) % 9000
            let name = "IMG_\(digits).\(safe)"
            if !used.contains(name) { return name }
        }
        throw NativeMediaError.storage
    }

    static func validateOutputDisplayName(_ name: String) throws {
        guard name.range(of: "^IMG_[0-9]{4}\\.(JPG|JPEG|HEIC|HEIF|PNG|MP4|MOV)$", options: .regularExpression) != nil else {
            throw NativeMediaError.storage
        }
    }

    static func outputExtension(kind: MediaKind, original: String) -> String {
        let original = original.lowercased()
        switch kind {
        case .jpeg: return ["jpg", "jpeg"].contains(original) ? original : "jpg"
        case .heic: return ["heic", "heif"].contains(original) ? original : "heic"
        case .png: return "png"
        case .mp4: return "mp4"
        case .mov: return "mov"
        }
    }

    private func removeExports() throws {
        let folder = try exportsDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard files.count <= 1200 else { throw NativeMediaError.storage }
        for file in files {
            if file.lastPathComponent != "Metadata-Preset.json" { try Self.validateOutputDisplayName(file.lastPathComponent) }
            try Self.requireRegularFile(file, maximumBytes: Int64.max, minimumBytes: 0)
        }
        for file in files { try FileManager.default.removeItem(at: file) }
    }

    func delete(_ id: UUID) throws {
        try load()
        try recoverOrphans()
        guard let session = sessions.first(where: { $0.id == id }) else { throw NativeMediaError.notFound }
        let names = (session.history + (session.processing.map { [$0] } ?? [])).compactMap(\.outputDisplayName)
        try persist(sessions.filter { $0.id != id })
        try removeDirectory(id)
        try removePreview(id)
        for name in names { try removeExport(name) }
    }

    func clear() throws {
        try load()
        // Retry interrupted/failed cleanup even when the journal is already
        // empty. The bridge gate guarantees no live staging operation here.
        try recoverOrphans()
        let identifiers = sessions.map(\.id)
        try persist([])
        for id in identifiers { try removeDirectory(id); try removePreview(id) }
        try removeExports()
    }

    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        guard NativeFileSystem.samePath(root.resolvingSymlinksInPath(), root) else { throw NativeMediaError.storage }
        try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        guard NativeFileSystem.samePath(previewRoot.resolvingSymlinksInPath(), previewRoot),
              !NativeFileSystem.samePath(previewRoot, root), !NativeFileSystem.isDescendant(previewRoot, of: root) else { throw NativeMediaError.storage }
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let manifestURL = root.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            try Self.requireRegularFile(manifestURL, maximumBytes: Int64(Self.maximumManifestBytes))
            let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
            let manifest: Manifest
            do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
            catch { throw NativeMediaError.storage }
            guard manifest.schemaVersion == 1, manifest.sessions.count <= Self.maximumSessions,
                  Set(manifest.sessions.map(\.id)).count == manifest.sessions.count else { throw NativeMediaError.storage }
            for session in manifest.sessions {
                guard session.history.count <= 10, session.notes.count <= 100 else { throw NativeMediaError.storage }
                _ = try ownedFile(session.id, name: session.sourceName)
                if let previewName = session.previewName { _ = try confinedPreview(session.id, name: previewName) }
                for processing in session.history + (session.processing.map { [$0] } ?? []) {
                    guard (processing.patch != nil) != (processing.metadataPatch != nil) else { throw NativeMediaError.storage }
                    if let patch = processing.metadataPatch { try patch.validate() }
                    if let name = processing.outputDisplayName { try Self.validateOutputDisplayName(name) }
                    _ = try ownedFile(session.id, name: processing.outputName)
                    guard processing.outputName.hasPrefix("output-\(processing.id.uuidString).") else { throw NativeMediaError.storage }
                }
            }
            sessions = manifest.sessions
        }
        // A termination before journal commit can leave owned staging files.
        // Recover only after validating the entire manifest, and never follow
        // links or recurse into foreign directories while discarding orphans.
        try recoverOrphans()
        loaded = true
    }

    private func persist(_ replacement: [NativeSession]) throws {
        guard replacement.count <= Self.maximumSessions else { throw NativeMediaError.storage }
        let data = try JSONEncoder().encode(Manifest(schemaVersion: 1, sessions: replacement))
        guard data.count <= Self.maximumManifestBytes else { throw NativeMediaError.storage }
        let url = root.appendingPathComponent("manifest.json")
        // Refuse existing links before atomic replacement; no backup restore or
        // path sent by Flutter can change the journal's destination.
        if FileManager.default.fileExists(atPath: url.path) { try Self.requireRegularFile(url, maximumBytes: Int64(Self.maximumManifestBytes)) }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        sessions = replacement
        // Qualification applies only to each session's current frozen output.
        // History remains on disk without retaining its potentially large check
        // reports in this additional cache. Replacement/deletion/clear all use
        // this same journal transition, bounding cache entries by live sessions.
        let liveKeys = Set(replacement.compactMap { session in
            session.processing.map { QualificationKey(session: session.id, processing: $0.id) }
        })
        qualifiedComparisons = qualifiedComparisons.filter { liveKeys.contains($0.key) }
    }

    private func createDirectory(_ id: UUID) throws -> URL {
        let directory = try confinedDirectory(id)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw NativeMediaError.storage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return directory
    }

    private func confinedDirectory(_ id: UUID) throws -> URL {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true).standardizedFileURL
        guard NativeFileSystem.isDescendant(directory, of: root),
              NativeFileSystem.samePath(directory.resolvingSymlinksInPath(), directory) else { throw NativeMediaError.storage }
        return directory
    }

    private func confinedFile(_ id: UUID, name: String) throws -> URL {
        guard !name.contains("/"), !name.contains("\\"), !name.hasPrefix(".") else { throw NativeMediaError.storage }
        let base = (name as NSString).deletingPathExtension
        if base != "source" {
            guard base.hasPrefix("output-"), let outputID = UUID(uuidString: String(base.dropFirst(7))),
                  base == "output-\(outputID.uuidString)" else { throw NativeMediaError.storage }
        }
        _ = try allowedExtension((name as NSString).pathExtension)
        let directory = try confinedDirectory(id)
        let url = directory.appendingPathComponent(name).standardizedFileURL
        guard NativeFileSystem.samePath(url.deletingLastPathComponent(), directory),
              NativeFileSystem.samePath(url.resolvingSymlinksInPath(), url) else { throw NativeMediaError.storage }
        return url
    }

    private func ownedFile(_ id: UUID, name: String) throws -> URL {
        let url = try confinedFile(id, name: name)
        try Self.requireRegularFile(url, maximumBytes: mediaSizeLimit)
        return url
    }

    private func removeFile(_ id: UUID, name: String) throws {
        let url = try confinedFile(id, name: name)
        if FileManager.default.fileExists(atPath: url.path) { try Self.requireRegularFile(url, maximumBytes: Int64.max, minimumBytes: 0); try FileManager.default.removeItem(at: url) }
    }

    private func removeDirectory(_ id: UUID) throws {
        let directory = try confinedDirectory(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        // Do not traverse attacker-controlled nested directories or links.
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard children.count <= 32 else { throw NativeMediaError.storage }
        for child in children { try Self.requireRegularFile(child, maximumBytes: Int64.max, minimumBytes: 0) }
        for child in children { try FileManager.default.removeItem(at: child) }
        try FileManager.default.removeItem(at: directory)
    }

    private func recoverOrphans() throws {
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard children.count <= 512 else { throw NativeMediaError.storage }
        let known = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        for child in children where child.lastPathComponent != "manifest.json" {
            guard let id = UUID(uuidString: child.lastPathComponent), child.lastPathComponent == id.uuidString else { continue }
            _ = try confinedDirectory(id)
            guard let session = known[id] else { try removeDirectory(id); continue }
            let retained = Set([session.sourceName] + session.history.map(\.outputName) + (session.processing.map { [$0.outputName] } ?? []))
            let files = try FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)
            guard files.count <= 32 else { throw NativeMediaError.storage }
            for file in files where !retained.contains(file.lastPathComponent) {
                try Self.requireRegularFile(file, maximumBytes: Int64.max, minimumBytes: 0)
                try FileManager.default.removeItem(at: file)
            }
        }
        let previews = try FileManager.default.contentsOfDirectory(at: previewRoot, includingPropertiesForKeys: nil)
        guard previews.count <= 512 else { throw NativeMediaError.storage }
        let retainedPreviews = Set(sessions.compactMap(\.previewName))
        for preview in previews where !retainedPreviews.contains(preview.lastPathComponent) {
            guard preview.pathExtension == "png", let id = UUID(uuidString: preview.deletingPathExtension().lastPathComponent),
                  preview.lastPathComponent == "\(id.uuidString).png" else { continue }
            try removePreview(id)
        }
        // Remove stale consumer links left by replacement/interrupted deletion.
        let exports = try exportsDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil)
        guard files.count <= 1200 else { throw NativeMediaError.storage }
        let retainedNames = Set(sessions.flatMap { $0.history + ($0.processing.map { [$0] } ?? []) }.compactMap(\.outputDisplayName))
        for file in files where file.lastPathComponent != "Metadata-Preset.json" && !retainedNames.contains(file.lastPathComponent) {
            try removeExport(file.lastPathComponent)
        }
    }

    private func removeExport(_ name: String) throws {
        try Self.validateOutputDisplayName(name)
        let file = try exportsDirectory().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            try Self.requireRegularFile(file, maximumBytes: Int64.max, minimumBytes: 0)
            try FileManager.default.removeItem(at: file)
        }
    }

    private func confinedPreview(_ id: UUID, name: String) throws -> URL {
        guard name == "\(id.uuidString).png" else { throw NativeMediaError.storage }
        let url = previewRoot.appendingPathComponent(name).standardizedFileURL
        guard NativeFileSystem.samePath(url.deletingLastPathComponent(), previewRoot),
              NativeFileSystem.samePath(url.resolvingSymlinksInPath(), url) else { throw NativeMediaError.storage }
        return url
    }

    private func removePreview(_ id: UUID) throws {
        let url = try confinedPreview(id, name: "\(id.uuidString).png")
        if FileManager.default.fileExists(atPath: url.path) { try Self.requireRegularFile(url, minimumBytes: 0); try FileManager.default.removeItem(at: url) }
    }

    private func allowedExtension(_ value: String) throws -> String {
        let ext = value.lowercased()
        guard ["jpg", "jpeg", "heic", "heif", "png", "mp4", "mov"].contains(ext) else { throw NativeMediaError.unsupported("Choose a JPEG, HEIC, PNG, MP4 or MOV file.") }
        return ext
    }

    static func requireRegularFile(_ url: URL, maximumBytes: Int64 = maximumMediaBytes, minimumBytes: Int64 = 1) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, Int64(count) >= minimumBytes, Int64(count) <= maximumBytes else { throw NativeMediaError.storage }
    }

    private static func displayName(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map { String($0) }.joined().prefix(256))
    }
}

/// PhotoKit may deliver callbacks on different queues. The lock protects the
/// stream, byte limit and cancellation ID; no complete media Data is retained.
final class NativePhotoStream: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let maximumBytes: Int64
    private var count: Int64 = 0
    private var requestID: PHAssetResourceDataRequestID?
    private var failure: Error?
    private var finished = false

    init(target: URL, maximumBytes: Int64) throws {
        guard !FileManager.default.fileExists(atPath: target.path), maximumBytes > 0,
              FileManager.default.createFile(atPath: target.path, contents: nil) else { throw NativeMediaError.storage }
        handle = try FileHandle(forWritingTo: target)
        self.maximumBytes = maximumBytes
    }
    deinit { try? handle.close() }
    func install(_ id: PHAssetResourceDataRequestID) {
        lock.lock(); requestID = id; let shouldCancel = failure != nil && !finished; lock.unlock()
        if shouldCancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func accept(_ data: Data) {
        lock.lock()
        guard !finished, failure == nil else { lock.unlock(); return }
        if Int64(data.count) > maximumBytes - count { failure = NativeMediaError.storage }
        else {
            do { try handle.write(contentsOf: data); count += Int64(data.count) }
            catch { failure = NativeMediaError.storage }
        }
        let cancellation = failure == nil ? nil : requestID
        lock.unlock()
        if let cancellation { PHAssetResourceManager.default().cancelDataRequest(cancellation) }
    }
    func cancel() {
        lock.lock(); if !finished { failure = CancellationError() }; let cancellation = finished ? nil : requestID; lock.unlock()
        if let cancellation { PHAssetResourceManager.default().cancelDataRequest(cancellation) }
    }
    func finish(_ error: Error?) -> Error? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return failure }
        finished = true
        if failure == nil && (error != nil || count == 0) { failure = NativeMediaError.storage }
        do { try handle.synchronize(); try handle.close() } catch { if failure == nil { failure = NativeMediaError.storage } }
        return failure
    }
}

enum NativeReadableMetadata {
    static func createPreview(source url: URL, output: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: output.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: false] as CFDictionary),
              image.width <= 512, image.height <= 512,
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: output); return false }
        return true
    }
    static func details(_ url: URL, inspection: MediaInspection) -> [String: String] {
        var details = inspection.metadata
        guard inspection.kind.isImage,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return details }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let fields: [(String, Any?)] = [
            ("dateTime", tiff[kCGImagePropertyTIFFDateTime as String]),
            ("dateTimeOriginal", exif[kCGImagePropertyExifDateTimeOriginal as String]),
            ("exposureTime", exif[kCGImagePropertyExifExposureTime as String]),
            ("fNumber", exif[kCGImagePropertyExifFNumber as String]),
            ("focalLength", exif[kCGImagePropertyExifFocalLength as String]),
            ("focalLength35mm", exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]),
            ("exposureBias", exif[kCGImagePropertyExifExposureBiasValue as String])]
        for (key, value) in fields {
            if let string = value as? String { details[key] = String(string.prefix(256)) }
            else if let number = value as? NSNumber, number.doubleValue.isFinite { details[key] = number.stringValue }
        }
        if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let first = iso.first, first.doubleValue.isFinite { details["iso"] = first.stringValue }
        // GPS stays in canonical structured location evidence. Opaque MakerNote,
        // IPTC blobs and arbitrary metadata dictionaries are never flattened.
        return details
    }
}
