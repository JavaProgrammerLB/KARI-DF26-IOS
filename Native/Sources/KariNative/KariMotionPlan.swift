import Foundation

enum MotionDirection: String, CaseIterable {
    case forward = "前进", backward = "后退", left = "左转", right = "右转"
    var scenario: String {
        switch self {
        case .forward: "come_closer"
        case .backward: "back_up"
        case .left: "look_left"
        case .right: "look_right"
        }
    }
    init?(scenario: String) {
        guard let direction = Self.allCases.first(where: { $0.scenario == scenario }) else { return nil }
        self = direction
    }
}

struct MotionCount: Equatable {
    static let one = MotionCount(1)!
    let value: Int
    init?(_ value: Int) {
        guard (1...20).contains(value) else { return nil }
        self.value = value
    }
}

struct MotionStep: Equatable {
    let direction: MotionDirection
    let count: MotionCount
}

enum MotionPlanError: Error, Equatable, LocalizedError {
    case empty, malformed, countOutOfRange(Int), tooManySteps(Int)
    var errorDescription: String? {
        switch self {
        case .empty: "动作计划为空，小车保持不动"
        case .malformed: "动作计划格式无效，小车保持不动"
        case .countOutOfRange(let count): "每一步只能重复 1 到 20 次，收到 \(count) 次，小车保持不动"
        case .tooManySteps(let count): "一次最多 8 步，收到 \(count) 步，小车保持不动"
        }
    }
}

enum KariAction: Equatable {
    case plan(MotionPlan)
    case scenario(String)
    var motionPlan: MotionPlan? {
        switch self {
        case .plan(let plan): plan
        case .scenario(let name): MotionDirection(scenario: name).map { MotionPlan($0) }
        }
    }
}

struct MotionExecutionReport: Equatable {
    var requested: Int
    var completed: Int
    var stopped: Bool
    static func finished(_ requested: Int) -> MotionExecutionReport {
        .init(requested: requested, completed: requested, stopped: false)
    }
}

struct MotionPlan: Equatable {
    static let toolName = "drive"
    let steps: [MotionStep]
    var pulseCount: Int { steps.reduce(0) { $0 + $1.count.value } }
    init(_ direction: MotionDirection) { steps = [MotionStep(direction: direction, count: .one)] }
    private init(validated steps: [MotionStep]) { self.steps = steps }

    static func make(_ requested: [(MotionDirection, Int)]) -> Result<MotionPlan, MotionPlanError> {
        guard !requested.isEmpty else { return .failure(.empty) }
        guard requested.count <= 8 else { return .failure(.tooManySteps(requested.count)) }
        var steps: [MotionStep] = []
        for (direction, value) in requested {
            guard let count = MotionCount(value) else { return .failure(.countOutOfRange(value)) }
            steps.append(MotionStep(direction: direction, count: count))
        }
        return .success(MotionPlan(validated: steps))
    }

    static func parse(utterance text: String) -> Result<MotionPlan, MotionPlanError>? {
        guard text.count <= 240 else { return nil }
        var cursor = Cursor(rest: Substring(normalized(text)))
        _ = cursor.take("(?:你好卡里|嘿卡里|heykari|kari|卡里)?(?:请你|请|帮我|给我|麻烦你|please)?")
        var requested: [(MotionDirection, Int)] = []
        while true {
            guard let direction = cursor.direction(), let count = cursor.count() else { return nil }
            requested.append((direction, count))
            _ = cursor.take("吧|好吗|可以吗|please")
            if cursor.rest.isEmpty { break }
            guard cursor.take("然后再|然后|接着|之后|再|andthen|then|and") != nil else { return nil }
        }
        return make(requested)
    }

    static func parse(wire object: [String: Any]) -> Result<MotionPlan, MotionPlanError> {
        guard let items = object["steps"] as? [[String: Any]] else { return .failure(.malformed) }
        var requested: [(MotionDirection, Int)] = []
        for item in items {
            guard let direction = (item["direction"] as? String).flatMap(MotionDirection.init(rawValue:)),
                  let count = item["count"] == nil ? 1 : item["count"] as? Int else { return .failure(.malformed) }
            requested.append((direction, count))
        }
        return make(requested)
    }

