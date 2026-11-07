import Foundation

/// v1 hole: only clockwise, one revolution. Left and multi-turn stay out of this type.
struct SpinSpec: Equatable {
    enum Sense: Equatable { case clockwise }
    enum Revolutions: Equatable { case one }
    var sense: Sense
    var revolutions: Revolutions
    static let v1 = SpinSpec(sense: .clockwise, revolutions: .one)
    var turnCount: Double { 1 }
}

enum SpinExpansion: Equatable {
    case plan(MotionPlan)
    case refused(String)
}

enum SpinExpander {
    /// Matches `MotionCount` and `MotionPlan.make`. Not raised to fit a larger circle.
    static let pulsesPerStep = 20
    static let maxSteps = 8

    static func pulseCount(degreesPerPulse: Double, revolutions: Double) -> Int? {
        guard degreesPerPulse > 0, revolutions > 0, degreesPerPulse.isFinite, revolutions.isFinite else { return nil }
        let quotient = 360.0 * revolutions / degreesPerPulse
        guard quotient.isFinite, quotient > 0, quotient < Double(Int.max) else { return nil }
        // `360 / (360 / n)` is n, but the division is not always exact in binary.
        let nearest = quotient.rounded()
        let stable = abs(quotient - nearest) < 1e-6 ? nearest : quotient
        let count = Int(stable.rounded(.up))
        return count > 0 ? count : nil
    }

    static func expand(_ spec: SpinSpec, calibration: TurnPulseCalibration) -> SpinExpansion {
        guard spec.sense == .clockwise, spec.revolutions == .one else {
            return .refused("这一版只支持向右转一圈，小车保持不动")
        }
        guard calibration.scenario == MotionDirection.right.scenario else {
            return .refused("转一圈的标定不是右转脉冲，请在设置里重新标定")
        }
        guard let pulses = pulseCount(degreesPerPulse: calibration.degreesPerPulse, revolutions: spec.turnCount) else {
            return .refused("转一圈的标定无效，请在设置里重新标定")
        }
        guard pulses <= pulsesPerStep * maxSteps else {
            return .refused("转一圈需要 \(pulses) 次右转，一次最多 \(maxSteps) 步、每步 \(pulsesPerStep) 次，装不下，小车保持不动")
        }
        var requested: [(MotionDirection, Int)] = []
        var remaining = pulses
        while remaining > 0 {
            let count = min(pulsesPerStep, remaining)
            requested.append((.right, count))
            remaining -= count
        }
        switch MotionPlan.make(requested) {
        case .success(let plan):
            guard plan.pulseCount == pulses, plan.steps.allSatisfy({ $0.direction == .right }) else {
                return .refused("转一圈的计划无效，小车保持不动")
            }
            return .plan(plan)
        case .failure(let error):
            return .refused(error.localizedDescription)
        }
    }
}

enum ChassisIntentResult: Equatable {
    case plan(MotionPlan)
    case needsCalibration
    case refused(String)

    var userReason: String {
        switch self {
        case .plan: ""
        case .needsCalibration: ChassisIntent.needsCalibrationMessage
        case .refused(let reason): reason
        }
    }
}

enum ChassisIntent {
    static let needsCalibrationMessage = "还没标定转一圈，请先在设置里标定"

    /// Nil when the words are not a chassis command. Circle phrases are resolved before `MotionPlan.parse`.
    static func resolve(utterance text: String, calibration: TurnPulseCalibration?) -> ChassisIntentResult? {
        if let spec = spinSpec(utterance: text) { return expand(spec, calibration: calibration) }
        guard let parsed = MotionPlan.parse(utterance: text) else { return nil }
        switch parsed {
        case .success(let plan): return .plan(plan)
        case .failure(let error): return .refused(error.localizedDescription)
        }
    }

    /// A `spin` object wins over `steps`, so a guessed pulse count in the same call is not driven.
    static func resolve(wire object: [String: Any], calibration: TurnPulseCalibration?) -> ChassisIntentResult {
        if hasSpinIntent(object) {
            switch parsedSpin(object) {
            case .spec(let spec): return expand(spec, calibration: calibration)
            case .refused(let reason): return .refused(reason)
            }
        }
        switch MotionPlan.parse(wire: object) {
        case .success(let plan): return .plan(plan)
        case .failure(let error): return .refused(error.localizedDescription)
        }
    }

    static func isCircleUtterance(_ text: String) -> Bool { spinSpec(utterance: text) != nil }

    private static func expand(_ spec: SpinSpec, calibration: TurnPulseCalibration?) -> ChassisIntentResult {
        guard let calibration else { return .needsCalibration }
        switch SpinExpander.expand(spec, calibration: calibration) {
        case .plan(let plan): return .plan(plan)
        case .refused(let reason): return .refused(reason)
        }
    }

    /// Same wake and polite prefix as `MotionPlan.parse`. `spin` / `spin once` are already direct commands.
    private static func spinSpec(utterance text: String) -> SpinSpec? {
        guard text.count <= 240 else { return nil }
        let value = normalized(text)
        let pattern = #"^(?:你好卡里|嘿卡里|heykari|kari|卡里)?(?:请你|请|帮我|给我|麻烦你|please)?(?:转一圈|转圈|spin)(?:一下|一点|一会儿|一次|abit|alittle|once|for[0-9]+seconds?)?(?:吧|好吗|可以吗|please)?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return .v1
    }

    private static func hasSpinIntent(_ object: [String: Any]) -> Bool {
        guard let spin = object["spin"], !(spin is NSNull) else { return false }
        if let flag = spin as? Bool { return flag }
        return spin is [String: Any]
    }

    private enum ParsedSpin {
        case spec(SpinSpec)
        case refused(String)
    }

    private static func parsedSpin(_ object: [String: Any]) -> ParsedSpin {
        guard let spin = object["spin"] else { return .refused("转圈参数无效，小车保持不动") }
        if let flag = spin as? Bool { return flag ? .spec(.v1) : .refused("转圈参数无效，小车保持不动") }
        guard let payload = spin as? [String: Any] else { return .refused("转圈参数无效，小车保持不动") }
        if ["count", "pulses", "steps", "degrees", "degree"].contains(where: { payload[$0] != nil }) {
            return .refused("转一圈不能由模型填写次数，小车保持不动")
        }
        if let sense = payload["sense"] as? String {
            guard sense == "clockwise" else { return .refused("这一版只支持向右转一圈，小车保持不动") }
        } else if payload["sense"] != nil {
            return .refused("转圈参数无效，小车保持不动")
        }
        if let revolutions = integer(payload["revolutions"]) {
            guard revolutions == 1 else { return .refused("这一版只支持转一圈，小车保持不动") }
        } else if payload["revolutions"] != nil {
            return .refused("转圈参数无效，小车保持不动")
        }
        return .spec(.v1)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.rounded() == value, abs(value) < Double(Int.max) { return Int(value) }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !"，。！？、,.!?:：~～…".contains($0) }
    }
}
