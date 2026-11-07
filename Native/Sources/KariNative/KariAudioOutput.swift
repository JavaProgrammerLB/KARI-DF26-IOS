import AVFoundation
import Foundation
import UIKit

// All graph and queue operations run on the main thread, including completion cleanup.
final class KariAudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var pending: [UUID: (Result<[String: Any], Error>) -> Void] = [:]
    private var playbackQueue = KariPlaybackQueue()
    private var playbackEpoch = 0
    private var playbackTimer: Timer?
    private var startup: DispatchWorkItem?
    private var lastCompletion = ProcessInfo.processInfo.systemUptime
    private var recoveryAttempts = 0
    private var playedChunks = 0
    private var configurationObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var microphoneTapStarts = 0
    private var capturedPCMFrames = 0
    private var microphoneTapInstalled = false
    private var microphoneWanted = false
    private var microphoneGeneration = 0
    private var voiceProcessingEnabled = false
    private var voiceProcessingWanted = false
    private var voiceProcessingNote = ""
    private var interrupted = false
    private var configuringSession = false
    private var reconfiguring = false
    private var microphoneFrame: ((Data, Double) -> Void)?
    private var microphoneState: ((String, String) -> Void)?
    private(set) var inputDescription = ""
    var resumeCaptureAutomatically = true
    var activate: (() throws -> Void)?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        player.volume = 1
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, !self.reconfiguring, !self.engine.isRunning else { return }
            if !self.playbackQueue.isEmpty && !self.interrupted { self.recoverPlayback() }
            if self.microphoneWanted && !self.interrupted { self.recoverMicrophone() }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            guard let self, self.microphoneWanted, !self.reconfiguring, !self.configuringSession, !self.interrupted else { return }
            guard Self.usesBuiltInSpeaker() != self.voiceProcessingWanted else { return }
            self.recoverMicrophone()
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                // Starting the engine can deliver this notification. The playback-only test never opens the microphone, so latching it fails every later chunk.
                guard !self.configuringSession else { return }
                self.interrupted = true
                self.removeMicrophoneTap()
                self.engine.pause()
                self.stop(message: "系统暂时中断了音频")
                if self.microphoneWanted { self.microphoneState?("interrupted", "麦克风被系统暂时中断，可点击恢复采集。") }
            } else {
                self.interrupted = false
                let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                if self.microphoneWanted && self.resumeCaptureAutomatically {
                    self.recoverMicrophone()
                }
            }
        }
    }

    deinit {
        playbackTimer?.invalidate(); startup?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    func prepare() throws -> [String: Any] {
        // Do not renegotiate AVAudioSession for every incoming speech chunk.
        if !engine.isRunning { try startEngine() }
        guard !interrupted else { throw failure("音频正被系统中断，请稍后恢复采集") }
        return status()
    }

    private func startEngine() throws {
        configuringSession = true
        interrupted = false
        do {
            try activate?()
            engine.prepare()
            try engine.start()
        } catch {
            configuringSession = false
            throw error
        }
        DispatchQueue.main.async { [weak self] in self?.configuringSession = false }
    }

    func startMicrophone(onFrame: @escaping (Data, Double) -> Void, onState: @escaping (String, String) -> Void, settle: Bool = true) throws {
        reconfiguring = true
        defer { reconfiguring = false }
        interrupted = false
        removeMicrophoneTap()
        microphoneFrame = onFrame; microphoneState = onState; microphoneWanted = true
        configuringSession = true
        do {
            try activate?()
            let input = engine.inputNode
            let sourceFormat = try prepareInputForCapture()
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute.inputs.map(\.portName).joined(separator: "、")
            let outputs = session.currentRoute.outputs.map(\.portName).joined(separator: "、")
            let processing = voiceProcessingEnabled ? "语音处理开" : "语音处理关"
            inputDescription = "\(Int(sourceFormat.sampleRate))Hz \(route)→\(outputs) \(processing)"
            if !voiceProcessingNote.isEmpty { inputDescription += " \(voiceProcessingNote)" }
            let generation = microphoneGeneration
            input.installTap(onBus: 0, bufferSize: 2048, format: sourceFormat) { [weak self] buffer, _ in
                guard let self, let data = Self.pcm16k(buffer) else { return }
                let count = data.count / 2
                var sum: Double = 0
                data.withUnsafeBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    for index in 0..<count { let value = Double(samples[index]) / 32768; sum += value * value }
                }
                let level = sqrt(sum / Double(max(count, 1)))
                DispatchQueue.main.async {
                    guard self.microphoneWanted, self.microphoneGeneration == generation else { return }
                    self.capturedPCMFrames += count
                    self.microphoneFrame?(data, level)
                }
            }
            microphoneTapInstalled = true
            microphoneTapStarts += 1
            engine.prepare()
            do { try engine.start() }
            catch {
                guard voiceProcessingEnabled else { throw error }
                removeMicrophoneTap()
                try? input.setVoiceProcessingEnabled(false)
                voiceProcessingEnabled = false
                voiceProcessingNote = "语音处理未开"
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
                engine.prepare()
                try engine.start()
                let fallbackFormat = input.outputFormat(forBus: 0)
                engine.stop()
                let tapFormat = fallbackFormat.sampleRate > 0 ? fallbackFormat : sourceFormat
                inputDescription = "\(Int(tapFormat.sampleRate))Hz \(route)→\(outputs) 语音处理关 \(voiceProcessingNote)"
                let fallbackGeneration = microphoneGeneration
                input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
                    guard let self, let data = Self.pcm16k(buffer) else { return }
                    let count = data.count / 2
                    var sum: Double = 0
                    data.withUnsafeBytes { raw in
                        let samples = raw.bindMemory(to: Int16.self)
                        for index in 0..<count { let value = Double(samples[index]) / 32768; sum += value * value }
                    }
                    let level = sqrt(sum / Double(max(count, 1)))
                    DispatchQueue.main.async {
                        guard self.microphoneWanted, self.microphoneGeneration == fallbackGeneration else { return }
                        self.capturedPCMFrames += count
                        self.microphoneFrame?(data, level)
                    }
                }
                microphoneTapInstalled = true
                microphoneTapStarts += 1
                engine.prepare()
                try engine.start()
            }
            if voiceProcessingEnabled {
                input.isVoiceProcessingAGCEnabled = false
                input.isVoiceProcessingBypassed = false
            }
            DispatchQueue.main.async { [weak self] in self?.configuringSession = false }
            onState("started", "")
        } catch {
            configuringSession = false
            removeMicrophoneTap(); microphoneWanted = false
            throw error
        }
    }

    /// Built-in speaker and receiver need echo cancellation. A headset already isolates playback.
    static func usesBuiltInSpeaker() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return true }
        return outputs.allSatisfy { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
    }

    /// Voice motion is trusted on a headset, or on the built-in speaker only while voice processing actually enabled.
    /// A failed processor leaves this false so a plan cannot start on an uncancelled speaker path.
    var voiceMotionTrusted: Bool { !Self.usesBuiltInSpeaker() || voiceProcessingEnabled }

    /// Enable the voice processor while the engine is stopped. Playback through this engine is the reference.
    private func configureSpeakerEchoCancellation() {
        let input = engine.inputNode
        let speaker = Self.usesBuiltInSpeaker()
        voiceProcessingWanted = speaker
        voiceProcessingNote = ""
        if input.isVoiceProcessingEnabled == speaker {
            voiceProcessingEnabled = input.isVoiceProcessingEnabled
            if voiceProcessingEnabled {
                input.isVoiceProcessingAGCEnabled = false
                input.isVoiceProcessingBypassed = false
            }
            return
        }
        do {
            try input.setVoiceProcessingEnabled(speaker)
            voiceProcessingEnabled = input.isVoiceProcessingEnabled
            if voiceProcessingEnabled {
                input.isVoiceProcessingAGCEnabled = false
                input.isVoiceProcessingBypassed = false
            }
        } catch {
            voiceProcessingEnabled = input.isVoiceProcessingEnabled
            if speaker { voiceProcessingNote = "语音处理未开" }
        }
    }

    /// The hardware format is only real after the engine has run once. Leave the engine stopped for the tap.
    private func prepareInputForCapture() throws -> AVAudioFormat {
        let input = engine.inputNode
        if engine.isRunning { engine.stop() }
        // Match the output format before enabling the voice processor, or the engine refuses to start.
        if Self.usesBuiltInSpeaker(), !input.isVoiceProcessingEnabled {
            let hardware = try realizeInputFormat()
            if hardware.sampleRate > 0 { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware) }
        }
        configureSpeakerEchoCancellation()
        var format = try realizeInputFormat()
        if voiceProcessingEnabled, format.sampleRate > 0 {
            let outputFormat = engine.outputNode.inputFormat(forBus: 0)
            if outputFormat.sampleRate != format.sampleRate || outputFormat.channelCount != format.channelCount {
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
                format = try realizeInputFormat()
            }
            input.isVoiceProcessingAGCEnabled = false
            input.isVoiceProcessingBypassed = false
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw failure("麦克风格式不可用，请检查音频设备后恢复采集")
        }
        return format
    }

    private func realizeInputFormat() throws -> AVAudioFormat {
        engine.prepare()
        do { try engine.start() }
        catch {
            guard voiceProcessingEnabled else { throw error }
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            voiceProcessingEnabled = false
            voiceProcessingNote = "语音处理未开"
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
            engine.prepare()
            try engine.start()
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.stop()
        return format
    }

    /// Downsample the microphone buffer to little-endian 16 kHz mono PCM.
    private static func pcm16k(_ buffer: AVAudioPCMBuffer) -> Data? {
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, rate > 0, channels > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        if let first = buffer.floatChannelData?[0] {
            for index in 0..<frames {
                var sample = first[index]
                if channels > 1, let second = buffer.floatChannelData?[1] { sample = (sample + second[index]) * 0.5 }
                mono[index] = sample
            }
        } else if let first = buffer.int16ChannelData?[0] {
            for index in 0..<frames { mono[index] = Float(first[index]) / 32768 }
        } else { return nil }
        let outCount = max(1, Int((Double(frames) * 16_000 / rate).rounded()))
        var data = Data(count: outCount * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for index in 0..<outCount {
                let position = Double(index) * rate / 16_000
                let lower = min(frames - 1, Int(position))
                let upper = min(frames - 1, lower + 1)
                let fraction = Float(position - Double(lower))
                let sample = max(-1, min(1, mono[lower] * (1 - fraction) + mono[upper] * fraction))
                out[index] = Int16(sample * 32767)
            }
        }
        return data
    }

    private func removeMicrophoneTap() {
        microphoneGeneration += 1
        if microphoneTapInstalled { engine.inputNode.removeTap(onBus: 0); microphoneTapInstalled = false }
    }

    func stopMicrophone() {
        microphoneWanted = false
        removeMicrophoneTap()
        microphoneFrame = nil; microphoneState = nil
    }

    private func recoverMicrophone() {
        if microphoneWanted && !resumeCaptureAutomatically {
            microphoneState?("interrupted", "音频设备发生变化，请手动恢复采集。")
            return
        }
        guard microphoneWanted, UIApplication.shared.applicationState == .active,
              let frame = microphoneFrame, let state = microphoneState else { return }
        state("interrupted", "音频设备发生变化，正在恢复采集…")
        do { try startMicrophone(onFrame: frame, onState: state, settle: false) }
        catch { state("error", "采集恢复失败：\(error.localizedDescription)。请点击恢复采集。") }
    }

    func status() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        return ["route": session.currentRoute.outputs.map { $0.portName }.joined(separator: "、"),
                "volume": session.outputVolume, "running": engine.isRunning, "microphoneTapStarts": microphoneTapStarts, "capturedPCMFrames": capturedPCMFrames,
                "queuedChunks": pending.count, "playedChunks": playedChunks,
                "bufferedSeconds": Double(playbackQueue.queuedFrames) / format.sampleRate,
                "scheduledSeconds": Double(playbackQueue.scheduledFrames) / format.sampleRate,
                "playerRunning": player.isPlaying, "playbackRecoveries": recoveryAttempts,
                "voiceProcessing": voiceProcessingEnabled, "audioMode": session.mode.rawValue]
    }

    func enqueue(data: Data, sampleRate: Double, completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        guard data.count > 0, data.count % 2 == 0, data.count <= 4_000_000,
              (8_000...96_000).contains(sampleRate) else { throw failure("收到的语音数据格式不正确") }
        _ = try prepare()
        let count = data.count / 2
        let outputCount = max(1, Int(Double(count) * format.sampleRate / sampleRate))
        guard playbackQueue.canAppend(outputCount) else {
            throw failure("语音缓冲异常积压，本轮回复已暂停，请重试或点击恢复采集")
        }
        var samples = [Float](repeating: 0, count: outputCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            func sample(_ index: Int) -> Float {
                let i = min(count - 1, max(0, index)) * 2
                return Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768
            }
            for index in 0..<outputCount {
                let location = Double(index) * sampleRate / format.sampleRate
                let lower = Int(location), fraction = Float(location - Double(lower))
                samples[index] = sample(lower) * (1 - fraction) + sample(lower + 1) * fraction
            }
        }
        let wasEmpty = playbackQueue.isEmpty
        let id = UUID()
        guard playbackQueue.append(samples, request: id) else { throw failure("无法缓冲语音") }
        pending[id] = completion
        if wasEmpty {
            recoveryAttempts = 0; lastCompletion = ProcessInfo.processInfo.systemUptime
            // Absorb small network timing variations without delaying subsequent chunks.
            let work = DispatchWorkItem { [weak self] in self?.startup = nil; self?.pumpPlayback() }
            startup = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        } else if startup == nil { pumpPlayback() }
        if playbackTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkPlayback() }
            playbackTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func pumpPlayback() {
        guard !interrupted, !playbackQueue.isEmpty else { return }
        let epoch = playbackEpoch
        for chunk in playbackQueue.takeWindow() {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
                  let channel = buffer.floatChannelData?[0] else {
                stop(message: "无法创建语音播放缓冲区"); return
            }
            buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
            chunk.samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: source.count)
            }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, epoch == self.playbackEpoch else { return }
                    self.lastCompletion = ProcessInfo.processInfo.systemUptime
                    let finished = self.playbackQueue.complete(chunk.id)
                    if let finished, let callback = self.pending.removeValue(forKey: finished) {
                        self.playedChunks += 1; callback(.success(self.status()))
                    }
                    self.pumpPlayback()
                    if self.playbackQueue.isEmpty {
                        self.playbackTimer?.invalidate(); self.playbackTimer = nil
                    }
                }
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func checkPlayback() {
        guard !interrupted, !reconfiguring, startup == nil, !playbackQueue.isEmpty else { return }
        // Scheduled slices are at most 200 ms. Two seconds without a completion
        // indicates a stopped render path, rather than slow network delivery.
        if !engine.isRunning || !player.isPlaying || ProcessInfo.processInfo.systemUptime - lastCompletion > 2 {
            recoverPlayback()
        }
    }

    private func recoverPlayback() {
        guard !interrupted, !reconfiguring, !playbackQueue.isEmpty else { return }
        guard recoveryAttempts < 2 else {
            stop(message: "音频设备未能恢复播放，请检查输出设备后点击恢复采集"); return
        }
        recoveryAttempts += 1; playbackEpoch += 1
        // Keep the microphone tap and the Live connection. Replay only the small
        // unconfirmed window; never resubmit already completed audio.
        playbackQueue.recover(); player.stop()
        reconfiguring = true
        defer { reconfiguring = false }
        configuringSession = true
        do {
            try activate?()
            engine.stop(); engine.prepare(); try engine.start()
            DispatchQueue.main.async { [weak self] in self?.configuringSession = false }
            lastCompletion = ProcessInfo.processInfo.systemUptime
            pumpPlayback()
        } catch {
            configuringSession = false
            stop(message: "播放恢复失败：\(error.localizedDescription)")
        }
    }

    func test(completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        var data = Data(capacity: 12_000)
        for index in 0..<6_000 {
            let envelope = min(1, Double(index) / 240) * min(1, Double(5_999 - index) / 480)
            let value = Int16(sin(Double(index) * 2 * .pi * 660 / 24_000) * envelope * 10_000)
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(bits & 255)); data.append(UInt8(bits >> 8))
        }
        try enqueue(data: data, sampleRate: 24_000, completion: completion)
    }

    func stop(message: String = "播放已停止") {
        let callbacks = Array(pending.values)
        playbackEpoch += 1
        startup?.cancel(); startup = nil
        playbackTimer?.invalidate(); playbackTimer = nil
        pending.removeAll(); playbackQueue.clear()
        player.stop()
        callbacks.forEach { $0(.failure(failure(message))) }
    }

    func shutdown() {
        stopMicrophone(); stop(); engine.stop()
        if voiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            voiceProcessingEnabled = false
            voiceProcessingWanted = false
        }
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "KARIAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
