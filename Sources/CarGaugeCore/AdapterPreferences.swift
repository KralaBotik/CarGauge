import Foundation

public struct AdapterPreferences {
    private struct VerifiedAdapter: Codable {
        let id: UUID
        let name: String?
    }

    private let defaults: UserDefaults
    private static let verifiedKey = "verifiedOBDAdapter"
    private static let legacyKey = "selectedBLEPeripheral"

    public init(defaults: UserDefaults) { self.defaults = defaults }

    private var verified: VerifiedAdapter? {
        defaults.data(forKey: Self.verifiedKey).flatMap { try? JSONDecoder().decode(VerifiedAdapter.self, from: $0) }
    }

    public var verifiedID: UUID? { verified?.id }
    public var name: String? { BLEAdvertisementName.clean(verified?.name) }
    // A 0.3 installation could save a selection before verifying ELM and the coolant PID.
    public var preferredID: UUID? {
        verifiedID ?? defaults.string(forKey: Self.legacyKey).flatMap(UUID.init(uuidString:))
    }

    @discardableResult
    public func confirm(id: UUID, name: String?, coolant: Reading, at now: Date) -> Bool {
        guard coolant.isFresh(at: now) else { return false }
        let confirmedName = BLEAdvertisementName.clean(name) ?? (verifiedID == id ? self.name : nil)
        guard let encoded = try? JSONEncoder().encode(VerifiedAdapter(id: id, name: confirmedName)) else { return false }
        defaults.set(encoded, forKey: Self.verifiedKey)
        defaults.removeObject(forKey: Self.legacyKey)
        return true
    }

    public func clear() {
        defaults.removeObject(forKey: Self.verifiedKey)
        defaults.removeObject(forKey: Self.legacyKey)
    }
}
