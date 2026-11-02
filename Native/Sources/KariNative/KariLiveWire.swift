import Foundation

struct KariLiveToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]?
}

struct KariLiveToolResult {
    let id: String
    let name: String
    let response: [String: Any]
}

enum KariLiveEvent {
    case ready
    case resumable(handle: String)
    case interrupted
    case heard(String)
    case reply(String)
    case audio(Data)
    case generationComplete
    case turnComplete
    case toolCalls([KariLiveToolCall])
    case toolCancellation(Set<String>)
}

enum KariLiveCommand {
    case audio(Data)
    case video(Data)
    case text(String)
    case toolResults([KariLiveToolResult])
}

struct KariLiveSessionContext {
    var personality = ""
    var memoryInstruction: String?
    var resumeHandle: String?
}

protocol KariLiveWire {
    func connectRequest(credential: String) -> URLRequest
    func setupMessage(template: [String: Any], context: KariLiveSessionContext) -> [String: Any]
    func encode(_ command: KariLiveCommand) -> [[String: Any]]
    func decode(_ message: [String: Any]) throws -> [KariLiveEvent]
    /// Empty when the provider always accepts frames or the session is a connectivity test.
    func updateVideo(_ enabled: Bool) -> [[String: Any]]
}

extension KariAIConfiguration {
    func liveWire(testOnly: Bool = false, acceptsVideo: Bool = false) throws -> any KariLiveWire {
        guard let offer = preset.live else { throw KariError.message("当前提供商不支持实时语音") }
        switch offer.transport {
        case .geminiDeveloper:
            return GeminiLiveWire(url: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
                                  model: "models/\(try KariAIRequest.identifier(liveModel.replacingOccurrences(of: "models/", with: "")))", oauth: auth == "oauth", testOnly: testOnly)
        case .vertex:
            guard endpointType != "express" else { throw KariError.message("Express 端点不支持当前实时路径，请选择标准项目") }
            let region = try KariAIRequest.identifier(region), project = try KariAIRequest.identifier(projectId)
            let host = region == "global" ? "aiplatform.googleapis.com" : "\(region)-aiplatform.googleapis.com"
            return GeminiLiveWire(url: "wss://\(host)/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent",
                                  model: "projects/\(project)/locations/\(region)/publishers/google/models/\(try KariAIRequest.identifier(liveModel))", oauth: auth == "oauth", testOnly: testOnly)
        case .zhipu:
            let resolved = voice.flatMap { offer.voices.contains($0) ? $0 : nil } ?? offer.voices[0]
            return ZhipuLiveWire(model: try ZhipuModel(liveModel), voice: resolved, testOnly: testOnly, acceptsVideo: acceptsVideo)
        }
    }
}

