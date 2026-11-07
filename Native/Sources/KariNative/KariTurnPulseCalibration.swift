import Foundation

/// Measured angle of one `look_right` pulse. Angle math reads this record; nothing invents a default.
struct TurnPulseCalibration: Codable, Equatable {
    var scenario: String
    var degreesPerPulse: Double
    var samplePulses: Int
    var measuredAt: Date

    static let defaultsKey = "kari.turn.calibration.v1"

    /// `degreesPerPulse = 360 / samplePulses`. Nil when the ritual recorded no completed pulse.
    static func measured(samplePulses: Int, at measuredAt: Date) -> TurnPulseCalibration? {
        guard samplePulses > 0 else { return nil }
        return TurnPulseCalibration(scenario: "look_right", degreesPerPulse: 360 / Double(samplePulses), samplePulses: samplePulses, measuredAt: measuredAt)
    }

    static func load(from defaults: UserDefaults) -> TurnPulseCalibration? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(TurnPulseCalibration.self, from: data)
    }

    static func store(_ value: TurnPulseCalibration?, in defaults: UserDefaults) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}
