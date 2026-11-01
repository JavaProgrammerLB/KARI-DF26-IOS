import SwiftUI
import Combine

@MainActor final class KariAppModel: ObservableObject {
    enum Phase { case idle, starting, active, testing, stopping }
    @Published private(set) var phase: Phase = .idle
    @Published var notice = "就在这里，陪着你"
    @Published var textReply = ""
    @Published var cameraEnabled = true
    @Published private(set) var recovering = false
    @Published private(set) var liveConnectionFailure = ""
    private let liveStarter: ((KariAIConfiguration) async throws -> Void)?
    var liveFailure: String { settings.configuration.isLive ? (live.error.isEmpty ? liveConnectionFailure : live.error) : "" }
    let memory: KariMemoryService
    let settings: KariSettings
    let companion: KariCompanionFeatures
    let motion = KariMotionCoordinator()
    let wake = WakeCoordinator()
    private var sceneID: String?
    private var sceneLease: MotionLease?
    private var manualLease: MotionLease?
    private(set) var scenarioBusy = false
    private(set) var textBusy = false
    let body = KariBluetooth()
    let camera = KariCamera()
    let live = KariLiveService()
    let face = KariFaceHost()
    lazy var remote: KariRemoteControl = KariRemoteControl(connected: { [weak self] in self?.body.isConnected == true }, send: { [weak self] command in
        guard let self, self.remote.ready else { throw CancellationError() }
        guard let lease = self.manualLease else { throw PolicyError.cancelled }; _ = try await self.motion.send(command, lease: lease, timeout: 0.25)
    }, stop: { [weak self] in await self?.motion.manualStop() ?? false })
    private var subscriptions = Set<AnyCancellable>()
    private var operation: Task<Void, Never>?
    private var textOperation: Task<Void, Never>?
    private var textToken = UUID()
    private var token = UUID()
    private var bodyFaultLatched = false
    lazy var scenarioNames: Set<String> = {
        guard let url = Bundle.module.url(forResource: "LiveSetup", withExtension: "json"), let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let setup = object["setup"] as? [String: Any],
              let tools = setup["tools"] as? [[String: Any]], let functions = tools.first?["functionDeclarations"] as? [[String: Any]],
              let parameters = functions.first?["parameters"] as? [String: Any], let properties = parameters["properties"] as? [String: Any],
              let name = properties["name"] as? [String: Any], let values = name["enum"] as? [String] else { return [] }
        return Set(values)
    }()
    var isBusy: Bool { memory.busy || memory.committing || remote.presented || remote.state == .stopping || recovering || phase == .starting || phase == .testing || phase == .stopping }
    var isActive: Bool { phase == .active }
    init(defaults suppliedDefaults: UserDefaults? = nil, liveStarter: ((KariAIConfiguration) async throws -> Void)? = nil) {
        self.liveStarter = liveStarter
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let defaults = suppliedDefaults ?? (testing ? UserDefaults(suiteName: "app.kari.public.ui-tests")! : .standard)
        if testing && suppliedDefaults == nil { defaults.removePersistentDomain(forName: "app.kari.public.ui-tests") }
        settings = KariSettings(defaults: defaults); companion = KariCompanionFeatures(defaults: defaults)
        memory = KariMemoryService(defaults: defaults, root: testing ? FileManager.default.temporaryDirectory.appendingPathComponent("kari-memory-ui-tests") : nil)
        memory.canMutate = { [weak self] in self?.phase == .idle }
        memory.changed = { [weak self] in self?.live.clearResumption() }
        memory.$ready.filter { $0 }.sink { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.memory.resume(self.settings.configuration) }
        }.store(in: &subscriptions)
        memory.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        settings.$configuration.dropFirst().sink { [weak self] _ in self?.memory.invalidateQuery(); self?.live.clearResumption() }.store(in: &subscriptions)
        live.memoryAvailable = { [weak self] in self?.memory.hasEnabledDocuments == true }
        live.onMemorySearch = { [weak self] query in
            guard let self else { throw CancellationError() }
            return try await self.memory.search(query, chat: self.settings.configuration).map(\.json)
        }
        live.onMemoryCancel = { [weak self] in self?.memory.invalidateQuery() }
        if testing { try? settings.save(.fresh("rule"), key: "") }
        companion.attach(self); wake.app = self
        wake.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        live.$speaking.removeDuplicates().sink { [weak self] value in self?.companion.lifeEvent(value ? "playback_started" : "playback_stopped") }.store(in: &subscriptions)
        motion.$source.removeDuplicates().sink { [weak self] value in self?.companion.lifeEvent(value == nil ? "motion_stopped" : "motion_started") }.store(in: &subscriptions)
        motion.sendRaw = { [weak self] payload, timeout in guard let self else { throw PolicyError.cancelled }; return try await self.body.send(payload, timeout: timeout) }
        motion.stopRaw = { [weak self] timeout in await self?.body.stopMotion(timeout: timeout) ?? false }
        motion.preempt = { [weak self] in self?.sceneID = nil; self?.sceneLease = nil; self?.scenarioBusy = false; self?.face.cancel() }
        camera.onPixelBuffer = { [weak vision = companion.vision] buffer, time in vision?.submit(buffer, time: time) }
        camera.onOrientationChanged = { [weak vision = companion.vision, weak companion] turns in
            vision?.orientationChanged(clockwise: turns) { [weak companion] in companion?.cameraRotated(clockwise: turns) }
        }
        live.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        live.personality = { [weak self] in self?.companion.profile.instruction ?? "" }
        live.$heard.removeDuplicates().sink { [weak self] value in if !value.isEmpty { self?.companion.interact() } }.store(in: &subscriptions)
        remote.prepare = { [weak self] in guard let self else { return }; try await self.body.checkMotionReadiness(); self.manualLease = try await self.motion.acquire(.manual) }
        remote.takeControl = { [weak self] in self?.settings.motionEnabled = false; self?.companion.cancelAutomatic(); self?.motion.invalidate() }
        remote.stopFailed = { [weak self] in self?.notice = "停止未获确认，请检查连接后重试" }
        remote.presentationChanged = { [weak self] visible in UIApplication.shared.isIdleTimerDisabled = visible || self?.isActive == true; if !visible, let lease = self?.manualLease { self?.motion.release(lease); self?.manualLease = nil } }
        remote.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        camera.onFrame = { [weak self] data in guard let self, !self.companion.wakeSettings.enabled || self.wake.mayUpload else { return }; self.live.sendFrame(data) }
        face.onPhoto = { [weak self] in guard let data = self?.camera.snapshot() else { throw KariError.message("请先开启摄像头并等待画面") }; return data }
        face.onCommand = { [weak self] payload, runID in
            guard let self else { throw CancellationError() }
            return try await self.sendBodyCommand(payload, runID: runID)
        }
        live.onScenario = { [weak self] name in
            guard let self, self.phase == .active else { throw KariError.message("陪伴尚未开始") }
            guard !self.remote.presented else { throw KariError.message("手动遥控中，AI 身体动作已暂停") }
            try await self.runScenario(name)
        }
        live.onCancel = { [weak self] in
            self?.motion.invalidate(); guard self?.remote.presented != true else { return }
            Task { _ = await self?.motion.stop() }
        }
        live.onImmediateStop = { [weak self] in self?.stopBodyImmediately() }
        body.onFault = { [weak self] text in
            guard let self else { return }; self.remote.connectionLost(reason: text)
            guard !self.bodyFaultLatched else { return }; self.bodyFaultLatched = true
            self.settings.motionEnabled = false; self.companion.cancelAutomatic(); self.motion.invalidate(); self.notice = text + "；语音可继续"
        }
        body.onConnection = { [weak self] connected in self?.companion.lifeEvent(connected ? "connected" : "disconnected"); if !connected { self?.settings.motionEnabled = false; self?.companion.cancelAutomatic(); self?.motion.invalidate(); self?.remote.connectionLost() } else { self?.bodyFaultLatched = false }; self?.updateFace() }
        live.$speaking.combineLatest(live.$connecting).sink { [weak self] _, _ in
            Task { @MainActor in self?.updateFace() }
        }.store(in: &subscriptions)
        camera.$running.sink { [weak self] _ in Task { @MainActor in self?.updateFace() } }.store(in: &subscriptions)
    }
    private func updateFace() { face.state(connected: body.isConnected, speaking: live.speaking, thinking: live.connecting, cameraRunning: camera.running) }
    private func stopBodyImmediately() {
        settings.motionEnabled = false; companion.cancelAutomatic(); motion.invalidate()
        if remote.presented { remote.emergencyStop(); notice = "手动遥控已停止"; return }
        Task { let confirmed = await motion.stop(); notice = confirmed ? "身体动作已停止，语音陪伴可继续。" : "停止指令未获确认，请检查机器人。" }
    }
    private func connectLive(_ config: KariAIConfiguration) async throws {
        if let liveStarter { try await liveStarter(config) }
        else { try await live.start(config) }
    }
    func start() {
        guard phase == .idle, !isBusy else { return }
        phase = .starting; token = UUID(); let current = token
        liveConnectionFailure = ""; notice = "正在开始陪伴…"
        operation = Task {
            let config = settings.configuration
            if config.isLive && !companion.wakeSettings.enabled {
                do { try await connectLive(config) }
                catch {
                    guard current == token, !Task.isCancelled else { return }
                    liveConnectionFailure = KariAIRequest.redact(error.localizedDescription)
                }
            }
            guard current == token, !Task.isCancelled else { return }
            var cameraNotice = ""
            if cameraEnabled {
                do { if !camera.running { try await camera.start(front: camera.front) } }
                catch {
                    guard current == token, !Task.isCancelled else { return }
                    cameraEnabled = false; cameraNotice = "摄像头未开启，语音仍可继续。\(error.localizedDescription)"
                }
            }
            guard current == token, !Task.isCancelled else { return }
            settings.motionEnabled = !(config.isLive && companion.wakeSettings.enabled)
            phase = .active
            let failures = [liveConnectionFailure, cameraNotice].filter { !$0.isEmpty }
            notice = failures.isEmpty ? (config.isLive ? "可以直接说话，我在听。" : "陪伴已开始，可使用下方文字交流。") : failures.joined(separator: "\n")
            UIApplication.shared.isIdleTimerDisabled = true
            if config.isLive && companion.wakeSettings.enabled { companion.invalidateFollow("等待唤醒期间不跟随，请手动开启运动") }
            companion.begin()
            if config.isLive && companion.wakeSettings.enabled {
                await wake.begin(companion.wakeSettings)
                guard current == token, !Task.isCancelled else { return }
                notice = "等待唤醒"
            }
        }
    }
    func stop() async {
        token = UUID(); operation?.cancel(); memory.invalidateQuery()
        textOperation?.cancel(); textToken = UUID(); phase = .stopping
        recovering = false; wake.stop(); companion.end(); remote.close()
        live.stop(); camera.stop(); face.cancel(); settings.motionEnabled = false; textBusy = false; scenarioBusy = false
        UIApplication.shared.isIdleTimerDisabled = false
        body.stopScan(); let stopped = await motion.stop()
        phase = .idle; notice = stopped ? "陪伴已结束，麦克风和摄像头已关闭。" : "采集已关闭；身体停止未获确认，请检查机器人。"
    }
    func recoverCapture() {
        guard phase == .active, !recovering else { return }
        if companion.wakeSettings.enabled && settings.configuration.isLive {
            recovering = true; let current = token
            operation = Task {
                defer { if current == token { recovering = false } }
                await wake.resume()
                guard current == token, !Task.isCancelled, phase == .active else { return }
                if cameraEnabled && !camera.running { do { try await camera.start(front: camera.front) } catch { notice = "相机不可用，请检查权限" } }
                UIApplication.shared.isIdleTimerDisabled = true
            }
            return
        }
        recovering = true; let current = token
        operation = Task {
            defer { if current == token { recovering = false } }
            do {
                if settings.configuration.isLive {
                    if live.connected { try await live.recoverMicrophone() } else { try await connectLive(settings.configuration) }
                }
                guard current == token, !Task.isCancelled else { return }
                if cameraEnabled && !camera.running { try await camera.start(front: camera.front) }
                if current == token { liveConnectionFailure = ""; notice = "采集已恢复，可以继续对话。" }
            } catch { if current == token && !Task.isCancelled { liveConnectionFailure = KariAIRequest.redact(error.localizedDescription); notice = liveConnectionFailure } }
        }
    }
    func suspendForBackground() async {
        if companion.wakeSettings.enabled && settings.configuration.isLive && phase == .active {
            wake.suspend(reason: "已暂停，回到前台后请手动恢复采集")
            camera.stop(); companion.cameraChanged(); remote.close(); _ = await motion.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        } else { await stop() }
    }
    func toggleCameraIfNeeded() { if !camera.running { cameraEnabled = false; toggleCamera() } }
    func toggleCamera() {
        cameraEnabled.toggle()
        if !cameraEnabled { companion.cameraChanged(); camera.stop(); return }
        operation = Task { do { try await camera.start(front: camera.front) } catch { cameraEnabled = false; notice = error.localizedDescription } }
    }
    func switchCamera() {
        companion.cameraChanged()
        operation = Task { do { try await camera.start(front: !camera.front); cameraEnabled = true } catch { notice = error.localizedDescription } }
    }
    func testSound() {
        let current = token
        operation = Task { do { try await live.testTone(); if current == token { notice = "提示音已输出，请确认手机媒体音量。" } } catch { if current == token { notice = error.localizedDescription } } }
    }
    func setCompanionMotionEnabled(_ enabled: Bool) {
        guard phase == .active, !remote.presented else { return }
        if enabled {
            guard body.isConnected else { return }
            settings.motionEnabled = true
        } else {
            stopBodyImmediately()
        }
    }
    func runScenario(_ name: String, manual: Bool = false, source: MotionSource = .explicit, allowBody: Bool = true) async throws {
        guard !remote.presented, !companion.follow.enabled || source == .follow else { throw PolicyError.busy }
        guard scenarioNames.contains(name) || ["pose_neutral", "pose_attentive", "pose_curious", "pose_happy", "pose_sleepy", "pose_scared", "pose_shy"].contains(name) else { throw PolicyError.invalidProfile }
        if source == .idle && scenarioBusy { throw PolicyError.busy }
        let lease = try await motion.acquire(manual ? .test : source)
        let id = UUID().uuidString
        sceneID = id; sceneLease = lease; scenarioBusy = true
        let permitted = allowBody && body.isConnected && (manual || settings.motionEnabled)
        defer { motion.release(lease); if sceneID == id { sceneID = nil; sceneLease = nil; scenarioBusy = false } }
        do { try await face.run(name, allowMotion: permitted, runID: id) }
        catch { if motion.valid(lease) { _ = await motion.stop() }; throw error }
    }
    private func sendBodyCommand(_ payload: [String: Any], runID: String) async throws -> [String: Any] {
        guard sceneID == runID, let lease = sceneLease, motion.valid(lease), !remote.presented else { throw PolicyError.cancelled }
        var command = try KariBodyProtocol.validated(payload, motionAllowed: settings.motionEnabled || phase == .testing)
        if lease.source == .idle, command["type"] as? String == "motion" {
            for key in ["linear", "angular"] { command[key] = max(-0.1, min(0.1, (command[key] as? Double ?? 0) * companion.profile.motionScale)) }
            let duration = command["duration_ms"] as? Int ?? 300
            command["ramp_ms"] = min(duration / 2, Int(200 * (companion.profile.behaviorStyle["movementSoftness"] ?? 0.8)))
        }
        return try await motion.send(command, lease: lease)
    }
    func runIdleScene(_ scene: IdleScene, preview: Bool = false) async throws {
        guard !Task.isCancelled, !remote.presented, !companion.follow.enabled,
              !body.management.busy, body.management.info["ota_mode"] as? Bool != true,
              preview || phase == .active && wake.phase != .suspended else { throw PolicyError.busy }
        let option = companion.sceneOptions(scene.id)
        if let pose = scene.pose {
            try await runScenario(pose, source: preview ? .test : .idle, allowBody: false); return
        }
        guard scene.body, body.isConnected, !live.speaking,
              preview || companion.behavior.idleBody && settings.motionEnabled && companion.allowsAutomaticBody else { throw PolicyError.busy }
        let lease = try await motion.acquire(preview ? .test : .idle)
        scenarioBusy = true
        defer { motion.release(lease); if motion.source == nil { scenarioBusy = false } }
        let speed = companion.idleSettings.speedScale * option.speedScale * companion.profile.motionScale
        let timing = companion.idleSettings.durationScale * option.durationScale
        do {
            for step in scene.steps {
                try Task.checkCancellation()
                guard motion.valid(lease), preview ? phase == .testing : phase == .active && settings.motionEnabled && companion.behavior.idleBody && companion.allowsAutomaticBody && !live.speaking else { throw PolicyError.cancelled }
                let duration = min(1000, max(50, Int((step.durationMs ?? 100) * timing)))
                switch step.kind {
                case "move":
                    let left = step.left ?? 0, right = step.right ?? 0
                    let command: [String: Any] = ["type": "motion", "linear": max(-0.1, min(0.1, (left + right) / 2 * speed)), "angular": max(-0.1, min(0.1, (right - left) / 2 * speed)), "duration_ms": duration, "ramp_ms": min(duration / 2, 150)]
                    _ = try await motion.send(KariBodyProtocol.validated(command, motionAllowed: true), lease: lease)
                    try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000)
                case "stop": _ = try await motion.send(["type": "stop"], lease: lease)
                case "pause": break
                default: throw PolicyError.invalidProfile
                }
                let pause = min(2000, max(0, (step.pauseMs ?? 0) * timing))
                if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000)) }
            }
            _ = try await motion.send(["type": "stop"], lease: lease)
        } catch { if motion.valid(lease) { _ = await motion.stop() }; throw error }
    }
    func cancelIdlePreview() {
        guard phase == .testing else { return }
        let current = token; operation?.cancel()
        Task { guard token == current, phase == .testing else { return }; await stop() }
    }
    func previewIdle(_ scene: IdleScene) {
        guard phase == .idle, !isBusy else { return }
        guard !scene.body || body.isConnected else { notice = "请先连接机器人"; return }
        phase = .testing; token = UUID(); let current = token
        operation = Task {
            do { try await runIdleScene(scene, preview: true); if current == token { notice = "场景预览完成" } }
            catch { if current == token { notice = "场景预览已停止，请检查连接" } }
            guard current == token else { return }; settings.motionEnabled = false; phase = .idle
        }
    }
    func testMotion() {
        guard phase == .idle, !isBusy, body.isConnected else { notice = "请先连接自己的机器人，再结束陪伴进行测试"; return }
        phase = .testing; let current = UUID(); token = current
        notice = "正在测试轻微左右转动，请留出空间。"
        operation = Task {
            do { try await runScenario("look_left", manual: true, source: .test); try await runScenario("look_right", manual: true, source: .test); if token == current { notice = "动作测试完成，身体已确认指令。" } }
            catch { if token == current { notice = error.localizedDescription } }
            guard token == current else { return }
            await body.stopMotion(); if token == current { phase = .idle }
        }
    }

    func testAI() {
        guard phase == .idle, !isBusy else { return }; phase = .testing; token = UUID(); let current = token
        notice = "正在测试 AI…"
        operation = Task {
            do {
                let config = settings.configuration
                if config.isLive {
                    try await live.start(config, testOnly: true); live.sendText(KariConversationLanguage.testPrompt(fallback: KariLocalization.shared.language))
                    let limit = Date().addingTimeInterval(25)
                    while !Task.isCancelled && current == token && Date() < limit {
                        if !live.error.isEmpty { throw KariError.message(live.error) }
                        if live.receivedAudioChunks > 0 && !live.speaking && live.turnComplete { break }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard live.receivedAudioChunks > 0, live.turnComplete, !live.speaking else { throw KariError.message("AI 测试未完成语音播放，请检查网络和模型") }
                    if current == token { notice = "AI 测试成功，语音已收到并播放。" }
                } else { let reply = try await textRequest(KariConversationLanguage.testPrompt(fallback: KariLocalization.shared.language)); if current == token { textReply = reply; notice = config.isOffline ? "离线陪伴已就绪。" : "AI 文本测试成功。" } }
            } catch { if current == token { notice = KariAIRequest.redact(error.localizedDescription) } }
            guard current == token else { return }; live.stop(); phase = .idle
        }
    }
    func textRequest(_ text: String, image: Data? = nil, allowActions: Bool = false, autonomous: Bool = false, useMemory: Bool = false) async throws -> String {
        let config = settings.configuration
        if config.isOffline {
            if useMemory {
                let results = try await memory.search(text, chat: config)
                return results.isEmpty ? L("未找到相关记忆。当前离线陪伴不生成资料回答。") : L("当前离线陪伴不生成资料回答，以下是检索到的原文：") + "\n\n" + results.map(\.context).joined(separator: "\n\n")
            }
            return KariConversationLanguage.offlineReply(to: text, fallback: KariLocalization.shared.language)
        }
        let key = try await KariCredentials.token(config)
        var instruction = "You are KARI, a warm, concise desktop companion. " + KariConversationLanguage.instruction(fallback: KariLocalization.shared.language) + companion.profile.instruction
        if allowActions {
            instruction += "Return only JSON: {\"text\":\"your natural reply in the user’s language\",\"scenario\":null}. Choose a scenario only when movement is permitted by the context, and only from: \(scenarioNames.sorted().joined(separator: ",")). Body connected: \(body.isConnected). Motion allowed: \(settings.motionEnabled). If disconnected or movement is not permitted, scenario must be null. Never claim to have moved when movement is unavailable. Never mention internal scenario names."
        }
        if autonomous { instruction += " This is optional idle reflection, not a user command. Only suggest an allowlisted scene; never raw commands. Body actions allowed: \(companion.behavior.idleBody && settings.motionEnabled)." } else { instruction += " Only move on explicit user request." }
        var context: [KariMemoryHit] = []
        var memoryTicket: UUID?
        var prompt = text
        if useMemory && memory.hasEnabledDocuments {
            instruction += " " + KariMemoryService.instruction
            do {
                context = try await memory.search(text, chat: config)
                memoryTicket = memory.searchGeneration
                prompt += "\n\n<retrieved_memory>\n" + (context.isEmpty ? "No relevant memory found." : context.map(\.context).joined(separator: "\n\n")) + "\n</retrieved_memory>"
            } catch is CancellationError { throw CancellationError() }
            catch {
                memory.invalidateQuery()
                notice = "记忆检索暂不可用：" + KariAIRequest.redact(error.localizedDescription)
                prompt += "\nMemory search failed. Tell the user that memory is temporarily unavailable; do not claim the library contains no information."
            }
        }
        try Task.checkCancellation()
        let request = try KariAIRequest.text(config, key: key, prompt: prompt, image: image, systemInstruction: instruction)
        let (data, response) = try await URLSession.shared.data(for: request)
        let reply = try KariAIRequest.response(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: config.provider)
        try Task.checkCancellation()
        if let memoryTicket, memoryTicket != memory.searchGeneration { throw CancellationError() }
        return useMemory ? memory.filterCitations(reply, hits: context) : reply
    }
    @discardableResult func sendText(_ text: String, includeImage: Bool = false) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if KariAIRequest.isStopRequest(text) { companion.interact(); stopBodyImmediately(); return true }
        if let name = KariMemoryActionPolicy.scenario(for: text), phase == .active { Task { try? await runScenario(name) } }
        if companion.wakeSettings.enabled && settings.configuration.isLive && !wake.mayUpload { notice = "请先唤醒，再发送消息"; return false }
        companion.interact()
        if live.connected { live.sendText(text); return true }
        let image = includeImage ? camera.snapshot() : nil
        if includeImage && image == nil { notice = "请先开启摄像头并等待画面"; return false }
        let current = token
        memory.cancelSearch()
        textOperation?.cancel(); textToken = UUID(); let messageToken = textToken
        textBusy = true
        textOperation = Task {
            defer { if messageToken == textToken { textBusy = false } }
            do {
                let raw = try await textRequest(text, image: image, allowActions: true, useMemory: true)
                guard current == token, messageToken == textToken else { return }
                let reply = KariAIRequest.companionReply(raw, allowedScenarios: scenarioNames); textReply = reply.text
                if let scenario = reply.scenario, phase == .active {
                    guard !memory.hasEnabledDocuments || KariMemoryActionPolicy.isDirectCommand(text) else {
                        textReply = L("资料问答不会执行动作，请单独下达动作指令"); return
                    }
                    try await runScenario(scenario)
                }
            }
            catch { if current == token && messageToken == textToken { notice = error.localizedDescription } }
        }
        return true
    }
}