    static func parse(wire text: String) -> Result<MotionPlan, MotionPlanError> {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let object = (try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8))) as? [String: Any] else { return .failure(.malformed) }
        return parse(wire: object)
    }

    /// Unparsed text that still names a direction goes to the planner. Questions about a direction never do.
    static func mayBeChassis(_ text: String) -> Bool {
        guard text.count <= 80, !text.contains(where: { "?？".contains($0) }) else { return false }
        let value = normalized(text)
        guard !["吗", "什么", "怎么", "是不是"].contains(where: value.contains) else { return false }
        return phrases.contains { value.contains($0.0) }
    }

    static let toolDeclaration: [String: Any] = [
        "name": toolName,
        "description": "Drive the car for one user request to go forward, back up, turn left, or turn right. Send the whole request as one ordered plan in a single call.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "steps": [
                    "type": "ARRAY",
                    "description": "Ordered steps, 1 to 8.",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "direction": ["type": "STRING", "enum": MotionDirection.allCases.map(\.rawValue), "description": "前进 moves closer, 后退 backs up, 左转 turns left, 右转 turns right."],
                            "count": ["type": "INTEGER", "description": "How many times to repeat this small pulse, 1 to 20. Omit for 1."]
                        ],
                        "required": ["direction"]
                    ]
                ]
            ],
            "required": ["steps"]
        ]
    ]

    static let toolRule = "Use drive for 前进, 后退, 左转, and 右转. Use run_scenario for every other approved scenario."

    static let modelInstruction = """
    <car_motion>
    This device is a small car. When the user clearly asks to go forward, back up, turn left, or turn right, call drive once with the whole request as ordered steps. Do not answer these commands with speech alone and do not use run_scenario for them.
    direction is exactly 前进, 后退, 左转, or 右转. 前进, 向前, 往前, 往前进, and 向前进 use 前进. 后退, 向后, and 往后 use 后退. 左转, 向左, and 往左 use 左转. 右转, 向右, and 往右 use 右转.
    count is how many times to repeat that one small pulse. 步, 次, 下, and 回 are counts. 前进十步 and 后退10次 are [{"direction":"前进","count":10}] and [{"direction":"后退","count":10}]. 后退两回 is count 2. 前进两步再右转 is [{"direction":"前进","count":2},{"direction":"右转","count":1}]. Degrees and seconds are not counts, so 左转九十度 is count 1.
    Pass the number the user said even above 20. The phone refuses it, and then you tell the user why the car stayed still.
    The tool result field executed is how many pulses actually ran. Say that number. When executed is 0, do not claim the car moved.
    If you are unsure, say so directly. Do not pretend to search.
    </car_motion>
    """

    static let plannerInstruction = """
    Turn the user's request to drive a small car into JSON only, with no other text: {"steps":[{"direction":"前进","count":1}]}.
    direction is exactly 前进, 后退, 左转, or 右转. 往前进 and 向前进 are 前进. count repeats one small pulse and defaults to 1. 步, 次, 下, and 回 are counts. Degrees and seconds are not counts. Keep the user's order and the number they said.
    If the request is not about driving the car forward, back, left, or right, return {"steps":[]}.
    """

    private static let phrases: [(String, MotionDirection)] = [
        ("往前进", .forward), ("向前进", .forward),
        ("往前走", .forward), ("向前走", .forward), ("往后走", .backward), ("向后走", .backward), ("往后退", .backward), ("向后退", .backward),
        ("往左转", .left), ("向左转", .left), ("往右转", .right), ("向右转", .right),
        ("前进", .forward), ("往前", .forward), ("向前", .forward), ("后退", .backward), ("往后", .backward), ("向后", .backward),
        ("左转", .left), ("往左", .left), ("向左", .left), ("右转", .right), ("往右", .right), ("向右", .right),
        ("moveforward", .forward), ("goforward", .forward), ("movebackward", .backward), ("gobackward", .backward), ("backup", .backward),
        ("turnleft", .left), ("turnright", .right)
    ]

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !"，。！？、,.!?:：~～…".contains($0) }
    }

    private static func numeral(_ text: String) -> Int {
        if let value = Int(text) { return value }
        if text.allSatisfy(\.isASCII) { return Int.max }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0, current = 0
        for character in text {
            switch character {
            case "十": total += max(current, 1) * 10; current = 0
            case "百": total += max(current, 1) * 100; current = 0
            default: current = digits[character] ?? 0
            }
        }
        return total + current
    }

    private struct Cursor {
        var rest: Substring
        mutating func take(_ pattern: String) -> Substring? {
            guard let range = rest.range(of: pattern, options: [.regularExpression, .anchored]), !range.isEmpty else { return nil }
            defer { rest = rest[range.upperBound...] }
            return rest[range]
        }
        mutating func direction() -> MotionDirection? {
            guard let (phrase, direction) = MotionPlan.phrases.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            rest = rest.dropFirst(phrase.count)
            return direction
        }
        /// Nil when a number is left without a unit the grammar knows.
        mutating func count() -> Int? {
            if take("一点|一会儿|abit|alittle|once|for[0-9]+seconds?") != nil { return 1 }
            guard let number = take("[0-9]+|[零一二两三四五六七八九十百]+") else { return 1 }
            if take("步|次|下|回|steps?|times") != nil { return MotionPlan.numeral(String(number)) }
            if take("秒钟|秒|度|°|seconds?|degrees?") != nil { return 1 }
            return nil
        }
    }
}

