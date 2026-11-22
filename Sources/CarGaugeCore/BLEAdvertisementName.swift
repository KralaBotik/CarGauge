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
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.contains { word in
            switch word {
            case "vgate", "icar", "icarpro", "obd", "obdii", "obd2", "elm327": true
            default: false
            }
        }
    }
}
