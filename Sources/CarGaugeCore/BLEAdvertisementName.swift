import Foundation

public enum BLEAdvertisementName {
    public static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.filter { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
            switch scalar.value {
            case 0x061C, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069: return false
            default: return scalar.properties.generalCategory != .control
            }
        }
        let name = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    public static func preferred(advertised: String?, peripheral: String?, previousAdvertisement: String?) -> String {
        clean(advertised) ?? clean(previousAdvertisement) ?? clean(peripheral) ?? ""
    }

    public static func isLikelyOBD(_ name: String) -> Bool {
        let words = name.precomposedStringWithCompatibilityMapping.lowercased().split { !$0.isLetter && !$0.isNumber }
        if words == ["android", "vlink"] { return false }
        return words.contains { word in
            switch word {
            case "vgate", "icar", "icarpro", "obd", "obdii", "obd2", "elm327", "vlink": true
            default: false
            }
        }
    }

    public static func disambiguatingID(_ identifier: UUID, against peers: [UUID]) -> String {
        let full = identifier.uuidString
        let suffix = full.suffix(8)
        return peers.contains { $0.uuidString.suffix(8) == suffix } ? full : String(suffix)
    }
}