enum MotionTrigger: Equatable {
    /// Server transcript. Playback and the post-playback tail are treated as echo.
    case transcript
    /// Model tool call for a plan that was armed by trusted uplink or typing.
    case tool
    /// Turn-end fallback. Same arming rule as a tool call.
    case settle
    /// Keyboard text. Not acoustic echo, and not blocked when voice processing is off.
    case typed
}

enum MotionStartDecision: Equatable {
    case allow
    case rejectEcho
    case rejectUntrustedVoice
    case suppressDuplicate
}

struct MotionStartRequest: Equatable {
    var trigger: MotionTrigger
    var speaking: Bool
    /// True while `now < echoUntil`. This is the PR6 tail, not a substitute for voice processing.
    var echoTail: Bool
    /// Headset, or built-in speaker with voice processing actually enabled. Typed requests pass true.
    var voiceTrusted: Bool
    /// This turn received trusted microphone uplink or typed text.
    var turnArmed: Bool
    /// Same plan as the last one, and no accepted uplink has arrived since it started.
    var duplicateWithoutFreshUplink: Bool
}

enum MotionStartGate {
    /// Stop requests never reach this gate. Playback still uploads audio; this only refuses a new plan.
    static func decide(_ request: MotionStartRequest) -> MotionStartDecision {
        if request.trigger == .typed { return .allow }
        if !request.voiceTrusted { return .rejectUntrustedVoice }
        if request.duplicateWithoutFreshUplink { return .suppressDuplicate }
        let playbackEcho = request.speaking || request.echoTail
        switch request.trigger {
        case .typed:
            return .allow
        case .transcript:
            if playbackEcho || !request.turnArmed { return .rejectEcho }
            return .allow
        case .tool, .settle:
            if request.turnArmed { return .allow }
            return .rejectEcho
        }
    }
}

struct MotionToolReply: Equatable {
    var ok: Bool
    var executed: Int?
    var requested: Int?
    var reason: String?

    static func make(decision: MotionStartDecision, report: MotionExecutionReport?) -> MotionToolReply {
        switch decision {
        case .allow:
            let report = report ?? MotionExecutionReport(requested: 0, completed: 0, stopped: true)
            let reason = report.stopped ? "已停止，完成 \(report.completed)/\(report.requested)" : nil
            return .init(ok: true, executed: report.completed, requested: report.requested, reason: reason)
        case .rejectEcho:
            return .init(ok: true, executed: 0, requested: nil, reason: "回声期间不开始动作")
        case .rejectUntrustedVoice:
            return .init(ok: false, executed: 0, requested: nil, reason: "扬声器语音处理未开，已拒绝语音动作")
        case .suppressDuplicate:
            return .init(ok: true, executed: nil, requested: nil, reason: "同一口令已在执行或刚被回声重复，未再次发车")
        }
    }
}

enum MotionRunControl {
    static func beginAllowed(epochAtStart: Int, epochNow: Int) -> Bool { epochAtStart == epochNow }
    static func pulseAllowed(epochAtStart: Int, epochNow: Int, leaseValid: Bool) -> Bool {
        epochAtStart == epochNow && leaseValid
    }
}
