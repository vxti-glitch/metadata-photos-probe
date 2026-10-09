import Foundation

public struct VideoMetadataWriteReport: Codable, Sendable {
    public let strategy: String
    public let validatedTracks: Int
    public let validatedChunks: Int
    public let notes: [String]
}

/// A deliberately restricted, file-backed movie-level mdta writer. It never decodes media.
/// Apple's public format defines key indexes and immediate values:
/// https://developer.apple.com/documentation/quicktime-file-format/metadata_atoms_and_types
/// https://developer.apple.com/documentation/quicktime-file-format/metadata_item_keys_atom
/// https://developer.apple.com/documentation/quicktime-file-format/chunk_offset_atom
/// Chunk offsets are absolute file offsets. Keeping every original media byte at its
/// original position avoids repairing/rebuilding tracks, sample tables or codec data.
/// Unsupported containers are refused; AVFoundation readback and the independent
/// integrity verifier MUST still run before any output is considered usable.
public enum VideoMetadataWriter {
    public static func write(source: URL, output: URL, patch: CameraPatch) async throws -> VideoMetadataWriteReport {
        try patch.validate()
        guard patch.lens == nil else { throw ProbeError.unsupported("Video lens editing is not qualified") }
        return try await write(source: source, output: output, patch: MetadataPatch(values: ["make": .string(patch.make), "model": .string(patch.model)]))
    }
    public static func write(source: URL, output: URL, patch: MetadataPatch) async throws -> VideoMetadataWriteReport {
        try patch.validate()
        guard patch.targetedKeys.isSubset(of: VideoMetadataFields.supported) else { throw ProbeError.unsupported("Requested field has no qualified movie metadata representation") }
        let existing = patch.targetedKeys.isDisjoint(with: VideoMetadataFields.gpsKeys) ? [:] : try inspect(source)
        let movieValues = try VideoMetadataFields.values(patch, existing: existing, track: false)
        let trackValues = try VideoMetadataFields.values(patch, existing: existing, track: true)
        guard source.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath() else { throw ProbeError.sameFile }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ProbeError.outputExists }
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard source.isFileURL, output.isFileURL, info.isRegularFile == true, let count = info.fileSize, count > 0 else {
            throw ProbeError.malformed("A nonempty regular movie file is required")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let top = try VideoBMFF.fileAtoms(input, length: UInt64(count))
        let allowedTop = Set(["ftyp", "moov", "mdat", "free", "skip", "wide"].map(VideoBMFF.code))
        guard top.allSatisfy({ allowedTop.contains($0.type) }), top.first?.type == VideoBMFF.code("ftyp"),
              top.filter({ $0.type == VideoBMFF.code("ftyp") }).count == 1,
              top.filter({ $0.type == VideoBMFF.code("moov") }).count == 1 else {
            throw ProbeError.unsupported("Only self-contained nonfragmented MP4/MOV with one moov and known top-level atoms is qualified")
        }
        let movie = top.first { $0.type == VideoBMFF.code("moov") }!
        guard movie.size <= VideoBMFF.maxMovieBytes else { throw ProbeError.unsupported("Movie header exceeds 16 MiB parser budget") }
        let dataAtoms = top.filter { $0.type == VideoBMFF.code("mdat") }
        guard !dataAtoms.isEmpty else { throw ProbeError.malformed("Movie has no mdat") }
        let ftyp = top[0]
        guard ftyp.size >= UInt64(ftyp.header + 8) else { throw ProbeError.malformed("Truncated ftyp") }
        let brandData = try VideoBMFF.read(input, at: ftyp.offset + UInt64(ftyp.header), count: 4)
        let brand = String(decoding: brandData, as: UTF8.self)
        let isMOV = brand == "qt  "
        guard isMOV || ["isom", "iso2", "mp41", "mp42", "avc1", "M4V ", "MSNV"].contains(brand) else {
            throw ProbeError.unsupported("Unqualified movie brand \(brand)")
        }
        let originalMovie = try VideoBMFF.read(input, at: movie.offset, count: Int(movie.size))
        let movieAtom = try VideoBMFF.atoms(originalMovie).first!
        let children = try VideoBMFF.atoms(movieAtom.payload)
        let validation = try VideoBMFF.validateMovie(children, media: dataAtoms)
        var metadataCount = 0
        var rebuilt = Data()
        for child in children {
            if child.type == VideoBMFF.code("meta") {
                guard try VideoBMFF.handler(child) == VideoBMFF.code("mdta") else {
                    throw ProbeError.unsupported("Non-mdta movie-level meta cannot be combined with another movie meta")
                }
                metadataCount += 1
                rebuilt.append(try VideoBMFF.editMetadata(child, values: movieValues))
            } else if child.type == VideoBMFF.code("udta") {
                var userData = Data()
                for entry in try VideoBMFF.atoms(child.payload) {
                    if entry.type == VideoBMFF.code("meta"), try VideoBMFF.handler(entry) == VideoBMFF.code("mdta") {
                        metadataCount += 1
                        userData.append(try VideoBMFF.editMetadata(entry, values: movieValues))
                    } else { userData.append(try VideoBMFF.retainUserData(entry, patch: patch)) }
                }
                rebuilt.append(try VideoBMFF.atom("udta", userData))
            } else if child.type == VideoBMFF.code("trak") {
                rebuilt.append(try VideoBMFF.editTrack(child, patch: patch, values: trackValues,
                    locationValues: movieValues.filter { $0.key == VideoMetadataFields.locationKey }))
            } else if child.type == VideoBMFF.code("mvhd") {
                rebuilt.append(try VideoBMFF.editDates(child, patch: patch, create: "movieCreateDate", modify: "movieModifyDate"))
            } else { rebuilt.append(child.raw) }
        }
        guard metadataCount <= 1 else { throw ProbeError.unsupported("Ambiguous multiple movie-level mdta containers") }
        // This is Apple's QuickTime mdta atom, not the versioned ISO item-meta box.
        // AVFoundation requires the unversioned mdta layout in our MP4/MOV controls.
        if metadataCount == 0, !movieValues.isEmpty { rebuilt.append(try VideoBMFF.newMetadata(movieValues, fullBox: false)) }
        let newMovie = try VideoBMFF.atom("moov", rebuilt)
        guard newMovie.count <= Int(VideoBMFF.maxMovieBytes) else { throw ProbeError.unsupported("Edited movie header exceeds 16 MiB budget") }
        try Task.checkCancellation()
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw ProbeError.writeFailed("Cannot create staged movie") }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: output) } }
        let destination = try FileHandle(forWritingTo: output)
        defer { try? destination.close() }
        try input.seek(toOffset: 0)
        var copied: UInt64 = 0
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            try destination.write(contentsOf: bytes)
            copied += UInt64(bytes.count)
        }
        guard copied == UInt64(count) else { throw ProbeError.writeFailed("Source changed while being copied") }
        // Retire the old movie atom without moving any media. Zero its retired payload
        // so stale camera values are not left in free space. The original stays immutable.
        try destination.seek(toOffset: movie.offset + 4)
        try destination.write(contentsOf: Data("free".utf8))
        try destination.seek(toOffset: movie.offset + UInt64(movie.header))
        var remaining = movie.size - UInt64(movie.header)
        let zero = Data(repeating: 0, count: 65_536)
        while remaining > 0 {
            try Task.checkCancellation()
            let amount = min(remaining, UInt64(zero.count))
            try destination.write(contentsOf: zero.prefix(Int(amount)))
            remaining -= amount
        }
        try destination.seek(toOffset: copied)
        try destination.write(contentsOf: newMovie)
        try destination.synchronize()
        complete = true
        return VideoMetadataWriteReport(strategy: "Metadata-only moov relocation; original media offsets retained",
            validatedTracks: validation.tracks, validatedChunks: validation.chunks,
            notes: ["Every accepted track/sample table and non-target metadata record was retained; no samples were decoded or re-encoded.",
                    "Original media byte positions are unchanged. All referenced chunk extents were checked inside original mdat payloads.",
                    "Fragmented, protected, external-reference, unknown relocation-sensitive or ambiguous metadata layouts are refused.",
                    "File size grows by a movie header and fast-start layout may change. Independent media/readback and Photos device tests remain required."])
    }
    /// Independent bounded container readback, including every movie/track/media date.
    public static func inspect(_ url: URL) throws -> [String: String] {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let size = try input.seekToEnd(), top = try VideoBMFF.fileAtoms(input, length: size)
        let movies = top.filter { $0.type == VideoBMFF.code("moov") }
        guard movies.count == 1, let movie = movies.first, movie.size <= VideoBMFF.maxMovieBytes else { throw ProbeError.unsupported("Bounded unique movie header required") }
        let data = try VideoBMFF.read(input, at: movie.offset, count: Int(movie.size))
        return try VideoBMFF.inspectedMovie(VideoBMFF.atoms(data)[0])
    }
}