private func composedSetup(_ template: [String: Any], model: String, testOnly: Bool, context: KariLiveSessionContext) -> [String: Any] {
    var payload = KariLiveConfiguration.setup(template, model: model, testOnly: testOnly)
    guard !testOnly else { return payload }
    var parts = (payload["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
    parts.append(["text": context.personality])
    if let memory = context.memoryInstruction {
        parts.append(["text": memory + " Use search_memory with a self-contained query before answering document or personal-memory questions. State only references returned by that tool. Never read UUID citation IDs aloud; mention document names and locations instead."])
        var tools = payload["tools"] as? [[String: Any]] ?? []
        tools.append(["functionDeclarations": [["name": "search_memory", "description": "Search the user's imported memory documents; no physical actions.", "parameters": ["type": "OBJECT", "properties": ["query": ["type": "STRING", "description": "A self-contained search question"]], "required": ["query"]]]]])
        payload["tools"] = tools
    }
    payload["systemInstruction"] = ["parts": parts]
    return payload
}

fileprivate struct GeminiLiveWire: KariLiveWire {
    let url: String
    let model: String
    let oauth: Bool
    let testOnly: Bool

    func connectRequest(credential: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(oauth ? "Bearer \(credential)" : credential, forHTTPHeaderField: oauth ? "Authorization" : "x-goog-api-key")
        return request
    }
    func setupMessage(template: [String: Any], context: KariLiveSessionContext) -> [String: Any] {
        var payload = composedSetup(template, model: model, testOnly: testOnly, context: context)
        if let handle = context.resumeHandle { payload["sessionResumption"] = ["handle": handle] }
        return ["setup": payload]
    }
    func encode(_ command: KariLiveCommand) -> [[String: Any]] {
        switch command {
        case .audio(let pcm): return [["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]]]
        case .video(let jpeg): return [["realtimeInput": ["video": ["data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]]]
        case .text(let text): return [["clientContent": ["turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": true]]]
        case .toolResults(let results): return [["toolResponse": ["functionResponses": results.map { ["id": $0.id, "name": $0.name, "response": $0.response] }]]]
        }
    }
    func decode(_ message: [String: Any]) throws -> [KariLiveEvent] {
        if let failure = message["error"] as? [String: Any] { throw KariError.message(failure["message"] as? String ?? "AI 拒绝请求") }
        var events: [KariLiveEvent] = []
        if message["setupComplete"] != nil { events.append(.ready) }
        if let resume = message["sessionResumptionUpdate"] as? [String: Any], resume["resumable"] as? Bool != false, let handle = resume["newHandle"] as? String { events.append(.resumable(handle: handle)) }
        let content = message["serverContent"] as? [String: Any] ?? [:]
        if content["interrupted"] as? Bool == true { events.append(.interrupted) }
        if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String { events.append(.heard(text)) }
        if let text = (content["outputTranscription"] as? [String: Any])?["text"] as? String { events.append(.reply(text)) }
        for part in (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] {
            guard let blob = part["inlineData"] as? [String: Any], let mime = blob["mimeType"] as? String, mime.hasPrefix("audio/pcm"),
                  let encoded = blob["data"] as? String, let pcm = Data(base64Encoded: encoded) else { continue }
            events.append(.audio(pcm))
        }
        if content["generationComplete"] as? Bool == true { events.append(.generationComplete) }
        if content["turnComplete"] as? Bool == true { events.append(.turnComplete) }
        if let calls = (message["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] {
            events.append(.toolCalls(calls.map { .init(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", arguments: $0["args"] as? [String: Any]) }))
        }
        if let cancellation = message["toolCallCancellation"] as? [String: Any] { events.append(.toolCancellation(Set(cancellation["ids"] as? [String] ?? []))) }
        return events
    }
    func updateVideo(_: Bool) -> [[String: Any]] { [] }
}

fileprivate struct ZhipuModel {
    let id: String
    init(_ raw: String) throws { id = try KariAIRequest.identifier(raw) }
}

// Reference type so a camera toggle can change the same session the socket is using.
// Zhipu documents function calling for voice calls only, and bills every attached video frame.
fileprivate final class ZhipuLiveWire: KariLiveWire {
    let model: ZhipuModel
    let voice: String
    let testOnly: Bool
    private var acceptsVideo: Bool
    private var baseInstructions = ""
    private var tools: [[String: Any]] = []

    init(model: ZhipuModel, voice: String, testOnly: Bool, acceptsVideo: Bool) {
        self.model = model
        self.voice = voice
        self.testOnly = testOnly
        self.acceptsVideo = testOnly ? false : acceptsVideo
    }

    func connectRequest(credential: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://open.bigmodel.cn/api/paas/v4/realtime")!)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        return request
    }
    func setupMessage(template: [String: Any], context: KariLiveSessionContext) -> [String: Any] {
        let composed = composedSetup(template, model: model.id, testOnly: testOnly, context: context)
        let parts = (composed["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        baseInstructions = parts.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let declarations = (composed["tools"] as? [[String: Any]] ?? []).flatMap { $0["functionDeclarations"] as? [[String: Any]] ?? [] }
        tools = declarations.map { declaration in
            ["type": "function", "name": declaration["name"] ?? "", "description": declaration["description"] ?? "", "parameters": Self.jsonSchema(declaration["parameters"] ?? [:])]
        }
        if !testOnly { tools.insert(Self.driveTool, at: 0) }
        return ["type": "session.update", "session": sessionPayload()]
    }
    func updateVideo(_ enabled: Bool) -> [[String: Any]] {
        guard !testOnly else { return [] }
        acceptsVideo = enabled
        return [["type": "session.update", "session": sessionPayload()]]
    }
    // Gemini declarations use OpenAPI-style uppercase types and `nullable`; Zhipu expects JSON Schema.
    private static func jsonSchema(_ value: Any) -> Any {
        if let list = value as? [Any] { return list.map(jsonSchema) }
        guard let object = value as? [String: Any] else { return value }
        var result: [String: Any] = [:]
        for (key, item) in object where key != "nullable" {
            result[key] = key == "type" ? ((item as? String)?.lowercased() ?? item) : jsonSchema(item)
        }
        return result
    }
    private static let driveTool: [String: Any] = [
        "type": "function", "name": "drive",
        "description": "Move the car the moment the user clearly asks to go forward, back up, turn left, or turn right. Call this instead of only agreeing in speech.",
        "parameters": [
            "type": "object",
            "properties": [
                "direction": [
                    "type": "string",
                    "enum": ["前进", "后退", "左转", "右转"],
                    "description": "前进 moves closer, 后退 backs up, 左转 turns left, 右转 turns right."
                ]
            ],
            "required": ["direction"]
        ]
    ]
    private func sessionPayload() -> [String: Any] {
        let video = acceptsVideo && !testOnly
        return [
            "model": model.id, "voice": voice,
            "instructions": testOnly ? baseInstructions : Self.spokenInstructions(baseInstructions, video: video),
            "tools": tools,
            // Bare pcm is 16 kHz on this API, which matches the microphone converter.
            "modalities": ["text", "audio"], "input_audio_format": "pcm", "output_audio_format": "pcm",
            "temperature": 0.2,
            // Match Gemini's slower end-of-speech so a short command is not split, and keep server VAD across updates.
            "turn_detection": ["type": "server_vad", "interrupt_response": true, "prefix_padding_ms": 300, "silence_duration_ms": 700],
            // auto_search defaults on in the vendor docs and adds a server search tool. Function calls are documented for audio only.
            "beta_fields": ["chat_mode": video ? "video_passive" : "audio", "auto_search": false]
        ]
    }
    private static func spokenInstructions(_ base: String, video: Bool) -> String {
        var text = base
        if !video {
            text = text.replacingOccurrences(of: "(?s)<perception_truth>.*?</perception_truth>\\n?", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "(?s)<body_context_rules>.*?</body_context_rules>\\n?", with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "You have one tool: run_scenario.", with: "Use drive for 前进, 后退, 左转, and 右转. Use run_scenario for every other approved scenario.")
        let camera = video ? "The camera is on. Describe only what a new frame shows." : "The camera is off. Do not claim you can see the user, the room, or any object."
        text += """

        <car_motion>
        This device is a small car. When the user clearly asks to move, call drive immediately. direction must be exactly 前进, 后退, 左转, or 右转.
        前进, 向前, 往前, and 向前走 use 前进. 后退, 向后, 往后, and 向后走 use 后退. 左转, 向左, and 往左 use 左转. 右转, 向右, and 往右 use 右转.
        Do not answer these four commands with speech alone. Prefer the tool call and no extra speech.
        \(camera) Do not search the web.
        </car_motion>
        """
        return text
    }
    func encode(_ command: KariLiveCommand) -> [[String: Any]] {
        switch command {
        case .audio(let pcm): return [["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]]
        case .video(let jpeg):
            guard acceptsVideo, !testOnly else { return [] }
            return [["type": "input_audio_buffer.append_video_frame", "video_frame": jpeg.base64EncodedString()]]
        case .text(let text):
            return [["type": "conversation.item.create", "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]],
                    ["type": "response.create"]]
        case .toolResults(let results):
            let outputs: [[String: Any]] = results.map { result in
                let output = (try? JSONSerialization.data(withJSONObject: result.response)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                var item: [String: Any] = ["type": "function_call_output", "object": "realtime.item", "output": output]
                if !result.id.isEmpty { item["call_id"] = result.id }
                return ["type": "conversation.item.create", "item": item]
            }
            return outputs + [["type": "response.create"]]
        }
    }
    func decode(_ message: [String: Any]) throws -> [KariLiveEvent] {
        switch message["type"] as? String {
        case "error": throw KariError.message((message["error"] as? [String: Any])?["message"] as? String ?? "AI 拒绝请求")
        case "session.updated": return [.ready]
        case "input_audio_buffer.speech_started": return [.interrupted]
        case "conversation.item.input_audio_transcription.completed": return (message["transcript"] as? String).map { [.heard($0)] } ?? []
        case "conversation.item.created":
            guard ((message["item"] as? [String: Any])?["role"] as? String) == "user" else { return [] }
            let parts = (message["item"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return parts.compactMap { part in (part["transcript"] as? String).flatMap { $0.isEmpty ? nil : $0 } }.map { .heard($0) }
        case "response.audio_transcript.delta": return (message["delta"] as? String).map { [.reply($0)] } ?? []
        case "response.audio.delta": return (message["delta"] as? String).flatMap { Data(base64Encoded: $0) }.map { [.audio($0)] } ?? []
        case "response.audio.done": return [.generationComplete]
        case "response.done": return [.turnComplete]
        case "response.function_call_arguments.done":
            return [.toolCalls([Self.toolCall(message)])]
        default: return []
        }
    }
    private static func toolCall(_ message: [String: Any]) -> KariLiveToolCall {
        let arguments: [String: Any]?
        if let object = message["arguments"] as? [String: Any] { arguments = object }
        else if let text = message["arguments"] as? String { arguments = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        else { arguments = nil }
        let callID = (message["call_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (message["item_id"] as? String) ?? ""
        return .init(id: callID, name: message["name"] as? String ?? "", arguments: arguments)
    }
}
