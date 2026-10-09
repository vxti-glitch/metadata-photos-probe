import Foundation

/// Primitive JSON values with a closed, format-aware field registry. No untrusted
/// field can become a TIFF pointer, atom name, path or command-line argument.
public enum MetadataValue: Codable, Sendable, Equatable {
    case string(String), number(Double)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(String.self) { self = .string(value) }
        else { self = .number(try c.decode(Double.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v) }
    }
    public var text: String {
        switch self { case .string(let v): return v; case .number(let v): return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), v) }
    }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
}

public struct MetadataPatch: Codable, Sendable, Equatable {
    public var values: [String: MetadataValue]
    public var removals: [String]
    public init(values: [String: MetadataValue] = [:], removals: [String] = []) { self.values = values; self.removals = removals }
    public var targetedKeys: Set<String> { Set(values.keys).union(removals) }
    public static let stringKeys = Set(["make", "model", "lensMake", "lensModel", "hostComputer", "software", "dateTimeOriginal", "createDate", "modifyDate", "offsetTime", "offsetTimeOriginal", "offsetTimeDigitized", "title", "description", "artist", "copyright", "keywords", "movieCreateDate", "movieModifyDate", "trackCreateDate", "trackModifyDate", "mediaCreateDate", "mediaModifyDate"])
    public static let numericRanges: [String: ClosedRange<Double>] = ["iso": 1...65535, "exposureTime": 0.000000001...86400, "fNumber": 0.01...256, "exposureCompensation": -128...128, "focalLength": 0.01...65535, "focalLength35mm": 1...65535, "meteringMode": 0...255, "flash": 0...127, "latitude": -90...90, "longitude": -180...180, "altitude": -100000...100000, "imageDirection": 0...359.999999]
    public static let allKeys = stringKeys.union(numericRanges.keys)
    public static func supportedKeys(for kind: MediaKind) -> [String] {
        (kind.isImage ? Set(ExifMetadataEditor.fields.keys) : VideoMetadataFields.supported).sorted()
    }
    public func validate() throws {
        guard values.count <= 64, removals.count <= 64, Set(removals).count == removals.count,
              Set(values.keys).isDisjoint(with: removals), targetedKeys.isSubset(of: Self.allKeys) else { throw ProbeError.invalidPatch }
        for (key, value) in values {
            if Self.stringKeys.contains(key) {
                guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 1024,
                      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ProbeError.invalidPatch }
                if key.hasPrefix("offsetTime") { guard text.range(of: "^[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00)$", options: .regularExpression) != nil else { throw ProbeError.invalidPatch } }
                if key.lowercased().contains("date") { _ = try Self.date(text) }
            } else {
                guard let n = value.number, n.isFinite, Self.numericRanges[key]?.contains(n) == true else { throw ProbeError.invalidPatch }
                if ["iso", "flash", "meteringMode", "focalLength35mm"].contains(key), n.rounded() != n { throw ProbeError.invalidPatch }
            }
        }
    }
    public static func date(_ text: String) throws -> Date {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { try validateISOWallTime(text); return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { try validateISOWallTime(text); return date }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.isLenient = false
        guard text.count == 19, let date = f.date(from: text), f.string(from: date) == text else { throw ProbeError.invalidPatch }
        return date
    }
    private static func validateISOWallTime(_ text: String) throws {
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00))$", options: .regularExpression) != nil else { throw ProbeError.invalidPatch }
        let wall = String(text.prefix(19)).replacingOccurrences(of: "-", with: ":").replacingOccurrences(of: "T", with: " ")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.isLenient = false
        guard let date = f.date(from: wall), f.string(from: date) == wall else { throw ProbeError.invalidPatch }
    }
    public static func exifDate(_ text: String) throws -> String {
        if text.range(of: "^\\d{4}:\\d{2}:\\d{2} \\d{2}:\\d{2}:\\d{2}$", options: .regularExpression) != nil { _ = try date(text); return text }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.string(from: try date(text))
    }
    public func validateReadback(_ inspection: MediaInspection) throws {
        for (key, value) in values {
            guard let actual = inspection.metadata[key] else { throw ProbeError.readbackFailed("Missing requested \(key)") }
            if let n = value.number {
                guard let result = Double(actual), abs(result - n) <= Self.numericTolerance(for: key, value: n) else { throw ProbeError.readbackFailed("\(key) differs from requested numeric value") }
            } else if key.lowercased().contains("date") {
                guard abs((try Self.date(actual)).timeIntervalSince(try Self.date(value.text))) < 1 else { throw ProbeError.readbackFailed("\(key) date differs") }
            } else if actual != value.text { throw ProbeError.readbackFailed("\(key) differs from requested value") }
        }
        for key in removals { guard inspection.metadata[key] == nil else { throw ProbeError.readbackFailed("Removed \(key) remains present") } }
    }
    public static func numericTolerance(for key: String, value: Double) -> Double {
        if ["latitude", "longitude"].contains(key) { return 0.000001 }
        if key == "exposureTime" { return max(1e-12, abs(value) * 1e-6) }
        return max(0.000001, abs(value) * 0.000001)
    }
}
