import Foundation
import CoreFoundation

public enum EmbeddedLocationState: String, Codable, Sendable { case present, notFound, incomplete }

/// Exposed file metadata only. Photos' independently indexed location is a separate layer.
public struct EmbeddedLocationEvidence: Codable, Sendable, Equatable {
    public let state: EmbeddedLocationState
    public let values: [String: String]
    public let latitude: Double?
    public let longitude: Double?
    public let summary: String

    public static func image(gps: [String: Any]?) -> Self {
        guard let gps, !gps.isEmpty else { return absent }
        let values = gps.mapValues(canonicalValue)
        func coordinate(_ key: String, _ reference: String, positive: String, negative: String, limit: Double) -> Double? {
            guard let number = gps[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let ref = gps[reference] as? String else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= limit, [positive, negative].contains(ref) else { return nil }
            return ref == negative ? -value : value
        }
        let lat = coordinate("Latitude", "LatitudeRef", positive: "N", negative: "S", limit: 90)
        let lon = coordinate("Longitude", "LongitudeRef", positive: "E", negative: "W", limit: 180)
        return Self(state: lat != nil && lon != nil ? .present : .incomplete, values: values,
                    latitude: lat, longitude: lon,
                    summary: lat != nil && lon != nil ? "Embedded GPS coordinates found" : "GPS fields found; coordinates incomplete or invalid")
    }

    public static func video(metadata: [String: String]) -> Self {
        let values = metadata.filter { $0.key.lowercased().contains("location") }
        guard !values.isEmpty else { return absent }
        // Qualify only decimal ISO 6709 coordinates; retain unsupported representations verbatim.
        let pattern = "^([+-][0-9]{2}(?:\\.[0-9]+)?)([+-][0-9]{3}(?:\\.[0-9]+)?)(?:[+-][0-9]+(?:\\.[0-9]+)?)?/$"
        let expression = try? NSRegularExpression(pattern: pattern)
        let candidates = values.filter { $0.key.lowercased().contains("iso6709") }
        var coordinates = [(Double, Double)]()
        for value in candidates.values {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if let match = expression?.firstMatch(in: value, range: range),
               let a = Range(match.range(at: 1), in: value), let b = Range(match.range(at: 2), in: value),
               let lat = Double(value[a]), let lon = Double(value[b]),
               lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 { coordinates.append((lat, lon)) }
        }
        let consistent = coordinates.count == candidates.count && !coordinates.isEmpty &&
            coordinates.allSatisfy { $0.0 == coordinates[0].0 && $0.1 == coordinates[0].1 }
        return Self(state: consistent ? .present : .incomplete, values: values,
                    latitude: consistent ? coordinates[0].0 : nil, longitude: consistent ? coordinates[0].1 : nil,
                    summary: consistent ? "Embedded video location found" : "Location tags found; coordinates incomplete or unsupported")
    }

    private static var absent: Self {
        Self(state: .notFound, values: [:], latitude: nil, longitude: nil,
             summary: "Location not found in exposed embedded metadata")
    }
}
