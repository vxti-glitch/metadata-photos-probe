import Foundation
import ImageIO
import AVFoundation
import CryptoKit

public enum MediaIntegrity {
    public static func compare(source: URL, output: URL) async throws -> IntegrityComparison {
        let before = try await MetadataEngine.inspect(source)
        let after = try await MetadataEngine.inspect(output)
        var checks = [IntegrityCheck](), limitations = [String]()
        func check(_ name: String, _ matches: Bool, _ detail: String) {
            checks.append(IntegrityCheck(name: name, status: matches ? .passed : .failed, detail: detail))
        }
        check("container", before.kind == after.kind, "Source \(before.kind.rawValue), output \(after.kind.rawValue)")
        if before.kind.isImage {
            check("image presentation", before.structure == after.structure, "Compare dimensions, bit depth, orientation, color model/profile and container type.")
            let retained = try retainedImageProperties(source) == retainedImageProperties(output)
            check("ImageIO exposed non-target properties", retained, "Compare properties after excluding only requested camera/lens fields. Unknown private tags are outside this comparison.")
            if before.kind == .jpeg && after.kind == .jpeg {
                let original = try JPEGInventory.read(source), edited = try JPEGInventory.read(output)
                check("JPEG compressed scans and coding/color blocks", original.signatures == edited.signatures,
                    "Independent marker parser compares every scan, coding segment, ICC block and non-EXIF/XMP segment in order.")
                limitations += Array(Set(original.limitations + edited.limitations)).sorted()
                limitations.append("Opaque EXIF maker notes and XMP fields not exposed by ImageIO are not fully qualified; this result cannot certify arbitrary originals.")
            } else {
                let original = try BoxInventory.read(source), edited = try BoxInventory.read(output)
                let same = !original.payloadHashes.isEmpty && original.payloadHashes == edited.payloadHashes
                checks.append(IntegrityCheck(name: "HEIC mdat bytes", status: same ? .passed : .notChecked,
                    detail: same ? "Top-level media payload bytes match; item graph semantics remain unverified." : "Media payload layout differs; item-level identity cannot be inferred from this comparison."))
                limitations.append("HEIC iloc/iinf/iref/iprp item graph, primary item, transformations, tiles, auxiliary images, depth and HDR gain maps require an independent full HEIF verifier.")
            }
        } else if !after.kind.isImage {
            let original = try await videoFingerprints(source), edited = try await videoFingerprints(output)
            check("video track count", original.count == edited.count, "Inventory every AVFoundation-exposed track, including audio and metadata.")
            for index in 0..<min(original.count, edited.count) {
                check("track \(index + 1) compressed data / timing / format", original[index] == edited[index],
                    "Uncompressed-reader settings are never used. Compare encoded sample bytes, per-sample sizes/counts, timing, attachments, format extensions and track transforms.")
            }
            limitations.append("Track signatures do not prove preservation of all opaque container atoms, edit-list semantics, Dolby Vision/HDR side data, metadata namespaces or AVFoundation-invisible tracks.")
        }
        let status: IntegrityStatus = checks.contains { $0.status == .failed } ? .mismatch : (limitations.isEmpty ? .verified : .incomplete)
        return IntegrityComparison(status: status, checks: checks, limitations: limitations)
    }

    private static func retainedImageProperties(_ url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw ProbeError.malformed("No image properties") }
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFMake as String)
            tiff.removeValue(forKey: kCGImagePropertyTIFFModel as String)
            if tiff.isEmpty { properties.removeValue(forKey: kCGImagePropertyTIFFDictionary as String) }
            else { properties[kCGImagePropertyTIFFDictionary as String] = tiff }
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifLensModel as String)
            if exif.isEmpty { properties.removeValue(forKey: kCGImagePropertyExifDictionary as String) }
            else { properties[kCGImagePropertyExifDictionary as String] = exif }
        }
        return canonicalValue(properties)
    }

    private static func videoFingerprints(_ url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard tracks.count <= 64 else { throw ProbeError.unsupported("More than 64 tracks exceeds controlled-fixture bounds") }
        var fingerprints = [String]()
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
            var digest = SHA256(), count = 0
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
                        update(canonicalValue(CMFormatDescriptionGetExtensions(format) as NSDictionary))
                    }
                    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) {
                        update(canonicalValue(attachments as NSArray))
                    }
                    if let block = CMSampleBufferGetDataBuffer(sample) {
                        let length = CMBlockBufferGetDataLength(block)
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
                    } else { throw ProbeError.unsupported("Track sample has no compressed data block") }
                }
                guard reader.status == .completed else { throw reader.error ?? ProbeError.malformed("Compressed reader did not complete") }
            } catch { reader.cancelReading(); throw error }
            update("total \(count)")
            fingerprints.append(digest.finalize().map { String(format: "%02x", $0) }.joined())
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
