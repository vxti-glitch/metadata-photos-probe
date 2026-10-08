import Foundation
import AVFoundation

enum VideoMetadataFields {
    static let keys: [String: String] = ["make": "com.apple.quicktime.make", "model": "com.apple.quicktime.model", "software": "com.apple.quicktime.software", "title": "com.apple.quicktime.title", "description": "com.apple.quicktime.description", "artist": "com.apple.quicktime.artist", "copyright": "com.apple.quicktime.copyright", "keywords": "com.apple.quicktime.keywords", "dateTimeOriginal": "com.apple.quicktime.creationdate"]
    static var trackKeys: [String: String] {
        var keys = ["lensModel": "com.apple.quicktime.camera.lens_model", "focalLength35mm": "com.apple.quicktime.camera.focal_length.35mm_equivalent", "iso": "org.smpte.rdd18.camera.isosensitivity", "exposureTime": "org.smpte.rdd18.camera.shutterspeed_time", "fNumber": "org.smpte.rdd18.lens.irisfnumber"]
        // Use Apple's SDK identifiers on the actual target OS rather than
        // guessing keys introduced with its camera metadata API in iOS 26.
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
            func key(_ identifier: AVMetadataIdentifier) -> String {
                let raw = identifier.rawValue
                return raw.hasPrefix("mdta/") ? String(raw.dropFirst(5)) : raw
            }
            keys["iso"] = key(.quickTimeMetadataCameraISOSensitivity)
            keys["exposureTime"] = key(.quickTimeMetadataCameraShutterSpeedTime)
            keys["fNumber"] = key(.quickTimeMetadataCameraLensIrisFNumber)
            keys["lensModel"] = key(.quickTimeMetadataCameraLensModel)
            keys["focalLength35mm"] = key(.quickTimeMetadataCameraFocalLength35mmEquivalent)
        }
        #endif
        return keys
    }
    static let dateKeys = Set(["movieCreateDate", "movieModifyDate", "trackCreateDate", "trackModifyDate", "mediaCreateDate", "mediaModifyDate", "createDate", "modifyDate"])
    static let gpsKeys = Set(["latitude", "longitude", "altitude"])
    static let supported = Set(keys.keys).union(trackKeys.keys).union(dateKeys).union(gpsKeys)
    static let locationKey = "com.apple.quicktime.location.ISO6709"
    static func values(_ patch: MetadataPatch, existing: [String: String], track: Bool) throws -> [String: String?] {
        var result = [String: String?]()
        for (key, atom) in (track ? trackKeys : keys) where patch.targetedKeys.contains(key) { result[atom] = .some(patch.values[key]?.text) }
        if !track, !patch.targetedKeys.isDisjoint(with: gpsKeys) {
            if patch.removals.contains("latitude") || patch.removals.contains("longitude") { result[locationKey] = .some(nil) }
            else {
                let lat = patch.values["latitude"]?.number ?? existing["latitude"].flatMap(Double.init)
                let lon = patch.values["longitude"]?.number ?? existing["longitude"].flatMap(Double.init)
                guard let lat, let lon else { throw ProbeError.invalidPatch }
                let altitude = patch.removals.contains("altitude") ? nil : patch.values["altitude"]?.number ?? existing["altitude"].flatMap(Double.init)
                let locale = Locale(identifier: "en_US_POSIX")
                let base = String(format: "%+010.6f%+011.6f", locale: locale, lat, lon)
                result[locationKey] = .some(base + (altitude.map { String(format: "%+.3f", locale: locale, $0) } ?? "") + "/")
            }
        }
        return result
    }
    static func decodeLocation(_ text: String) -> [String: String] {
        let regex = try? NSRegularExpression(pattern: "^([+-][0-9]{2}(?:\\.[0-9]+)?)([+-][0-9]{3}(?:\\.[0-9]+)?)([+-][0-9]+(?:\\.[0-9]+)?)?/$")
        guard let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [:] }
        var result = [String: String]()
        for (index, key) in [(1, "latitude"), (2, "longitude"), (3, "altitude")] {
            if let range = Range(match.range(at: index), in: text), let value = Double(text[range]) { result[key] = MetadataValue.number(value).text }
        }
        return result
    }
}
