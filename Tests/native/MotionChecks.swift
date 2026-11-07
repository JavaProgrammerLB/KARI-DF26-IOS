import Foundation

var passed = 0
func check(_ condition: Bool, _ name: String) {
    precondition(condition, name); passed += 1
}

func plan(_ text: String) -> MotionPlan? {
    if case .success(let plan)? = MotionPlan.parse(utterance: text) { return plan }
    return nil
}

check(plan("前进十步")?.pulseCount == 10 && plan("前进十步")?.steps.first?.direction == .forward, "前进十步 is ten forward pulses")
check(plan("后退10次")?.pulseCount == 10 && plan("后退10次")?.steps.first?.direction == .backward, "后退10次 is ten backward pulses")
check(plan("后退两回")?.pulseCount == 2, "后退两回 keeps the PR7 unit and the number two")
check(plan("往前进")?.steps.first?.direction == .forward && plan("向前进")?.pulseCount == 1, "往前进 and 向前进 stay forward")
check(plan("前进两步再右转")?.steps.map { "\($0.direction.rawValue)\($0.count.value)" } == ["前进2", "右转1"], "a sequence keeps order")
check(plan("左转九十度")?.pulseCount == 1 && plan("前进3秒")?.pulseCount == 1, "degrees and seconds are one pulse")
check(plan("前进21步") == nil && MotionPlan.parse(utterance: "前进21步") != nil, "an out-of-range count is recognized and refused")
check(plan("眨眨眼") == nil && plan("前进是什么意思？") == nil, "questions and other actions are not chassis plans")
check(MotionPlan.parse(wire: ["direction": "前进"]) == .failure(.malformed), "a bare direction is not a drive plan")
if case .success(let wired) = MotionPlan.parse(wire: ["steps": [["direction": "后退", "count": 4]]]) {
    check(wired.pulseCount == 4, "wire steps carry the count")
} else { check(false, "wire steps carry the count") }

let parameters = MotionPlan.toolDeclaration["parameters"] as? [String: Any]
check(parameters?["required"] as? [String] == ["steps"], "drive schema requires steps")
let spinSchema = ((parameters?["properties"] as? [String: Any])?["spin"] as? [String: Any])?["properties"] as? [String: Any]
check(spinSchema?["sense"] != nil && spinSchema?["count"] == nil && spinSchema?["pulses"] == nil, "spin schema has no pulse count for the model to guess")
check(MotionPlan.modelInstruction.contains("Do not pretend to search") && MotionPlan.modelInstruction.contains("executed") && MotionPlan.modelInstruction.contains("往前进"), "prompt keeps common knowledge, real counts, and 往前进")
check(MotionPlan.modelInstruction.contains("Do not guess how many pulses") && MotionPlan.modelInstruction.contains("还没标定转一圈，请先在设置里标定"), "prompt tells the model not to invent a circle")
check(!MotionPlan.modelInstruction.contains("direction must be exactly"), "prompt does not require a bare direction")
check(MotionPlan.parse(utterance: "转一圈") == nil && MotionPlan.parse(utterance: "转圈") == nil && MotionPlan.parse(utterance: "spin once") == nil, "circle words stay out of the pulse parser")

func request(_ trigger: MotionTrigger, speaking: Bool = false, echoTail: Bool = false, voiceTrusted: Bool = true, turnArmed: Bool = true, duplicate: Bool = false) -> MotionStartRequest {
    .init(trigger: trigger, speaking: speaking, echoTail: echoTail, voiceTrusted: voiceTrusted, turnArmed: turnArmed, duplicateWithoutFreshUplink: duplicate)
}

check(MotionStartGate.decide(request(.transcript, speaking: true)) == .rejectEcho, "playback transcript does not start a plan")
check(MotionStartGate.decide(request(.transcript, echoTail: true)) == .rejectEcho, "echo tail transcript does not start a plan")
check(MotionStartGate.decide(request(.tool, speaking: true, turnArmed: true)) == .allow, "an armed tool can still run while the reply plays")
check(MotionStartGate.decide(request(.tool, speaking: true, turnArmed: false)) == .rejectEcho, "an unarmed tool during playback is echo")
check(MotionStartGate.decide(request(.settle, echoTail: true, turnArmed: true)) == .allow, "armed settle still runs after the 0.8s tail is armed")
check(MotionStartGate.decide(request(.settle, echoTail: true, turnArmed: false)) == .rejectEcho, "unarmed settle does not invent a plan")
check(MotionStartGate.decide(request(.tool, voiceTrusted: false)) == .rejectUntrustedVoice, "speaker without voice processing cannot start voice motion")
check(MotionStartGate.decide(request(.typed, speaking: true, voiceTrusted: false)) == .allow, "typed text is not blocked by echo or a failed processor")
check(MotionStartGate.decide(request(.transcript, duplicate: true)) == .suppressDuplicate, "same plan without fresh uplink does not run again")
check(MotionStartGate.decide(request(.transcript, duplicate: false)) == .allow, "fresh uplink allows the same words as a new command")
check(MotionStartGate.decide(request(.tool, speaking: true, duplicate: true)) == .suppressDuplicate, "duplicate suppression wins over an armed playback tool")

