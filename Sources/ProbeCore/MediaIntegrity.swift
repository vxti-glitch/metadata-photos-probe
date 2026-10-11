import Foundation
import ImageIO
import AVFoundation
import CryptoKit

public enum MediaIntegrity {
    /// A nil patch means an exact preservation comparison, including camera fields.
    /// A supplied patch excludes only deliberately edited fields and verifies their new values.
    public static func compare(source: URL, output: URL, patch: CameraPatch? = nil) async throws -> IntegrityComparison {
        try patch?.validate()
        let before = try await MetadataEngine.inspect(source)
        let after = try await MetadataEngine.inspect(output)
        var checks = [IntegrityCheck](), limitations = [String]()
        func check(_ name: String, _ matches: Bool, _ detail: String) {
            checks.append(IntegrityCheck(name: name, status: matches ? .passed : .failed, detail: detail))
        }
        check("container", before.kind == after.kind, "Source \(before.kind.rawValue), output \(after.kind.rawValue)")
        if let patch {
            let matches = after.metadata["make"] == patch.make && after.metadata["model"] == patch.model &&
                (patch.lens == nil || after.metadata["lens"] == patch.lens)
            check("requested camera metadata", matches, "Read back exactly the requested make/model and any explicitly edited lens.")
        }
        check("retained embedded metadata", retainedMetadata(before.metadata, patch: patch) == retainedMetadata(after.metadata, patch: patch),
              "Preserve inspected non-target fields; a nil patch preserves all inspected camera fields too.")
        check("exposed embedded location", before.location == after.location,
              "Compare exposed embedded location independently from the Photos library location; absent fields do not prove there is no location elsewhere.")
        if before.byteCount == after.byteCount,
           try WholeFileDigest.sha256(source) == WholeFileDigest.sha256(output) {
            check("exact complete file bytes", true, "Whole-file SHA-256 and byte count match. No container, compressed media or opaque metadata bytes changed. Photos UI/provenance remains a separate device observation.")
            return IntegrityComparison(status: checks.contains { $0.status == .failed } ? .mismatch : .verified, checks: checks, limitations: [])
        }
        if before.kind.isImage {
            check("image presentation", before.structure == after.structure, "Compare dimensions, bit depth, orientation, color model/profile and container type.")
            let retained = try retainedImageProperties(source, patch: patch) == retainedImageProperties(output, patch: patch)
            check("ImageIO exposed non-target properties", retained, "Compare properties after excluding only requested camera/lens fields. Unknown private tags are outside this comparison.")
            if before.kind == .jpeg && after.kind == .jpeg {
                let original = try JPEGInventory.read(source), edited = try JPEGInventory.read(output)
                check("JPEG compressed scans and coding segments", original.codingSignatures == edited.codingSignatures,
                    "Independent scan/coding comparison. Source markers: \(markerLabels(original.codingSignatures)); output: \(markerLabels(edited.codingSignatures)).")
                check("JPEG non-target application/color blocks", original.applicationSignatures == edited.applicationSignatures,
                    "Compare ICC, JFIF, comments and all other non-target APP payloads. Source markers: \(markerLabels(original.applicationSignatures)); output: \(markerLabels(edited.applicationSignatures)).")
                limitations += Array(Set(original.limitations + edited.limitations)).sorted()
                limitations.append("Opaque EXIF maker notes and XMP fields not exposed by ImageIO are not fully qualified; this result cannot certify arbitrary originals.")
            } else if before.kind == .png && after.kind == .png {
                check("PNG compressed pixels and non-target chunks", try StillContainerMetadata.pngFingerprint(source) == StillContainerMetadata.pngFingerprint(output),
                    "Hash every PNG chunk except the deliberately edited eXIf chunk. IDAT, alpha, palette, profile and presentation bytes remain exact.")
            } else {
                do {
                    let original = try HEICMetadataWriter.inventory(source), edited = try HEICMetadataWriter.inventory(output)
                    limitations += Array(Set(original.limitations + edited.limitations)).sorted()
                    check("HEIC non-Exif item bytes", original.nonExifItemSHA256 == edited.nonExifItemSHA256,
                          "Independently hash all non-Exif item extents, including coded image, thumbnail and auxiliary items.")
                    check("HEIC item graph and properties", original.itemGraphSHA256 == edited.itemGraphSHA256 &&
                          original.primaryItemID == edited.primaryItemID && original.exifItemID == edited.exifItemID,
                          "Compare the container metadata graph and properties, excluding only the selected Exif locator fields.")
                } catch ProbeError.unsupported(let detail) {
                    checks.append(IntegrityCheck(name: "HEIC item graph", status: .notChecked, detail: detail))
                }
                limitations.append("HEIC iloc/iinf/iref/iprp item graph, primary item, transformations, tiles, auxiliary images, depth and HDR gain maps require an independent full HEIF verifier.")
            }
        } else if !after.kind.isImage {
            // Known inventory loss remains a failure even if an opaque sample stops
            // compressed verification later. Never put these checks in that catch.
            checks += videoStructureChecks(source: before, output: after)
            do {
                let original = try await videoFingerprints(source), edited = try await videoFingerprints(output)
                check("video track count", original.count == edited.count, "Inventory every AVFoundation-exposed track, including audio and metadata.")
                for index in 0..<min(original.count, edited.count) {
                    check("track \(index + 1) compressed data / timing / format", original[index] == edited[index],
                        "Compare encoded samples/timing/format/transform. Source: \(original[index].payloadBytes) encoded bytes, \(original[index].sampleBuffers) buffers, \(original[index].emptyMarkers) empty no-image markers; output: \(edited[index].payloadBytes) encoded bytes, \(edited[index].sampleBuffers) buffers, \(edited[index].emptyMarkers) empty no-image markers. Empty markers have no compressed bytes to verify.")
                }
            } catch {
                let detail = (error as? ProbeError)?.localizedDescription ?? error.localizedDescription
                checks.append(IntegrityCheck(name: "video compressed samples", status: .notChecked, detail: detail))
                limitations.append("Compressed verification unsupported for this structure: \(detail)")
            }
            limitations.append("Track signatures do not prove preservation of all opaque container atoms, edit-list semantics, Dolby Vision/HDR side data, metadata namespaces or AVFoundation-invisible tracks.")
        }
        let status: IntegrityStatus = checks.contains { $0.status == .failed } ? .mismatch : (limitations.isEmpty ? .verified : .incomplete)
        return IntegrityComparison(status: status, checks: checks, limitations: limitations)
    }
    /// Reuses independent encoded-media checks, replacing only the legacy
    /// three-field metadata checks with the exact typed target set.
    public static func compareMetadata(source: URL, output: URL, patch: MetadataPatch) async throws -> IntegrityComparison {
        try patch.validate()
        let before = try await MetadataEngine.inspect(source), after = try await MetadataEngine.inspect(output)
        let baseline = try await compare(source: source, output: output)
        let excluded = Set(["retained embedded metadata", "exposed embedded location", "ImageIO exposed non-target properties"])
        var checks = baseline.checks.filter { !excluded.contains($0.name) }
        do { try patch.validateReadback(after); checks.append(IntegrityCheck(name: "requested metadata", status: .passed, detail: "Every selected value and removal was independently read back.")) }
        catch { checks.append(IntegrityCheck(name: "requested metadata", status: .failed, detail: error.localizedDescription)) }
        var keys = patch.targetedKeys
        if keys.contains("lensModel") {
            keys.insert("lens")
            keys.insert("com.apple.quicktime.camera.lens_model")
            keys.insert("mdta/com.apple.quicktime.camera.lens_model")
            keys.insert("quickTimeMetadata/com.apple.quicktime.camera.lens_model")
            keys.insert("commonIdentifier/cameraLensModel")
            keys.insert("common/cameraLensModel")
            keys.insert("cameraLensModel")
        }
        for (key, raw) in VideoMetadataFields.keys.merging(VideoMetadataFields.trackKeys, uniquingKeysWith: { a, _ in a }) where keys.contains(key) {
            keys.insert(raw)
            keys.insert("mdta/" + raw)
            keys.insert("quickTimeMetadata/" + raw)
            keys.insert("quickTimeUserData/" + raw)
        }
        let legacyUserDataMap: [String: [String]] = [
            "make": ["©mak", "udta/©mak", "quickTimeUserData/©mak", "commonIdentifier/make", "common/make"],
            "model": ["©mod", "udta/©mod", "quickTimeUserData/©mod", "commonIdentifier/model", "common/model"],
            "software": ["©swr", "udta/©swr", "quickTimeUserData/©swr", "commonIdentifier/software", "common/software"],
            "title": ["©nam", "udta/©nam", "quickTimeUserData/©nam", "titl", "udta/titl", "quickTimeUserData/titl", "commonIdentifier/title", "common/title"],
            "copyright": ["©cpr", "udta/©cpr", "quickTimeUserData/©cpr", "cprt", "udta/cprt", "quickTimeUserData/cprt", "commonIdentifier/copyrights", "common/copyright"],
            "artist": ["©ART", "udta/©ART", "quickTimeUserData/©ART", "auth", "udta/auth", "quickTimeUserData/auth", "perf", "udta/perf", "quickTimeUserData/perf", "commonIdentifier/author", "common/artist"],
            "description": ["©des", "udta/©des", "quickTimeUserData/©des", "dscp", "udta/dscp", "quickTimeUserData/dscp", "commonIdentifier/description", "common/description"],
            "dateTimeOriginal": ["commonIdentifier/creationDate", "common/creationDate"]
        ]
        for (target, aliases) in legacyUserDataMap where keys.contains(target) {
            keys.formUnion(aliases)
        }
        if !keys.isDisjoint(with: VideoMetadataFields.gpsKeys) {
            keys.formUnion(VideoMetadataFields.gpsKeys); keys.insert(VideoMetadataFields.locationKey); keys.insert("mdta/" + VideoMetadataFields.locationKey)
            // The writer normalizes or retires ISO `loci`, QuickTime legacy `©xyz`, and
            // container-level ISO 6709 location. Exclude Apple's synthesized common identifier
            // and exact container representations for those selected locations so non-target
            // preservation accurately isolates unselected metadata.
            keys.insert(AVMetadataIdentifier.identifier3GPUserDataLocation.rawValue)
            keys.insert(AVMetadataIdentifier.quickTimeUserDataLocationISO6709.rawValue)
            keys.insert(AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue)
            keys.insert(AVMetadataIdentifier.commonIdentifierLocation.rawValue)
            keys.insert("common/location")
            keys.insert("location")
            keys.insert("udta/©xyz")
            keys.insert("©xyz")
            keys.insert("udta/loci")
            keys.insert("loci")
            keys.insert("3gp/loci")
        }
        let videoDateKeys: Set<String> = [
            "createDate", "modifyDate", "movieCreateDate", "movieModifyDate",
            "trackCreateDate", "trackModifyDate", "mediaCreateDate", "mediaModifyDate",
            "dateTimeOriginal", "com.apple.quicktime.creationdate", "mdta/com.apple.quicktime.creationdate",
            AVMetadataIdentifier.quickTimeMetadataCreationDate.rawValue
        ]
        if !keys.isDisjoint(with: videoDateKeys) {
            keys.formUnion(videoDateKeys)
        }
        let retained = before.metadata.filter { !keys.contains($0.key) } == after.metadata.filter { !keys.contains($0.key) }
        checks.append(IntegrityCheck(name: "retained embedded metadata", status: retained ? .passed : .failed, detail: "Compare all exposed non-target metadata keys; exclude only selected fields and their documented aliases."))
        if patch.targetedKeys.isDisjoint(with: Set(["latitude", "longitude", "altitude", "imageDirection"])) {
            checks.append(IntegrityCheck(name: "exposed embedded location", status: before.location == after.location ? .passed : .failed, detail: "Unedited embedded location remains unchanged."))
        }
        if before.kind.isImage {
            let matches = try retainedImageProperties(source, metadataPatch: patch) == retainedImageProperties(output, metadataPatch: patch)
            checks.append(IntegrityCheck(name: "ImageIO non-target properties", status: matches ? .passed : .failed, detail: "Exclude exact TIFF/EXIF/GPS target property paths; compare all other exposed properties."))
            checks += try imageTargetReadback(output, patch: patch)
        } else {
            checks += try await videoTargetReadback(output, patch: patch)
        }
        let limitations = baseline.limitations.filter { !$0.contains("Unreferenced original Exif bytes remain") }
        return IntegrityComparison(status: checks.contains(where: { $0.status == .failed }) ? .mismatch : (limitations.isEmpty && !checks.contains(where: { $0.status == .notChecked }) ? .verified : .incomplete), checks: checks, limitations: limitations)
    }
    private static func videoTargetReadback(_ url: URL, patch: MetadataPatch) async throws -> [IntegrityCheck] {
        let asset = AVURLAsset(url: url)
        var checks = [IntegrityCheck]()
        var movieItems = [AVMetadataItem]()
        for format in try await asset.load(.availableMetadataFormats) { movieItems += try await asset.loadMetadata(for: format) }
        let tracks = (try await asset.load(.tracks)).filter { $0.mediaType == .video }
        var trackItems = [[AVMetadataItem]]()
        for track in tracks {
            var items = [AVMetadataItem]()
            for format in try await track.load(.availableMetadataFormats) { items += try await track.loadMetadata(for: format) }
            if items.isEmpty {
                items = (try? await track.load(.metadata)) ?? []
            }
            trackItems.append(items)
        }
        let containerInspected = (try? VideoMetadataWriter.inspect(url)) ?? [:]
        for (key, atom) in VideoMetadataFields.keys.merging(VideoMetadataFields.trackKeys, uniquingKeysWith: { a, _ in a }) where patch.targetedKeys.contains(key) {
            let isTrackKey = VideoMetadataFields.trackKeys[key] != nil
            let collections = isTrackKey ? trackItems : [movieItems]
            guard !collections.isEmpty else { checks.append(IntegrityCheck(name: "AVFoundation target \(key)", status: .failed, detail: "No video track is available for target readback.")); continue }
            var matches = false
            if let target = patch.values[key] {
                for collection in collections {
                    let found = collection.filter {
                        $0.identifier?.rawValue == "mdta/" + atom ||
                        $0.identifier?.rawValue == "quickTimeMetadata/" + atom ||
                        $0.identifier?.rawValue == atom ||
                        $0.identifier?.rawValue.hasSuffix("/" + atom) == true ||
                        ($0.key as? String) == atom
                    }
                    if found.isEmpty {
                        // Fallback: If AVFoundation does not deserialize track-level mdta items,
                        // verify directly against the binary container inspector.
                        if let containerVal = containerInspected[atom] ?? containerInspected[key] {
                            if let n = target.number {
                                let scalar = Double(containerVal.hasPrefix("F") ? String(containerVal.dropFirst()) : containerVal)
                                if let scalar, abs(scalar - n) <= MetadataPatch.numericTolerance(for: key, value: n) { matches = true; break }
                            } else {
                                let sanitized = MetadataPatch.sanitizeText(target.text)
                                let trimmed = containerVal.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                                if containerVal == target.text || containerVal == sanitized || trimmed == target.text || trimmed == sanitized { matches = true; break }
                            }
                        }
                    } else {
                        var allItemsMatch = true
                        for item in found {
                            let asyncVal: String? = try? await item.load(.stringValue)
                            guard let value = item.stringValue ?? asyncVal else { allItemsMatch = false; break }
                            if let n = target.number {
                                let scalar = Double(value.hasPrefix("F") ? String(value.dropFirst()) : value)
                                if scalar == nil || abs(scalar! - n) > MetadataPatch.numericTolerance(for: key, value: n) { allItemsMatch = false; break }
                            } else if key.lowercased().contains("date") {
                                let actualDate = try? MetadataPatch.date(value)
                                let targetDate = try? MetadataPatch.date(target.text)
                                if let actualDate, let targetDate {
                                    if abs(actualDate.timeIntervalSince(targetDate)) >= 1 { allItemsMatch = false; break }
                                } else {
                                    let sanitized = MetadataPatch.sanitizeText(target.text)
                                    let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                                    if value != target.text && value != sanitized && trimmed != target.text && trimmed != sanitized { allItemsMatch = false; break }
                                }
                            } else {
                                let sanitized = MetadataPatch.sanitizeText(target.text)
                                let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                                if value != target.text && value != sanitized && trimmed != target.text && trimmed != sanitized { allItemsMatch = false; break }
                            }
                        }
                        if allItemsMatch { matches = true; break }
                    }
                }
            } else {
                matches = collections.allSatisfy { collection in
                    collection.filter {
                        $0.identifier?.rawValue == "mdta/" + atom ||
                        $0.identifier?.rawValue == "quickTimeMetadata/" + atom ||
                        $0.identifier?.rawValue == atom ||
                        $0.identifier?.rawValue.hasSuffix("/" + atom) == true ||
                        ($0.key as? String) == atom
                    }.isEmpty
                }
            }
            checks.append(IntegrityCheck(name: "AVFoundation target \(key)", status: matches ? .passed : .failed, detail: "Read selected UTF-8 camera values from the correct movie/video-track key space with AVFoundation."))
        }
        return checks
    }
    /// Independent ImageIO tag mapping deliberately does not share the TIFF tag
    /// registry or parser used by the writer. Numeric tolerances reflect the
    /// rational quantization of the typed writer, not approximate file quality.
    private static func imageTargetReadback(_ url: URL, patch: MetadataPatch) throws -> [IntegrityCheck] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw ProbeError.readbackFailed("ImageIO cannot read edited image") }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:], exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:], gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        let tiffNames = ["make": "Make", "model": "Model", "software": "Software", "modifyDate": "DateTime", "description": "ImageDescription", "artist": "Artist", "copyright": "Copyright"]
        let exifNames = ["lensMake": "LensMake", "lensModel": "LensModel", "iso": "ISOSpeedRatings", "exposureTime": "ExposureTime", "fNumber": "FNumber", "exposureCompensation": "ExposureBiasValue", "focalLength": "FocalLength", "focalLength35mm": "FocalLenIn35mmFilm", "meteringMode": "MeteringMode", "flash": "Flash", "dateTimeOriginal": "DateTimeOriginal", "createDate": "DateTimeDigitized", "offsetTime": "OffsetTime", "offsetTimeOriginal": "OffsetTimeOriginal", "offsetTimeDigitized": "OffsetTimeDigitized"]
        var checks = [IntegrityCheck]()
        for key in patch.targetedKeys.sorted() {
            var actual: Any?
            if let name = tiffNames[key] { actual = tiff[name] }
            else if let name = exifNames[key] { actual = exif[name] }
            else if let name = ["latitude": "Latitude", "longitude": "Longitude", "altitude": "Altitude", "imageDirection": "ImgDirection"][key] {
                actual = gps[name]
                if let value = actual as? NSNumber {
                    let negative = key == "latitude" ? gps["LatitudeRef"] as? String == "S" : key == "longitude" ? gps["LongitudeRef"] as? String == "W" : key == "altitude" ? (gps["AltitudeRef"] as? NSNumber)?.intValue == 1 : false
                    actual = NSNumber(value: negative ? -value.doubleValue : value.doubleValue)
                }
            } else {
                checks.append(IntegrityCheck(name: "ImageIO target \(key)", status: .notChecked, detail: "This field is read back by the bounded TIFF reader; ImageIO does not expose its public tag in the supported mapping.")); continue
            }
            var matches = false
            if let target = patch.values[key] {
                if let number = target.number {
                    if let array = actual as? [NSNumber] { actual = array.first }
                    if let actual = actual as? NSNumber { matches = abs(actual.doubleValue - number) <= MetadataPatch.numericTolerance(for: key, value: number) }
                } else if let actual = actual as? String {
                    let sanitized = MetadataPatch.sanitizeText(target.text)
                    let trimmed = actual.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                    matches = key.lowercased().contains("date") ? actual == (try MetadataPatch.exifDate(target.text)) : (actual == target.text || actual == sanitized || trimmed == target.text || trimmed == sanitized)
                }
            } else { matches = actual == nil }
            checks.append(IntegrityCheck(name: "ImageIO target \(key)", status: matches ? .passed : .failed, detail: "Read the selected field through Apple's independent image metadata reader."))
        }
        return checks
    }
    private static func retainedImageProperties(_ url: URL, metadataPatch: MetadataPatch) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw ProbeError.malformed("No image properties") }
        let tiffKeys = ["make": "Make", "model": "Model", "software": "Software", "hostComputer": "HostComputer", "modifyDate": "DateTime", "description": "ImageDescription", "artist": "Artist", "copyright": "Copyright", "title": "XPTitle", "keywords": "XPKeywords"]
        let exifKeys = ["lensMake": "LensMake", "lensModel": "LensModel", "iso": "ISOSpeedRatings", "exposureTime": "ExposureTime", "fNumber": "FNumber", "exposureCompensation": "ExposureBiasValue", "focalLength": "FocalLength", "focalLength35mm": "FocalLenIn35mmFilm", "meteringMode": "MeteringMode", "flash": "Flash", "dateTimeOriginal": "DateTimeOriginal", "createDate": "DateTimeDigitized", "offsetTime": "OffsetTime", "offsetTimeOriginal": "OffsetTimeOriginal", "offsetTimeDigitized": "OffsetTimeDigitized"]
        let gpsKeys = ["latitude": ["Latitude", "LatitudeRef"], "longitude": ["Longitude", "LongitudeRef"], "altitude": ["Altitude", "AltitudeRef"], "imageDirection": ["ImgDirection", "ImgDirectionRef"]]
        for (dictionaryKey, mapping) in [(kCGImagePropertyTIFFDictionary as String, tiffKeys), (kCGImagePropertyExifDictionary as String, exifKeys)] {
            if var dictionary = properties[dictionaryKey] as? [String: Any] {
                for key in metadataPatch.targetedKeys { if let name = mapping[key] { dictionary.removeValue(forKey: name) } }
                if dictionary.isEmpty { properties.removeValue(forKey: dictionaryKey) } else { properties[dictionaryKey] = dictionary }
            }
        }
        if var gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            for key in metadataPatch.targetedKeys { for name in gpsKeys[key] ?? [] { gps.removeValue(forKey: name) } }
            // Introduced GPSVersionID identifies the schema, not capture data.
            if !metadataPatch.targetedKeys.isDisjoint(with: Set(gpsKeys.keys)) { gps.removeValue(forKey: kCGImagePropertyGPSVersion as String) }
            if gps.isEmpty { properties.removeValue(forKey: kCGImagePropertyGPSDictionary as String) } else { properties[kCGImagePropertyGPSDictionary as String] = gps }
        }
        // ImageIO mirrors the selected EXIF Software into the PNG dictionary,
        // even when no text chunk was written. The independent PNG fingerprint
        // still compares every original non-eXIf chunk byte, including text.
        if metadataPatch.targetedKeys.contains("software"), var png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
            png.removeValue(forKey: kCGImagePropertyPNGSoftware as String)
            if png.isEmpty { properties.removeValue(forKey: kCGImagePropertyPNGDictionary as String) }
            else { properties[kCGImagePropertyPNGDictionary as String] = png }
        }
        return canonicalValue(properties)
    }

    static func videoStructureChecks(source: MediaInspection, output: MediaInspection) -> [IntegrityCheck] {
        let tracksMatch = source.structure["tracks"] == output.structure["tracks"] &&
            source.structure["trackTypes"] == output.structure["trackTypes"]
        let durationMatches = source.structure["duration"] == output.structure["duration"]
        return [
            IntegrityCheck(name: "video exposed track inventory", status: tracksMatch ? .passed : .failed,
                detail: "Source tracks/types: \(source.structure["tracks"] ?? "missing") / \(source.structure["trackTypes"] ?? "missing"); output: \(output.structure["tracks"] ?? "missing") / \(output.structure["trackTypes"] ?? "missing"). Independent of compressed sample support."),
            IntegrityCheck(name: "video exposed duration", status: durationMatches ? .passed : .failed,
                detail: "Source \(source.structure["duration"] ?? "missing"), output \(output.structure["duration"] ?? "missing"). Independent of compressed sample support.")
        ]
    }

    private static func markerLabels(_ signatures: [String]) -> String {
        signatures.map { String($0.prefix(24)) }.joined(separator: ",")
    }

    private static func retainedMetadata(_ metadata: [String: String], patch: CameraPatch?) -> [String: String] {
        guard let patch else { return metadata }
        var retained = metadata
        let cameraKeys: Set<String> = [
            "make", "model",
            "com.apple.quicktime.make", "com.apple.quicktime.model",
            "mdta/com.apple.quicktime.make", "mdta/com.apple.quicktime.model",
            "quickTimeMetadata/com.apple.quicktime.make", "quickTimeMetadata/com.apple.quicktime.model",
            "quickTimeUserData/©mak", "quickTimeUserData/©mod",
            "commonIdentifier/make", "commonIdentifier/model",
            "common/make", "common/model",
            "©mak", "©mod", "udta/©mak", "udta/©mod",
            AVMetadataIdentifier.quickTimeMetadataMake.rawValue,
            AVMetadataIdentifier.quickTimeMetadataModel.rawValue
        ]
        for key in cameraKeys { retained.removeValue(forKey: key) }
        if patch.lens != nil {
            let lensKeys: Set<String> = [
                "lens", "lensModel",
                "com.apple.quicktime.camera.lens_model",
                "mdta/com.apple.quicktime.camera.lens_model",
                "quickTimeMetadata/com.apple.quicktime.camera.lens_model"
            ]
            for key in lensKeys { retained.removeValue(forKey: key) }
        }
        return retained
    }

    private static func retainedImageProperties(_ url: URL, patch: CameraPatch?) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw ProbeError.malformed("No image properties") }
        if patch != nil, var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFMake as String)
            tiff.removeValue(forKey: kCGImagePropertyTIFFModel as String)
            if tiff.isEmpty { properties.removeValue(forKey: kCGImagePropertyTIFFDictionary as String) }
            else { properties[kCGImagePropertyTIFFDictionary as String] = tiff }
        }
        if patch?.lens != nil, var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifLensModel as String)
            if exif.isEmpty { properties.removeValue(forKey: kCGImagePropertyExifDictionary as String) }
            else { properties[kCGImagePropertyExifDictionary as String] = exif }
        }
        return canonicalValue(properties)
    }

    private struct TrackFingerprint: Equatable {
        let hash: String
        let payloadBytes: Int64
        let sampleBuffers: Int
        let emptyMarkers: Int
    }

    private static func videoFingerprints(_ url: URL) async throws -> [TrackFingerprint] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard tracks.count <= 64 else { throw ProbeError.unsupported("More than 64 tracks exceeds controlled-fixture bounds") }
        var fingerprints = [TrackFingerprint]()
        for track in tracks {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ProbeError.unsupported("Compressed reader unavailable for track \(track.trackID)") }
            reader.add(output)
            let range = try await track.load(.timeRange)
            let transform = try await track.load(.preferredTransform)
            let dimensions = try await track.load(.naturalSize)
            var digest = SHA256(), count = 0, emptyMarkers = 0
            var payloadBytes: Int64 = 0
            func update(_ string: String) { digest.update(data: Data((string + "\n").utf8)) }
            update(track.mediaType.rawValue)
            update(canonicalTime(range.start)); update(canonicalTime(range.duration))
            update("\(transform.a),\(transform.b),\(transform.c),\(transform.d),\(transform.tx),\(transform.ty)")
            update("\(dimensions.width),\(dimensions.height)")
            guard reader.startReading() else { throw reader.error ?? ProbeError.malformed("Cannot start compressed reader") }
            do {
                while let sample = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    count += 1
                    guard count <= 1_000_000 else { throw ProbeError.unsupported("Sample count exceeds controlled-fixture bounds") }
                    update("buffer \(count) samples \(CMSampleBufferGetNumSamples(sample))")
                    update(canonicalTime(CMSampleBufferGetPresentationTimeStamp(sample)))
                    update(canonicalTime(CMSampleBufferGetDecodeTimeStamp(sample)))
                    update(canonicalTime(CMSampleBufferGetDuration(sample)))
                    for index in 0..<CMSampleBufferGetNumSamples(sample) {
                        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
                        let code = CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing)
                        guard code == noErr else { throw ProbeError.malformed("Cannot inspect sample timing: \(code)") }
                        update("\(CMSampleBufferGetSampleSize(sample, at: index)):\(canonicalTime(timing.presentationTimeStamp)):\(canonicalTime(timing.decodeTimeStamp)):\(canonicalTime(timing.duration))")
                    }
                    if let format = CMSampleBufferGetFormatDescription(sample) {
                        update("\(CMFormatDescriptionGetMediaType(format)):\(CMFormatDescriptionGetMediaSubType(format))")
                        if let extensions = CMFormatDescriptionGetExtensions(format) {
                            update(canonicalValue(extensions as NSDictionary))
                        } else { update("no format extensions") }
                    }
                    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) {
                        update(canonicalValue(attachments as NSArray))
                    }
                    if let block = CMSampleBufferGetDataBuffer(sample) {
                        let length = CMBlockBufferGetDataLength(block)
                        payloadBytes += Int64(length)
                        var offset = 0
                        while offset < length {
                            let amount = min(1_048_576, length - offset)
                            var bytes = Data(count: amount)
                            let status = bytes.withUnsafeMutableBytes { pointer in
                                CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: amount, destination: pointer.baseAddress!)
                            }
                            guard status == noErr else { throw ProbeError.malformed("Cannot inspect compressed sample bytes: \(status)") }
                            digest.update(data: bytes); offset += amount
                        }
                    } else {
                        let totalSize = CMSampleBufferGetTotalSampleSize(sample)
                        let hasImage = CMSampleBufferGetImageBuffer(sample) != nil
                        guard totalSize == 0, !hasImage else {
                            throw ProbeError.unsupported("Track \(track.trackID) sample \(count) lacks a compressed data block: count=\(CMSampleBufferGetNumSamples(sample)), totalSize=\(totalSize), imageBuffer=\(hasImage), mediaType=\(track.mediaType.rawValue). Decoded/opaque data cannot be certified.")
                        }
                        emptyMarkers += 1
                        update("empty-no-image-marker")
                    }
                }
                guard reader.status == .completed else { throw reader.error ?? ProbeError.malformed("Compressed reader did not complete") }
            } catch { reader.cancelReading(); throw error }
            if (track.mediaType == .video || track.mediaType == .audio), payloadBytes == 0,
               CMTimeCompare(range.duration, .zero) > 0 {
                throw ProbeError.unsupported("Track \(track.trackID) has positive duration but zero independently accessible encoded bytes (\(emptyMarkers) empty markers). Encoded preservation cannot be certified.")
            }
            update("total \(count)")
            fingerprints.append(TrackFingerprint(hash: digest.finalize().map { String(format: "%02x", $0) }.joined(), payloadBytes: payloadBytes, sampleBuffers: count, emptyMarkers: emptyMarkers))
        }
        return fingerprints
    }
}

/// Stable representation independent of NSDictionary iteration order.
func canonicalValue(_ value: Any) -> String {
    if let data = value as? Data { return "data:" + data.base64EncodedString() }
    if let dictionary = value as? [String: Any] {
        return "{" + dictionary.keys.sorted().map { "\($0.utf8.count):\($0)=\(canonicalValue(dictionary[$0]!))" }.joined(separator: ";") + "}"
    }
    if let array = value as? [Any] { return "[" + array.map(canonicalValue).joined(separator: ";") + "]" }
    if let string = value as? String { return "s\(string.utf8.count):\(string)" }
    if let number = value as? NSNumber { return "n\(String(cString: number.objCType)):\(number.stringValue)" }
    return "\(type(of: value)):\(String(describing: value))"
}
