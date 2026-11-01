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
}

extension KariAIConfiguration {
    func liveWire(testOnly: Bool = false) throws -> any KariLiveWire {
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
            return ZhipuLiveWire(model: try ZhipuModel(liveModel), voice: resolved, testOnly: testOnly)
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
}

fileprivate struct ZhipuModel {
    let id: String
    init(_ raw: String) throws { id = try KariAIRequest.identifier(raw) }
}

fileprivate struct ZhipuLiveWire: KariLiveWire {
    let model: ZhipuModel
    let voice: String
    let testOnly: Bool

    func connectRequest(credential: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://open.bigmodel.cn/api/paas/v4/realtime")!)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        return request
    }
    func setupMessage(template: [String: Any], context: KariLiveSessionContext) -> [String: Any] {
        let composed = composedSetup(template, model: model.id, testOnly: testOnly, context: context)
        let parts = (composed["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let instructions = parts.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let declarations = (composed["tools"] as? [[String: Any]] ?? []).flatMap { $0["functionDeclarations"] as? [[String: Any]] ?? [] }
        let tools: [[String: Any]] = declarations.map { declaration in
            ["type": "function", "name": declaration["name"] ?? "", "description": declaration["description"] ?? "", "parameters": Self.jsonSchema(declaration["parameters"] ?? [:])]
        }
        let session: [String: Any] = [
            "model": model.id, "voice": voice, "instructions": instructions, "tools": tools,
            "modalities": ["text", "audio"], "input_audio_format": "pcm", "output_audio_format": "pcm",
            "turn_detection": ["type": "server_vad", "interrupt_response": true],
            "beta_fields": ["chat_mode": testOnly ? "audio" : "video_passive"]
        ]
        return ["type": "session.update", "session": session]
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
    func encode(_ command: KariLiveCommand) -> [[String: Any]] {
        switch command {
        case .audio(let pcm): return [["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]]
        case .video(let jpeg): return testOnly ? [] : [["type": "input_audio_buffer.append_video_frame", "video_frame": jpeg.base64EncodedString()]]
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
        case "response.audio_transcript.delta": return (message["delta"] as? String).map { [.reply($0)] } ?? []
        case "response.audio.delta": return (message["delta"] as? String).flatMap { Data(base64Encoded: $0) }.map { [.audio($0)] } ?? []
        case "response.audio.done": return [.generationComplete]
        case "response.done": return [.turnComplete]
        case "response.function_call_arguments.done":
            let arguments = (message["arguments"] as? String)?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let callID = (message["call_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (message["item_id"] as? String) ?? ""
            return [.toolCalls([.init(id: callID, name: message["name"] as? String ?? "", arguments: arguments)])]
        default: return []
        }
    }
}