let stopped = MotionToolReply.make(decision: .allow, report: .init(requested: 10, completed: 3, stopped: true))
check(stopped.ok && stopped.executed == 3 && stopped.requested == 10 && stopped.reason == "已停止，完成 3/10", "a stopped plan reports the pulses that finished")
let done = MotionToolReply.make(decision: .allow, report: .finished(10))
check(done.executed == 10 && done.reason == nil, "a finished plan reports every pulse")
check(MotionToolReply.make(decision: .rejectEcho, report: nil).executed == 0, "echo refusal reports zero pulses")
check(MotionToolReply.make(decision: .rejectUntrustedVoice, report: nil).ok == false, "a degraded processor is an explicit refusal")
check(MotionToolReply.make(decision: .suppressDuplicate, report: nil).executed == nil, "a duplicate does not pretend a new count")
check(MotionRunControl.beginAllowed(epochAtStart: 2, epochNow: 2) && !MotionRunControl.beginAllowed(epochAtStart: 2, epochNow: 3), "cancel before acquire blocks the plan")
check(!MotionRunControl.pulseAllowed(epochAtStart: 1, epochNow: 1, leaseValid: false) && MotionRunControl.pulseAllowed(epochAtStart: 1, epochNow: 1, leaseValid: true), "a dead lease stops the remaining pulses")