private enum VideoBMFF {
    static let maxMovieBytes: UInt64 = 16 * 1024 * 1024
    static let maxEntries = 1_000_000
    struct FileAtom { let type: UInt32; let offset: UInt64; let size: UInt64; let header: Int }
    struct Atom { let type: UInt32; let raw: Data; let header: Int; var payload: Data { raw.subdata(in: header..<raw.count) } }
    static func code(_ value: String) -> UInt32 { value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    static func number(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    static func u32(_ data: Data, _ at: Int) throws -> UInt32 {
        guard at >= 0, at <= data.count - 4 else { throw ProbeError.malformed("Truncated 32-bit movie field") }
        return data[at..<at+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    static func u64(_ data: Data, _ at: Int) throws -> UInt64 {
        guard at >= 0, at <= data.count - 8 else { throw ProbeError.malformed("Truncated 64-bit movie field") }
        return data[at..<at+8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    static func read(_ file: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try file.seek(toOffset: offset)
        let bytes = try file.read(upToCount: count) ?? Data()
        guard bytes.count == count else { throw ProbeError.malformed("Truncated movie atom") }
        return bytes
    }
    static func fileAtoms(_ file: FileHandle, length: UInt64) throws -> [FileAtom] {
        var result: [FileAtom] = [], offset: UInt64 = 0
        while offset < length {
            guard result.count < 512, length - offset >= 8 else { throw ProbeError.malformed("Invalid/budget-exceeded top-level atom list") }
            let header = try read(file, at: offset, count: 8)
            let size32 = try u32(header, 0), type = try u32(header, 4)
            guard size32 != 0 else { throw ProbeError.unsupported("EOF-sized atoms cannot safely precede an appended movie") }
            let headerSize = size32 == 1 ? 16 : 8
            let size = size32 == 1 ? try u64(read(file, at: offset + 8, count: 8), 0) : UInt64(size32)
            guard size >= UInt64(headerSize), size <= length - offset else { throw ProbeError.malformed("Movie atom size escapes its file") }
            result.append(FileAtom(type: type, offset: offset, size: size, header: headerSize)); offset += size
        }
        return result
    }
    static func atoms(_ data: Data) throws -> [Atom] {
        var result: [Atom] = [], cursor = 0
        while cursor < data.count {
            guard result.count < 100_000, data.count - cursor >= 8 else { throw ProbeError.malformed("Invalid/budget-exceeded child atom list") }
            let size32 = try u32(data, cursor), type = try u32(data, cursor + 4)
            guard size32 != 0 else { throw ProbeError.unsupported("Zero-size child atom") }
            let header = size32 == 1 ? 16 : 8
            let size64 = size32 == 1 ? try u64(data, cursor + 8) : UInt64(size32)
            guard size64 >= UInt64(header), size64 <= UInt64(data.count - cursor) else { throw ProbeError.malformed("Child atom size escapes its parent") }
            let size = Int(size64)
            result.append(Atom(type: type, raw: data.subdata(in: cursor..<cursor+size), header: header)); cursor += size
        }
        return result
    }
    static func atom(_ type: String, _ payload: Data) throws -> Data { try atom(code(type), payload) }
    static func atom(_ type: UInt32, _ payload: Data) throws -> Data {
        guard payload.count <= Int(maxMovieBytes) - 8 else { throw ProbeError.unsupported("Atom exceeds rewrite budget") }
        return number(UInt32(payload.count + 8)) + number(type) + payload
    }
    static func unique(_ atoms: [Atom], _ name: String) throws -> Atom {
        let values = atoms.filter { $0.type == code(name) }
        guard values.count == 1 else { throw ProbeError.malformed("Expected exactly one \(name) atom") }
        return values[0]
    }
    static func only(_ list: [Atom], _ allowed: [String]) throws {
        let accepted = Set(allowed.map(code))
        guard list.allSatisfy({ accepted.contains($0.type) }) else {
            let names = list.filter { !accepted.contains($0.type) }.map { String(decoding: number($0.type), as: UTF8.self) }
            throw ProbeError.unsupported("Unqualified movie atoms: \(names.joined(separator: ", ")); no relocation attempted")
        }
    }
    static func validateUserData(_ data: Data) throws {
        for child in try atoms(data) {
            let bytes = number(child.type)
            guard bytes.first == 0xA9 || ["meta", "free", "skip", "loci", "XMP_", "chpl"].map(code).contains(child.type) else {
                throw ProbeError.unsupported("Unqualified user-data atom")
            }
            if child.type == code("meta") { _ = try metadataChildren(child) }
        }
    }
    static func validateMovie(_ children: [Atom], media: [FileAtom]) throws -> (tracks: Int, chunks: Int) {
        try only(children, ["mvhd", "trak", "udta", "meta", "iods", "free"])
        _ = try unique(children, "mvhd")
        var trackCount = 0, chunkCount = 0
        for child in children {
            if child.type == code("udta") { try validateUserData(child.payload) }
            if child.type == code("meta") { _ = try metadataChildren(child) }
            guard child.type == code("trak") else { continue }
            trackCount += 1
            let track = try atoms(child.payload)
            try only(track, ["tkhd", "mdia", "edts", "tref", "tapt", "udta", "meta", "free"])
            _ = try unique(track, "tkhd")
            for item in track {
                if item.type == code("udta") { try validateUserData(item.payload) }
                if item.type == code("meta") { _ = try metadataChildren(item) }
                if item.type == code("edts") { try only(atoms(item.payload), ["elst"]) }
                if item.type == code("tapt") {
                    let apertures = try atoms(item.payload)
                    try only(apertures, ["clef", "prof", "enof"])
                    guard Set(apertures.map(\.type)).count == apertures.count else { throw ProbeError.malformed("Duplicate aperture atom") }
                    for aperture in apertures {
                        guard aperture.payload.count == 12, try u32(aperture.payload, 0) == 0 else { throw ProbeError.unsupported("Unqualified aperture layout") }
                    }
                }
            }
            let mdia = try atoms(unique(track, "mdia").payload)
            try only(mdia, ["mdhd", "hdlr", "minf", "elng", "udta", "meta", "free"])
            let minf = try atoms(unique(mdia, "minf").payload)
            try only(minf, ["vmhd", "smhd", "nmhd", "gmhd", "hdlr", "dinf", "stbl", "free"])
            let dinf = try atoms(unique(minf, "dinf").payload)
            try only(dinf, ["dref", "free"])
            let dref = try unique(dinf, "dref").payload
            guard try u32(dref, 0) == 0, dref.count >= 8 else { throw ProbeError.malformed("Invalid dref") }
            let references = try atoms(dref.subdata(in: 8..<dref.count))
            guard references.count == Int(try u32(dref, 4)), !references.isEmpty else { throw ProbeError.malformed("Data-reference count mismatch") }
            // Apple's media-data reference contract permits a self-reference flag
            // for an alias as well as a URL. AVAssetWriter MOV controls use `alis`.
            // Accept version 0 / flag 1 only, with no external alias/URL payload.
            // https://developer.apple.com/documentation/quicktime-file-format/media_data_reference_atom/data_references
            guard references.allSatisfy({
                ($0.type == code("url ") || $0.type == code("alis")) && $0.payload == number(1)
            }) else {
                throw ProbeError.unsupported("External or unqualified data references")
            }
            chunkCount += try validateSampleTable(atoms(unique(minf, "stbl").payload), references: references.count, media: media)
        }
        guard trackCount > 0 else { throw ProbeError.malformed("Movie has no tracks") }
        return (trackCount, chunkCount)
    }
    static func validateSampleTable(_ list: [Atom], references: Int, media: [FileAtom]) throws -> Int {
        try only(list, ["stsd", "stts", "ctts", "cslg", "stsc", "stsz", "stco", "co64", "stss", "stps", "sdtp", "sgpd", "sbgp", "csgm", "stdp", "stsh", "padb", "subs", "free"])
        let description = try unique(list, "stsd").payload
        guard try u32(description, 0) == 0, description.count >= 8 else { throw ProbeError.malformed("Invalid stsd") }
        let entries = try atoms(description.subdata(in: 8..<description.count))
        guard entries.count == Int(try u32(description, 4)), !entries.isEmpty else { throw ProbeError.malformed("Sample-description count mismatch") }
        let codecs = Set(["avc1", "avc3", "hvc1", "hev1", "mp4v", "mp4a", "lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64", "alac", "ac-3", "ec-3", "Opus", "metx", "mett", "mebx", "tmcd", "text", "tx3g"].map(code))
        for entry in entries {
            guard codecs.contains(entry.type), entry.payload.count >= 8 else { throw ProbeError.unsupported("Unqualified/protected sample description") }
            let p = entry.payload
            let index = Int(p[6]) << 8 | Int(p[7])
            guard index > 0, index <= references else { throw ProbeError.malformed("Sample description references unavailable data") }
        }
        let offsets = list.filter { $0.type == code("stco") || $0.type == code("co64") }
        guard offsets.count == 1 else { throw ProbeError.malformed("Expected one chunk offset table") }
        let table = offsets[0].payload, width = offsets[0].type == code("co64") ? 8 : 4
        guard try u32(table, 0) == 0 else { throw ProbeError.unsupported("Chunk offset version/flags") }
        let chunks = Int(try u32(table, 4))
        guard chunks <= maxEntries, table.count == 8 + chunks * width else { throw ProbeError.malformed("Chunk table count/length mismatch") }
        let sizes = try unique(list, "stsz").payload
        guard try u32(sizes, 0) == 0 else { throw ProbeError.unsupported("Sample size version/flags") }
        let fixed = try u32(sizes, 4), sampleCount = Int(try u32(sizes, 8))
        guard sampleCount <= maxEntries, sizes.count == (fixed == 0 ? 12 + sampleCount * 4 : 12) else { throw ProbeError.malformed("Sample size count/length mismatch") }
        let mapping = try unique(list, "stsc").payload
        guard try u32(mapping, 0) == 0 else { throw ProbeError.unsupported("Sample-to-chunk version/flags") }
        let maps = Int(try u32(mapping, 4))
        guard maps <= maxEntries, mapping.count == 8 + maps * 12 else { throw ProbeError.malformed("Sample-to-chunk count/length mismatch") }
        if sampleCount == 0 {
            guard chunks == 0, maps == 0 else { throw ProbeError.malformed("Empty track has chunk/sample mappings") }
            return 0
        }
        guard chunks > 0, maps > 0 else { throw ProbeError.malformed("Nonempty track lacks chunk mappings") }
        var runs: [(first: Int, samples: Int)] = []
        for index in 0..<maps {
            let start = 8 + index * 12
            let first = Int(try u32(mapping, start)), samples = Int(try u32(mapping, start + 4)), desc = Int(try u32(mapping, start + 8))
            guard first >= 1, first <= chunks, samples > 0, samples <= sampleCount, desc >= 1, desc <= entries.count,
                  (index == 0 ? first == 1 : first > runs[index-1].first) else { throw ProbeError.malformed("Invalid sample-to-chunk run") }
            runs.append((first, samples))
        }
        var run = 0, sample = 0
        for chunk in 0..<chunks {
            try Task.checkCancellation()
            if run + 1 < runs.count, runs[run + 1].first == chunk + 1 { run += 1 }
            let amount = runs[run].samples
            guard amount <= sampleCount - sample else { throw ProbeError.malformed("Chunk mapping exceeds samples") }
            var length: UInt64 = 0
            for _ in 0..<amount {
                length += UInt64(fixed == 0 ? try u32(sizes, 12 + sample * 4) : fixed); sample += 1
            }
            let offset = width == 8 ? try u64(table, 8 + chunk * width) : UInt64(try u32(table, 8 + chunk * width))
            guard media.contains(where: { offset >= $0.offset + UInt64($0.header) && offset < $0.offset + $0.size && length <= $0.offset + $0.size - offset }) else {
                throw ProbeError.malformed("A chunk extent escapes all mdat payloads")
            }
        }
        guard sample == sampleCount else { throw ProbeError.malformed("Unreferenced samples remain in table") }
        return chunks
    }
    static func metadataChildren(_ meta: Atom) throws -> (prefix: Data, children: [Atom]) {
        let body = meta.payload
        var prefixLength = 0
        if body.count >= 4 { if try u32(body, 0) == 0 { prefixLength = 4 } }
        let children = try atoms(body.subdata(in: prefixLength..<body.count))
        try only(children, ["hdlr", "keys", "ilst", "mhdr", "ctry", "lang", "free"])
        _ = try unique(children, "hdlr")
        return (Data(body.prefix(prefixLength)), children)
    }
    static func retainUserData(_ item: Atom, patch: MetadataPatch) throws -> Data {
        let changesLocation = !patch.targetedKeys.isDisjoint(with: VideoMetadataFields.gpsKeys)
        if item.type == code("XMP_"), !patch.removals.isEmpty || changesLocation {
            throw ProbeError.unsupported("Removal or location editing is refused for a movie containing additional XMP metadata")
        }
        if item.type == code("loci") {
            // ISO location is a second representation of the coordinate tuple.
            // Whole-coordinate removal must retire it alongside mdta/legacy GPS;
            // unrelated edits retain its original bytes. Its altitude cannot be
            // edited independently without a qualified ISO location parser.
            if patch.removals.contains("latitude") || patch.removals.contains("longitude") { return Data() }
            if patch.removals.contains("altitude") {
                throw ProbeError.unsupported("Altitude-only removal is refused for a movie containing ISO location metadata")
            }
            // A new coordinate tuple is written to mdta. Do not leave the old ISO
            // tuple for an independent reader to report as a competing location.
            if changesLocation { return Data() }
        }
        let legacy: [UInt32: Set<String>] = [0xa96d616b: ["make"], 0xa96d6f64: ["model"], 0xa9737772: ["software"], 0xa978797a: VideoMetadataFields.gpsKeys, 0xa96e616d: ["title"], 0xa9637079: ["copyright"], 0xa9415254: ["artist"], 0xa9636d74: ["description"]]
        if let fields = legacy[item.type], !fields.isDisjoint(with: patch.targetedKeys) { return Data() }
        return item.raw
    }
    static func editDates(_ item: Atom, patch: MetadataPatch, create: String, modify: String) throws -> Data {
        var accepted = Set([create, modify])
        if create == "movieCreateDate" { accepted.insert("createDate"); accepted.insert("modifyDate") }
        guard !patch.targetedKeys.isDisjoint(with: accepted) else { return item.raw }
        var payload = item.payload
        guard !payload.isEmpty, [0, 1].contains(payload[0]) else { throw ProbeError.unsupported("Unqualified date-header version") }
        let width = payload[0] == 1 ? 8 : 4
        guard payload.count >= 4 + width * 2 else { throw ProbeError.malformed("Short movie date header") }
        for (key, at) in [(create, 4), (modify, 4 + width)] {
            let alias = create == "movieCreateDate" && key == create ? "createDate" : modify == "movieModifyDate" && key == modify ? "modifyDate" : key
            let selected = patch.targetedKeys.contains(key) ? key : alias
            guard patch.targetedKeys.contains(selected) else { continue }
            var seconds: UInt64 = 0
            if let value = patch.values[selected] {
                let time = (try MetadataPatch.date(value.text)).timeIntervalSince1970 + 2_082_844_800
                guard time >= 0, time <= Double(UInt64.max), width == 8 || time <= Double(UInt32.max) else { throw ProbeError.unsupported("Date does not fit original movie-header version") }
                seconds = UInt64(time.rounded(.down))
            }
            let bytes = Data((0..<width).map { UInt8((seconds >> ((width - 1 - $0) * 8)) & 255) })
            payload.replaceSubrange(at..<at + width, with: bytes)
        }
        return try atom(item.type, payload)
    }
    static func editTrack(_ item: Atom, patch: MetadataPatch, values: [String: String?], locationValues: [String: String?]) throws -> Data {
        let changesLocation = !patch.targetedKeys.isDisjoint(with: VideoMetadataFields.gpsKeys)
        guard !values.isEmpty || !patch.removals.isEmpty || changesLocation || !patch.targetedKeys.isDisjoint(with: Set(["trackCreateDate", "trackModifyDate", "mediaCreateDate", "mediaModifyDate"])) else { return item.raw }
        let children = try atoms(item.payload), mdia = try atoms(unique(children, "mdia").payload)
        let mediaType = try u32(unique(mdia, "hdlr").payload, 8)
        if changesLocation, [code("meta"), code("mdta")].contains(mediaType) {
            throw ProbeError.unsupported("Location editing is refused for a movie containing timed metadata tracks")
        }
        let video = mediaType == code("vide")
        let scopedValues = (video ? values : [:]).merging(locationValues, uniquingKeysWith: { _, new in new })
        var body = Data(), count = 0
        for child in children {
            if child.type == code("tkhd") { body.append(try editDates(child, patch: patch, create: "trackCreateDate", modify: "trackModifyDate")) }
            else if child.type == code("mdia") {
                var data = Data()
                for entry in mdia {
                    if entry.type == code("mdhd") { data.append(try editDates(entry, patch: patch, create: "mediaCreateDate", modify: "mediaModifyDate")) }
                    else if entry.type == code("udta") {
                        var userData = Data()
                        for record in try atoms(entry.payload) {
                            if record.type == code("meta"), changesLocation || !patch.removals.isEmpty {
                                throw ProbeError.unsupported("Removal or location editing is refused for a movie containing unqualified media-level metadata")
                            }
                            userData.append(try retainUserData(record, patch: patch))
                        }
                        data.append(try atom("udta", userData))
                    } else if entry.type == code("meta"), changesLocation || !patch.removals.isEmpty {
                        throw ProbeError.unsupported("Removal or location editing is refused for a movie containing unqualified media-level metadata")
                    }
                    else { data.append(entry.raw) }
                }
                body.append(try atom("mdia", data))
            } else if child.type == code("meta"), !scopedValues.isEmpty {
                count += 1; body.append(try editMetadata(child, values: scopedValues))
            } else if child.type == code("udta") {
                var data = Data()
                for entry in try atoms(child.payload) {
                    if entry.type == code("meta"), !scopedValues.isEmpty, try handler(entry) == code("mdta") {
                        count += 1; data.append(try editMetadata(entry, values: scopedValues))
                    } else if entry.type == code("meta"), changesLocation {
                        throw ProbeError.unsupported("Location editing is refused for a movie containing unqualified track metadata")
                    } else { data.append(try retainUserData(entry, patch: patch)) }
                }
                body.append(try atom("udta", data))
            } else { body.append(child.raw) }
        }
        guard count <= 1 else { throw ProbeError.unsupported("Ambiguous video-track camera metadata containers") }
        if video, count == 0, !values.isEmpty { body.append(try newMetadata(values, fullBox: false)) }
        return try atom("trak", body)
    }
    static func metadataValues(_ meta: Atom) throws -> [String: String] {
        guard try handler(meta) == code("mdta") else { return [:] }
        let parts = try metadataChildren(meta).children, keys = try unique(parts, "keys").payload
        guard try u32(keys, 0) == 0, keys.count >= 8 else { throw ProbeError.malformed("Metadata keys header") }
        let count = Int(try u32(keys, 4)); guard count <= 4096 else { throw ProbeError.unsupported("Metadata key count") }
        var definitions = [String](), cursor = 8
        for _ in 0..<count {
            let length = Int(try u32(keys, cursor)), namespace = try u32(keys, cursor + 4)
            guard length >= 8, length <= keys.count - cursor else { throw ProbeError.malformed("Metadata key size") }
            definitions.append(namespace == code("mdta") ? String(decoding: keys[cursor + 8..<cursor + length], as: UTF8.self) : "")
            cursor += length
        }
        guard cursor == keys.count else { throw ProbeError.malformed("Metadata key trailing bytes") }
        var result = [String: String]()
        for item in try atoms(unique(parts, "ilst").payload) {
            guard item.type > 0, item.type <= UInt32(count) else { throw ProbeError.malformed("Metadata index") }
            let key = definitions[Int(item.type) - 1]
            guard !key.isEmpty else { continue }
            let values = try atoms(item.payload).filter { $0.type == code("data") }
            guard values.count <= 1 else { throw ProbeError.unsupported("Multiple metadata values cannot be represented as a scalar") }
            if let value = values.first, value.payload.count >= 8, try u32(value.payload, 0) == 1 {
                guard result[key] == nil else { throw ProbeError.unsupported("Duplicate movie metadata key") }
                result[key] = String(data: value.payload.dropFirst(8), encoding: .utf8)
            }
        }
        return result
    }
    static func inspectedMovie(_ movie: Atom) throws -> [String: String] {
        var result = [String: String](), dateValues = [String: Set<String>]()
        func collectDates(_ item: Atom, create: String, modify: String) throws {
            let p = item.payload; guard !p.isEmpty, [0, 1].contains(p[0]) else { throw ProbeError.unsupported("Movie date version") }
            let width = p[0] == 1 ? 8 : 4
            for (key, at) in [(create, 4), (modify, 4 + width)] {
                let value = width == 8 ? try u64(p, at) : UInt64(try u32(p, at))
                if value > 0 {
                    let date = Date(timeIntervalSince1970: Double(value) - 2_082_844_800)
                    dateValues[key, default: []].insert(ISO8601DateFormatter().string(from: date))
                }
            }
        }
        func collect(_ meta: Atom) throws {
            for (key, value) in try metadataValues(meta) {
                if let old = result[key], old != value { throw ProbeError.unsupported("Conflicting metadata values across movie/track containers") }
                result[key] = value
            }
        }
        for child in try atoms(movie.payload) {
            if child.type == code("mvhd") { try collectDates(child, create: "movieCreateDate", modify: "movieModifyDate") }
            if child.type == code("meta") { try collect(child) }
            if child.type == code("udta") { for m in try atoms(child.payload) where m.type == code("meta") { try collect(m) } }
            if child.type == code("trak") {
                for entry in try atoms(child.payload) {
                    if entry.type == code("tkhd") { try collectDates(entry, create: "trackCreateDate", modify: "trackModifyDate") }
                    if entry.type == code("meta") { try collect(entry) }
                    if entry.type == code("udta") { for m in try atoms(entry.payload) where m.type == code("meta") { try collect(m) } }
                    if entry.type == code("mdia") {
                        for m in try atoms(entry.payload) where m.type == code("mdhd") { try collectDates(m, create: "mediaCreateDate", modify: "mediaModifyDate") }
                    }
                }
            }
        }
        for (key, values) in dateValues { result[key] = values.sorted().joined(separator: ";") }
        result["createDate"] = result["movieCreateDate"]; result["modifyDate"] = result["movieModifyDate"]
        for (key, atom) in VideoMetadataFields.keys.merging(VideoMetadataFields.trackKeys, uniquingKeysWith: { a, _ in a }) { result[key] = result[atom] }
        if let location = result[VideoMetadataFields.locationKey] { for (key, value) in VideoMetadataFields.decodeLocation(location) { result[key] = value } }
        return result
    }
    static func handler(_ meta: Atom) throws -> UInt32 {
        let children = try metadataChildren(meta).children
        return try u32(unique(children, "hdlr").payload, 8)
    }
    static func newMetadata(_ values: [String: String?], fullBox: Bool) throws -> Data {
        let hdlr = try atom("hdlr", number(0) + number(0) + number(code("mdta")) + Data(repeating: 0, count: 13))
        let keys = try atom("keys", number(0) + number(0))
        let items = try atom("ilst", Data())
        let meta = try atom("meta", (fullBox ? number(0) : Data()) + hdlr + keys + items)
        return try editMetadata(atoms(meta)[0], values: values)
    }
    static func editMetadata(_ meta: Atom, values: [String: String?]) throws -> Data {
        let parts = try metadataChildren(meta)
        guard try handler(meta) == code("mdta") else { throw ProbeError.unsupported("Metadata handler is not mdta") }
        let keys = try unique(parts.children, "keys").payload
        guard try u32(keys, 0) == 0 else { throw ProbeError.unsupported("Unknown metadata keys version/flags") }
        let count = Int(try u32(keys, 4))
        guard count <= 4096 else { throw ProbeError.unsupported("Metadata key count exceeds budget") }
        var definitions: [(namespace: UInt32, value: Data)] = [], cursor = 8
        for _ in 0..<count {
            let length = Int(try u32(keys, cursor)), namespace = try u32(keys, cursor + 4)
            guard length >= 8, length <= keys.count - cursor else { throw ProbeError.malformed("Metadata key size invalid") }
            definitions.append((namespace, keys.subdata(in: cursor+8..<cursor+length))); cursor += length
        }
        guard cursor == keys.count else { throw ProbeError.malformed("Metadata keys have trailing data") }
        var items = try atoms(unique(parts.children, "ilst").payload)
        guard items.allSatisfy({ $0.type > 0 && $0.type <= UInt32(count) }) else { throw ProbeError.malformed("Metadata item key index invalid") }
        for key in values.keys.sorted() {
            let value = values[key]!
            let matches = definitions.indices.filter { definitions[$0].namespace == code("mdta") && definitions[$0].value == Data(key.utf8) }
            guard matches.count <= 1 else { throw ProbeError.unsupported("Duplicate camera metadata key") }
            let keyIndex: UInt32
            if let existing = matches.first { keyIndex = UInt32(existing + 1) }
            else { definitions.append((code("mdta"), Data(key.utf8))); keyIndex = UInt32(definitions.count) }
            let matchesItems = items.indices.filter { items[$0].type == keyIndex }
            guard matchesItems.count <= 1 else { throw ProbeError.unsupported("Duplicate camera metadata item") }
            guard let value else { items.removeAll { $0.type == keyIndex }; continue }
            let valueAtom = try atom("data", number(1) + number(0) + Data(value.utf8))
            var payload = Data()
            if let item = matchesItems.first {
                for child in try atoms(items[item].payload) {
                    guard ["data", "name", "itif"].map(code).contains(child.type) else { throw ProbeError.unsupported("Unknown camera item structure") }
                    if child.type != code("data") { payload.append(child.raw) }
                }
                payload.append(valueAtom)
                items[item] = try atoms(atom(keyIndex, payload))[0]
            } else { items.append(try atoms(atom(keyIndex, valueAtom))[0]) }
        }
        var keyBody = number(0) + number(UInt32(definitions.count))
        for definition in definitions { keyBody.append(number(UInt32(definition.value.count + 8)) + number(definition.namespace) + definition.value) }
        var body = parts.prefix
        for child in parts.children {
            if child.type == code("keys") { body.append(try atom("keys", keyBody)) }
            else if child.type == code("ilst") { body.append(try atom("ilst", items.reduce(into: Data()) { $0.append($1.raw) })) }
            else { body.append(child.raw) }
        }
        return try atom("meta", body)
    }
}
