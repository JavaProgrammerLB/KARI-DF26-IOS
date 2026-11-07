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
check(MotionPlan.modelInstruction.contains("Do not pretend to search") && MotionPlan.modelInstruction.contains("executed") && MotionPlan.modelInstruction.contains("往前进"), "prompt keeps common knowledge, real counts, and 往前进")
check(!MotionPlan.modelInstruction.contains("direction must be exactly"), "prompt does not require a bare direction")

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

print("Motion checks passed: \(passed)")
