import Foundation
import Combine
import AVFoundation
import UIKit
import GoogleSignIn

@MainActor public func handleKariURL(_ url: URL) -> Bool { GIDSignIn.sharedInstance.handle(url) }

@MainActor enum KariCredentials {
    static func authorize() async throws {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String, !clientID.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { throw KariError.message("请先配置 iOS Google OAuth 客户端 ID") }
        while let next = presenter.presentedViewController { presenter = next }
        GIDSignIn.sharedInstance.configuration = .init(clientID: clientID)
        _ = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: nil, additionalScopes: ["https://www.googleapis.com/auth/cloud-platform"])
    }
    static func token(_ config: KariAIConfiguration) async throws -> String {
        if config.auth == "oauth" && config.provider == "vertex" {
            var user = GIDSignIn.sharedInstance.currentUser
            if user == nil { user = try await GIDSignIn.sharedInstance.restorePreviousSignIn() }
            guard let user else { throw KariError.message("请先完成 Google 授权") }
            return try await user.refreshTokensIfNeeded().accessToken.tokenString
        }
        let key = try KariKeychain.read(config.credentialRef)
        guard !key.isEmpty || config.provider == "ollama" else { throw KariError.message("请在 AI 设置中填写 API Key") }
        return key
    }
}

@MainActor final class KariLiveService: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var speaking = false
    @Published private(set) var microphone = false
    @Published private(set) var inputLevel = 0.0
    @Published private(set) var inputDescription = ""
    @Published private(set) var uploadedAudioFrames = 0
    @Published private(set) var committedTurns = 0
    @Published private(set) var serverNote = ""
    @Published private(set) var heard = ""
    @Published private(set) var reply = ""
    @Published private(set) var error = ""
    private(set) var sentVideoFrames = 0
    private(set) var receivedAudioChunks = 0
    @Published private(set) var processing = false
    @Published private(set) var turnComplete = false
    private(set) var externalCapture = false
    private var sharedCaptureID = UUID()
    private var sharedFrame: ((Data, Double) -> Void)?
    private var sharedState: ((String, String) -> Void)?
    var memoryAvailable: (() -> Bool)?
    var onMemorySearch: ((String) async throws -> [[String: Any]])?
    var onMemoryCancel: (() -> Void)?
    var onScenario: ((String) async throws -> Void)?
    var onCancel: (() -> Void)?
    var onImmediateStop: (() -> Void)?
    private let audio = KariAudioOutput()
    var personality: (() -> String)?
    private var previousPersonality = ""
    private(set) var receivedPCMFrames = 0
    private(set) var playedPCMFrames = 0
    private(set) var serverInterruptions = 0
    private(set) var completedTurns = 0
    private(set) var generationCompletions = 0
    private(set) var playbackFailures = 0
    private var peakMicrophoneDuringPlayback = 0.0
    private var microphoneFramesDuringPlayback = 0
    var audioDiagnostics: [String: Any] {
        var value = audio.status()
        value["receivedSeconds"] = Double(receivedPCMFrames) / 24_000
        value["playedSeconds"] = Double(playedPCMFrames) / 24_000
        value["serverInterruptions"] = serverInterruptions
        value["completedTurns"] = completedTurns
        value["generationCompletions"] = generationCompletions
        value["playbackFailures"] = playbackFailures
        value["pendingBuffers"] = audioBuffers
        value["peakMicrophoneDuringPlayback"] = peakMicrophoneDuringPlayback
        value["microphoneFramesDuringPlayback"] = microphoneFramesDuringPlayback
        return value
    }
    private(set) var transportDiagnostic = ""
    func clearResumption() { resumeHandle = nil }
    private var socket: URLSessionWebSocketTask?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()
    private var receiver: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var setup: CheckedContinuation<Void, Error>?
    private var setupTimeout: Task<Void, Never>?
    private var ping: Task<Void, Never>?
    private var generation = 0
    private var queuedMessages = 0
    private var audioBuffers = 0
    private var playbackGeneration = 0
    private var cancelledToolIDs = Set<String>()
    private var scenarioToolIDs = Set<String>()
    private var memoryToolIDs = Set<String>()
    private var memoryHasBeenUsed = false
    private var userUtterance = ""
    private var awaitingNewUserInput = true
    private var resumeHandle: String?
    private var previousConfig: KariAIConfiguration?
    private var previousWasTest = false
    private var previousLanguage: String?
    private var discardAudioUntilTurnComplete = false
    private var wire: (any KariLiveWire)?
    /// Gemini always uploads while the camera runs. Zhipu stays voice-only until the user opts in.
    private(set) var uploadsVideo = true
    private var lastMotionName: String?
    private var lastMotionAt = -Double.infinity
    private var localSpeech = false
    private var quietSince = 0.0
    private var utterancePeak = 0.0
    private var uncommittedAudio = false
    private var echoUntil = 0.0
    private var responseOpen = false
    init() { audio.activate = { try Self.activateAudio() } }
    private static func activateAudio() throws {
        let session = AVAudioSession.sharedInstance()
        // Record from the iPhone microphone, the same input Voice Memos uses.
        // voiceChat plus a headset microphone was holding the captured voice down.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(builtIn)
        }
        if session.isInputGainSettable { try session.setInputGain(1) }
        if session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) { try session.overrideOutputAudioPort(.speaker) }
    }
    func start(_ config: KariAIConfiguration, testOnly: Bool = false, captureMicrophone: Bool = true) async throws {
        stop(clearResume: false, preserveCapture: externalCapture)
        if previousPersonality != personality?() || previousConfig != config || testOnly || previousWasTest || previousLanguage != KariLocalization.shared.language { resumeHandle = nil }
        previousPersonality = personality?() ?? ""
        previousConfig = config; previousWasTest = testOnly; previousLanguage = KariLocalization.shared.language; discardAudioUntilTurnComplete = false
        generation += 1; let token = generation
        KariLiveTrace.reset()
        connecting = true; error = ""; transportDiagnostic = ""; reply = ""; heard = ""; serverNote = ""; sentVideoFrames = 0; uploadedAudioFrames = 0; committedTurns = 0; receivedAudioChunks = 0; turnComplete = false
        localSpeech = false; quietSince = 0; utterancePeak = 0; uncommittedAudio = false; echoUntil = 0; responseOpen = false
        receivedPCMFrames = 0; playedPCMFrames = 0; serverInterruptions = 0; completedTurns = 0; generationCompletions = 0; playbackFailures = 0; peakMicrophoneDuringPlayback = 0; microphoneFramesDuringPlayback = 0
        do {
            let credential = try await KariCredentials.token(config)
            guard token == generation else { throw CancellationError() }
            let wire = try config.liveWire(testOnly: testOnly, acceptsVideo: !testOnly && uploadsVideo); self.wire = wire
            let task = session.webSocketTask(with: wire.connectRequest(credential: credential)); task.maximumMessageSize = 4_000_000; socket = task; task.resume()
            receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard let self, token == self.generation else { return }
                        let data: Data
                        switch message { case .string(let text): data = Data(text.utf8); case .data(let value): data = value; @unknown default: continue }
                        do { try self.receive(data, token: token) }
                        catch {
                            let text = error.localizedDescription
                            if Self.recoverableLiveError(text) {
                                self.serverNote = "上一轮被打断，可以继续说"
                                self.responseOpen = false
                                self.echoUntil = ProcessInfo.processInfo.systemUptime + 0.45
                                KariLiveTrace.line("note \(text.prefix(180))")
                                continue
                            }
                            throw error
                        }
                    }
                } catch { guard let self, token == self.generation else { return }; self.transportFailed(error, socket: task, prefix: "实时连接中断") }
            }
            guard let setupURL = Bundle.module.url(forResource: "LiveSetup", withExtension: "json"),
                  let wrapper = try JSONSerialization.jsonObject(with: Data(contentsOf: setupURL)) as? [String: Any],
                  let template = wrapper["setup"] as? [String: Any] else { throw KariError.message("实时配置资源缺失，请重新构建") }
            let context = KariLiveSessionContext(personality: personality?() ?? "", memoryInstruction: memoryAvailable?() == true ? KariMemoryService.instruction : nil, resumeHandle: resumeHandle)
            let setupMessage = wire.setupMessage(template: template, context: context)
            try await withCheckedThrowingContinuation { continuation in
                setup = continuation
                setupTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled, let self, token == self.generation else { return }; self.fail("实时会话准备超时，请检查网络与模型")
                }
                enqueue(setupMessage, token: token)
            }
            guard token == generation else { throw CancellationError() }
            connected = true; connecting = false
            // A camera toggle during setup cannot see the socket yet. Reconcile once the session is ready.
            if uploadsVideo != !wire.encode(.video(Data())).isEmpty {
                for frame in wire.updateVideo(uploadsVideo) { enqueue(frame, token: token) }
            }
            if !testOnly && captureMicrophone && !externalCapture { try await startMicrophone(token: token) }
            ping = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard !Task.isCancelled, let self, token == self.generation else { return }
                    task.sendPing { _ in }
                }
            }
        } catch {
            if token == generation { fail(error.localizedDescription) }
            if !self.error.isEmpty { throw KariError.message(self.error) }
            throw error
        }
    }
    private func startMicrophone(token: Int) async throws {
        let allowed = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
        guard token == generation else { throw CancellationError() }
        guard allowed else { throw KariError.message("请在 iPhone 设置中允许 KARI 使用麦克风") }
        try audio.startMicrophone(onFrame: { [weak self] data, level in
            guard let self else { return }
            self.inputLevel = level
            if self.inputDescription.isEmpty { self.inputDescription = self.audio.inputDescription }
            if self.speaking { self.peakMicrophoneDuringPlayback = max(self.peakMicrophoneDuringPlayback, level); self.microphoneFramesDuringPlayback += 1 }
            let now = ProcessInfo.processInfo.systemUptime
            switch LiveMicGate.disposition(speaking: self.speaking, responseOpen: self.responseOpen, now: now, echoUntil: self.echoUntil) {
            case .drop:
                self.localSpeech = false
                self.quietSince = 0
                self.utterancePeak = 0
                KariLiveTrace.sample("drop-echo level=\(Int(level * 100)) playing=\(self.speaking)")
                return
            case .holdLocalTurn:
                self.send(.audio(data), token: token)
                KariLiveTrace.sample("barge level=\(Int(level * 100)) playing=\(self.speaking) upload=\(self.uploadedAudioFrames)")
            case .upload:
                self.send(.audio(data), token: token)
                self.finishVoiceTurnIfQuiet(level, token: token)
                KariLiveTrace.sample("level=\(Int(level * 100)) peak=\(Int(self.utterancePeak * 100)) playing=\(self.speaking) upload=\(self.uploadedAudioFrames) commit=\(self.committedTurns) route=\(self.inputDescription)")
            }
        }, onState: { [weak self] type, message in
            guard let self, token == self.generation else { return }
            self.microphone = type == "started"
            self.error = type == "started" ? "" : message
        })
        microphone = true
    }
    func startSharedCapture(onFrame: @escaping (Data, Double) -> Void, onState: @escaping (String, String) -> Void) async throws {
        let captureID = UUID(); sharedCaptureID = captureID
        externalCapture = true; sharedFrame = onFrame; sharedState = onState
        audio.resumeCaptureAutomatically = false
        let allowed = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
        guard externalCapture, sharedCaptureID == captureID else { throw CancellationError() }
        guard allowed else { throw KariError.message("请在 iPhone 设置中允许 KARI 使用麦克风") }
        try audio.startMicrophone(onFrame: { [weak self] data, level in self?.sharedFrame?(data, level) }, onState: { [weak self] type, message in
            guard let self else { return }; self.microphone = type == "started"; self.sharedState?(type, message)
        })
        microphone = true
    }
    func endSharedCapture() {
        sharedCaptureID = UUID(); externalCapture = false; sharedFrame = nil; sharedState = nil
        audio.stopMicrophone(); microphone = false; audio.resumeCaptureAutomatically = true
    }
    func sendPCM(_ data: Data, level: Double = 0) {
        guard connected else { return }
        if speaking { peakMicrophoneDuringPlayback = max(peakMicrophoneDuringPlayback, level); microphoneFramesDuringPlayback += 1 }
        // At most sixteen 500ms chunks for the bounded eight-second wake buffer.
        for offset in stride(from: 0, to: data.count, by: 16_000) {
            let chunk = data.subdata(in: offset..<min(data.count, offset + 16_000))
            send(.audio(chunk), token: generation)
        }
    }
    func recoverMicrophone() async throws { audio.stopMicrophone(); microphone = false; guard connected else { return }; try await startMicrophone(token: generation) }
    func setUploadsVideo(_ enabled: Bool) {
        let changed = uploadsVideo != enabled
        uploadsVideo = enabled
        guard changed, connected, let wire else { return }
        for frame in wire.updateVideo(enabled) { enqueue(frame, token: generation) }
    }
    func sendFrame(_ jpeg: Data) { guard connected, uploadsVideo, queuedMessages < 6 else { return }; sentVideoFrames += 1; send(.video(jpeg), token: generation) }
    func sendText(_ text: String) { guard connected else { return }; userUtterance = text; awaitingNewUserInput = false; processing = true; send(.text(text), token: generation) }
    /// Voice-only audio is kept until this utterance falls well below its own peak.
    /// A fixed cutoff never arrives when the room itself stays above that cutoff.
    private func finishVoiceTurnIfQuiet(_ level: Double, token: Int) {
        guard !uploadsVideo, uncommittedAudio else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if level > utterancePeak { utterancePeak = level }
        let talking = utterancePeak > 0.05 && level > utterancePeak * 0.7
        if talking {
            localSpeech = true
            quietSince = 0
            return
        }
        guard localSpeech else { utterancePeak = max(level, utterancePeak * 0.98); return }
        if quietSince == 0 { quietSince = now; return }
        guard now - quietSince >= 0.5 else { return }
        localSpeech = false
        quietSince = 0
        utterancePeak = level
        KariLiveTrace.line("commit playing=\(speaking) upload=\(uploadedAudioFrames)")
        send(.commit, token: token)
    }
    private func send(_ command: KariLiveCommand, token: Int) {
        guard let wire else { return }
        for frame in wire.encode(command) {
            if frame["type"] as? String == "input_audio_buffer.append" { uploadedAudioFrames += 1; uncommittedAudio = true }
            if frame["type"] as? String == "input_audio_buffer.commit" { committedTurns += 1; uncommittedAudio = false }
            if frame["type"] as? String == "response.create" { responseOpen = true }
            enqueue(frame, token: token)
        }
    }
    private func enqueue(_ object: [String: Any], token: Int) {
        guard token == generation, let socket, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        guard queuedMessages < 48 else { fail("网络发送过慢，请检查网络后恢复连接"); return }
        queuedMessages += 1; let preceding = writer
        writer = Task { [weak self] in
            await preceding?.value
            guard let self, token == self.generation, !Task.isCancelled else { return }
            do { try await socket.send(.string(text)); if token == self.generation { self.queuedMessages = max(0, self.queuedMessages - 1) } }
            catch { if token == self.generation { self.transportFailed(error, socket: socket, prefix: "实时发送失败") } }
        }
    }
    private func receive(_ data: Data, token: Int) throws {
        guard let wire, let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let type = message["type"] as? String, type != "response.audio.delta" {
            KariLiveTrace.line("server \(type) \(KariLiveTrace.brief(message))")
        }
        for event in try wire.decode(message) { apply(event, token: token) }
    }
    private func apply(_ event: KariLiveEvent, token: Int) {
        switch event {
        case .ready: setupTimeout?.cancel(); let continuation = setup; setup = nil; continuation?.resume()
        case .resumable(let handle): resumeHandle = handle
        case .interrupted: onMemoryCancel?(); serverInterruptions += 1; playbackGeneration += 1; audio.stop(); audioBuffers = 0; speaking = false; discardAudioUntilTurnComplete = false
        case .heard(let text):
            serverNote = ""
            processing = true
            if awaitingNewUserInput { userUtterance = ""; awaitingNewUserInput = false }
            if userUtterance.count < 2000 { userUtterance += text }
            heard = String((heard + text).suffix(1500))
            if KariAIRequest.isStopRequest(text) { onImmediateStop?() }
            else if let name = KariMemoryActionPolicy.scenario(for: text), claimMotion(name), let run = onScenario {
                Task { try? await run(name) }
            }
        case .reply(let text): reply = String((reply + text).suffix(3000))
        case .audio(let pcm):
            guard !discardAudioUntilTurnComplete else { return }
            receivedPCMFrames += pcm.count / 2
            audioBuffers += 1; if !speaking { speaking = true }; receivedAudioChunks += 1; turnComplete = false
            let playback = playbackGeneration
            do { try audio.enqueue(data: pcm, sampleRate: 24_000) { [weak self] result in
                guard let self, token == self.generation, playback == self.playbackGeneration else { return }
                self.audioBuffers = max(0, self.audioBuffers - 1)
                if self.speaking != (self.audioBuffers > 0) { self.speaking = self.audioBuffers > 0 }
                switch result {
                case .success: self.playedPCMFrames += pcm.count / 2
                case .failure(let error): self.playbackFailed(error)
                }
            } } catch { playbackFailed(error) }
        case .generationComplete: generationCompletions += 1
        case .turnComplete:
            awaitingNewUserInput = true; completedTurns += 1; turnComplete = true; processing = false; discardAudioUntilTurnComplete = false
            responseOpen = false
            echoUntil = max(echoUntil, ProcessInfo.processInfo.systemUptime + 0.45)
        case .toolCalls(let calls): runTools(calls, token: token)
        case .toolCancellation(let ids):
            cancelledToolIDs.formUnion(ids)
            if !ids.isDisjoint(with: memoryToolIDs) { onMemoryCancel?() }
            if !ids.isDisjoint(with: scenarioToolIDs) { onCancel?() }
        }
    }
    private func runTools(_ calls: [KariLiveToolCall], token: Int) {
        for call in calls {
            if call.name == "search_memory" { memoryToolIDs.insert(call.id); memoryHasBeenUsed = true }
            if call.name == "run_scenario" || call.name == "drive" { scenarioToolIDs.insert(call.id) }
        }
        Task { [weak self] in
            guard let self else { return }; var results: [KariLiveToolResult] = []
            for call in calls {
                guard token == self.generation else { return }
                if self.cancelledToolIDs.contains(call.id) { self.memoryToolIDs.remove(call.id); continue }
                var response: [String: Any] = ["ok": true]
                do {
                    guard let args = call.arguments else { throw KariError.message("工具参数无效") }
                    if call.name == "search_memory" {
                        guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 2000, let search = self.onMemorySearch else { throw KariError.message("记忆检索参数无效") }
                        response["results"] = try await search(query)
                    } else if call.name == "run_scenario" || call.name == "drive" {
                        let raw = (call.name == "drive" ? args["direction"] : args["name"]) as? String ?? ""
                        guard let name = KariMemoryActionPolicy.resolveToolScenario(raw), let run = self.onScenario else { throw KariError.message("未知动作请求") }
                        guard !self.memoryHasBeenUsed || KariMemoryActionPolicy.isDirectCommand(self.userUtterance) else { throw KariError.message("资料问答不会执行动作，请单独下达动作指令") }
                        if self.claimMotion(name) { try await run(name) }
                    } else { throw KariError.message("未知动作请求") }
                } catch { response = ["ok": false, "reason": error.localizedDescription] }
                self.memoryToolIDs.remove(call.id)
                if !self.cancelledToolIDs.contains(call.id) { results.append(.init(id: call.id, name: call.name, response: response)) }
            }
            guard token == self.generation, !results.isEmpty else { return }; self.send(.toolResults(results), token: token)
        }
    }
    private func playbackFailed(_ failure: Error) {
        // Avoid a stream of identical errors and broken sentence fragments after
        // a failed output. Camera, microphone and socket remain available.
        playbackFailures += 1
        playbackGeneration += 1; discardAudioUntilTurnComplete = !turnComplete
        audioBuffers = 0; speaking = false
        audio.stop(); error = failure.localizedDescription
    }
    private func transportFailed(_ failure: Error, socket: URLSessionWebSocketTask, prefix: String) {
        var details = ["\((failure as NSError).domain):\((failure as NSError).code)"]
        if let response = socket.response as? HTTPURLResponse, response.statusCode != 101 { details.append("HTTP \(response.statusCode)") }
        if socket.closeCode != .invalid { details.append("WS \(socket.closeCode.rawValue)") }
        if let reason = socket.closeReason.flatMap({ String(data: $0, encoding: .utf8) }), !reason.isEmpty { details.append(String(reason.prefix(800))) }
        transportDiagnostic = KariAIRequest.redact(details.joined(separator: " · "))
        if transportDiagnostic.contains("User location is not supported for the API use") {
            fail("Google 实时 AI 不支持当前网络出口所在地区；请核对服务支持地区或选择其他 AI 服务。")
        } else {
            fail("\(prefix)：\(failure.localizedDescription) [\(transportDiagnostic)]")
        }
    }
    /// WebSocket 握手成功就是 HTTP 101。服务端取消半截回答时也会回这条，不能据此拆掉会话。
    private static func recoverableLiveError(_ text: String) -> Bool {
        let folded = text.lowercased()
        if folded.contains("denied") || folded.contains("unauthorized") || folded.contains("api key") || folded.contains("quota") || text.contains("鉴权") || text.contains("余额") { return false }
        return folded.contains("context canceled") || folded.contains("context cancelled") || folded.contains("request failed") || folded.contains("asr") || folded.contains("commit") || folded.contains("buffer") || folded.contains("vad")
    }
    private func fail(_ reason: String) {
        let clean = KariAIRequest.redact(reason)
        let pending = setup; setup = nil
        stop(clearResume: false, preserveCapture: externalCapture); error = clean
        pending?.resume(throwing: KariError.message(clean))
    }
    func stop(clearResume: Bool = true, preserveCapture: Bool = false) {
        onMemoryCancel?(); memoryToolIDs.removeAll(); scenarioToolIDs.removeAll()
        generation += 1; connected = false; connecting = false; if !preserveCapture { microphone = false }; speaking = false; processing = false; audioBuffers = 0; queuedMessages = 0
        playbackGeneration += 1; cancelledToolIDs.removeAll()
        setupTimeout?.cancel(); ping?.cancel(); receiver?.cancel(); writer?.cancel(); writer = nil
        let continuation = setup; setup = nil; continuation?.resume(throwing: CancellationError())
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil; wire = nil
        if preserveCapture { audio.stop() } else {
            endSharedCapture(); audio.shutdown(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if clearResume { resumeHandle = nil; memoryHasBeenUsed = false }
        userUtterance = ""; awaitingNewUserInput = true; lastMotionName = nil; lastMotionAt = -Double.infinity
    }
    /// Tool calls and the transcript can both name the same move. A second copy inside this window is the echo, not a new command.
    private func claimMotion(_ name: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if lastMotionName == name, now - lastMotionAt < 2 { return false }
        lastMotionName = name; lastMotionAt = now
        return true
    }
    func testTone() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do { try audio.test { result in continuation.resume(with: result.map { _ in () }) } }
            catch { continuation.resume(throwing: error) }
        }
    }
}

enum KariLiveTrace {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("live-debug.log")
    private static var lastSample = 0.0
    static func reset() { try? Data("start\n".utf8).write(to: url) }
    static func line(_ text: String) {
        let row = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, text)
        guard let data = row.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else { try? data.write(to: url) }
    }
    static func sample(_ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSample >= 1 else { return }
        lastSample = now
        line(text)
    }
    static func brief(_ message: [String: Any]) -> String {
        if let error = message["error"] as? [String: Any], let text = error["message"] as? String { return text }
        if let text = message["transcript"] as? String { return String(text.prefix(80)) }
        if let text = message["delta"] as? String, message["type"] as? String == "response.audio_transcript.delta" { return String(text.prefix(80)) }
        if let item = message["item"] as? [String: Any], let parts = item["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["transcript"] as? String }.joined()
            if !text.isEmpty { return String(text.prefix(80)) }
        }
        return ""
    }
}