let measuredAt = Date(timeIntervalSince1970: 1_700_000_000)
func calibration(_ pulses: Int) -> TurnPulseCalibration { TurnPulseCalibration.measured(samplePulses: pulses, at: measuredAt)! }
check(ChassisIntent.needsCalibrationMessage == "还没标定转一圈，请先在设置里标定", "missing calibration uses the settings prompt")
for phrase in ["转一圈", "转圈", "请转一圈", "你好卡里，转一圈", "spin", "spin once", "please spin"] {
    check(ChassisIntent.resolve(utterance: phrase, calibration: nil) == .needsCalibration, "\(phrase) does not move before calibration")
}
let wide = calibration(21)
if case .plan(let circle) = ChassisIntent.resolve(utterance: "转一圈", calibration: wide) {
    check(circle.pulseCount == 21 && circle.steps.map(\.count.value) == [20, 1] && circle.steps.allSatisfy { $0.direction == .right }, "a calibrated circle is finite right pulses, split after 20")
} else { check(false, "a calibrated circle is finite right pulses, split after 20") }
check(ChassisIntent.resolve(utterance: "请转一圈", calibration: wide) == ChassisIntent.resolve(utterance: "转一圈", calibration: wide), "the polite prefix does not change the circle")
if case .plan(let ten) = ChassisIntent.resolve(utterance: "右转十步", calibration: wide) {
    check(ten.pulseCount == 10 && ten.steps.count == 1 && ten.steps[0].direction == .right, "右转十步 stays ten pulses when a circle calibration exists")
} else { check(false, "右转十步 stays ten pulses when a circle calibration exists") }
if case .plan(let politeTen) = ChassisIntent.resolve(utterance: "请右转十步", calibration: wide) {
    check(politeTen.pulseCount == 10, "请右转十步 is not parsed as a circle")
} else { check(false, "请右转十步 is not parsed as a circle") }
check(ChassisIntent.resolve(utterance: "转两圈", calibration: wide) == nil && ChassisIntent.resolve(utterance: "左转一圈", calibration: wide) == nil, "left and multi-turn circles are outside v1")
for sample in 1...160 {
    if case .plan(let plan) = ChassisIntent.resolve(utterance: "转一圈", calibration: calibration(sample)) {
        check(plan.pulseCount == sample && plan.steps.allSatisfy { $0.direction == .right && (1...20).contains($0.count.value) }, "sample \(sample) expands to that many right pulses")
        check(plan.steps.count == (sample + 19) / 20, "sample \(sample) chunks by 20")
    } else { check(false, "sample \(sample) expands to that many right pulses") }
}
let exact = TurnPulseCalibration(scenario: "look_right", degreesPerPulse: 15, samplePulses: 99, measuredAt: measuredAt)
if case .plan(let fromAngle) = SpinExpander.expand(.v1, calibration: exact) {
    check(fromAngle.pulseCount == 24 && fromAngle.steps.map(\.count.value) == [20, 4], "N is ceil(360 / degreesPerPulse), not the stored sample when they differ")
} else { check(false, "N is ceil(360 / degreesPerPulse), not the stored sample when they differ") }
if case .plan(let full) = SpinExpander.expand(.v1, calibration: calibration(160)) {
    check(full.steps.count == 8 && full.steps.allSatisfy { $0.count.value == 20 }, "160 pulses fill 8 steps and still run")
} else { check(false, "160 pulses fill 8 steps and still run") }
if case .refused(let reason) = ChassisIntent.resolve(utterance: "转圈", calibration: calibration(161)) {
    check(reason.contains("161") && reason.contains("保持不动") && !reason.contains("160"), "161 pulses are refused instead of a shorter invented circle")
} else { check(false, "161 pulses are refused instead of a shorter invented circle") }
check(ChassisIntent.resolve(utterance: "转一圈", calibration: TurnPulseCalibration(scenario: "look_right", degreesPerPulse: 0, samplePulses: 1, measuredAt: measuredAt)) == .refused("转一圈的标定无效，请在设置里重新标定"), "a zero angle does not move")
var wrongWay = calibration(8)
wrongWay.scenario = "look_left"
if case .refused(let wrongReason) = ChassisIntent.resolve(utterance: "转一圈", calibration: wrongWay) {
    check(wrongReason.contains("重新标定"), "a left-pulse calibration is not driven as a right circle")
} else { check(false, "a left-pulse calibration is not driven as a right circle") }
let guessed: [String: Any] = ["steps": [["direction": "右转", "count": 3]], "spin": ["sense": "clockwise", "revolutions": 1]]
if case .plan(let preferred) = ChassisIntent.resolve(wire: guessed, calibration: wide) {
    check(preferred.pulseCount == 21, "spin intent ignores a guessed step count")
} else { check(false, "spin intent ignores a guessed step count") }
check(ChassisIntent.resolve(wire: ["spin": ["sense": "clockwise", "revolutions": 1]], calibration: nil) == .needsCalibration, "a spin tool call without calibration does not move")
check(ChassisIntent.resolve(wire: ["steps": [], "spin": ["revolutions": 2]], calibration: wide) == .refused("这一版只支持转一圈，小车保持不动"), "two revolutions are refused")
check(ChassisIntent.resolve(wire: ["spin": ["sense": "counterclockwise", "revolutions": 1]], calibration: wide) == .refused("这一版只支持向右转一圈，小车保持不动"), "a left spin is refused")
if case .plan(let wiredSteps) = ChassisIntent.resolve(wire: ["steps": [["direction": "后退", "count": 4]]], calibration: wide) {
    check(wiredSteps.pulseCount == 4 && wiredSteps.steps[0].direction == .backward, "ordinary steps ignore circle calibration")
} else { check(false, "ordinary steps ignore circle calibration") }
let stoppedCircle = MotionToolReply.make(decision: .allow, report: .init(requested: 21, completed: 11, stopped: true))
check(stoppedCircle.executed == 11 && stoppedCircle.requested == 21 && stoppedCircle.reason == "已停止，完成 11/21", "stopping mid-circle reports the pulses that finished")
let suite = "kari.turn.calibration.motion-checks"
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)
let stored = calibration(12)
TurnPulseCalibration.store(stored, in: defaults)
let loaded = TurnPulseCalibration.load(from: defaults)
check(loaded?.samplePulses == 12 && loaded?.scenario == "look_right" && abs((loaded?.degreesPerPulse ?? 0) - 30) < 1e-9, "calibration persists sample count and 360/sample degrees")
TurnPulseCalibration.store(nil, in: defaults)
check(TurnPulseCalibration.load(from: defaults) == nil, "clearing calibration removes the stored circle")

print("Motion checks passed: \(passed)")
