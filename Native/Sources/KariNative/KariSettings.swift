import Foundation
import Security
import Combine

enum KariLiveTransport {
    case geminiDeveloper
    case vertex
    case zhipu
}

struct KariLiveOffer {
    let transport: KariLiveTransport
    let models: [String]
    /// Empty when the voice comes from the setup template. The first entry is the default.
    let voices: [String]
}

struct KariProvider: Identifiable {
    let id: String
    let title: String
    let endpoint: String
    let models: [String]
    let live: KariLiveOffer?
    var liveModels: [String] { live?.models ?? [] }
    private static let geminiLiveModels = ["gemini-3.8-live", "gemini-3.1-flash-live-preview"]
    static let all: [KariProvider] = [
        .init(id: "gemini", title: "Google Gemini", endpoint: "https://generativelanguage.googleapis.com", models: ["gemini-3.8-flash", "gemini-3.7-flash"], live: .init(transport: .geminiDeveloper, models: geminiLiveModels, voices: [])),
        .init(id: "vertex", title: "Google Vertex AI", endpoint: "", models: ["gemini-3.8-flash"], live: .init(transport: .vertex, models: geminiLiveModels, voices: [])),
        .init(id: "zhipu", title: "智谱 GLM", endpoint: "https://open.bigmodel.cn/api/paas/v4", models: ["glm-4.6v", "glm-4.7-flash"],
              live: .init(transport: .zhipu, models: ["glm-realtime-flash", "glm-realtime", "glm-realtime-air"],
                          voices: ["tongtong", "xiaochen", "female-tianmei", "female-shaonv", "male-qn-daxuesheng", "male-qn-jingying", "lovely_girl"])),
        .init(id: "qwen", title: "通义千问 / 百炼", endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1", models: ["qwen-plus", "qwen-flash", "qwen-vl-plus"], live: nil),
        .init(id: "groq", title: "Groq", endpoint: "https://api.groq.com/openai/v1", models: ["openai/gpt-oss-120b", "openai/gpt-oss-20b"], live: nil),
        .init(id: "fireworks", title: "Fireworks", endpoint: "https://api.fireworks.ai/inference/v1", models: ["accounts/fireworks/models/llama-v3p3-70b-instruct"], live: nil),
        .init(id: "ollama", title: "Ollama 本地模型", endpoint: "http://", models: ["qwen3:8b", "gemma3:4b"], live: nil),
        .init(id: "openai-compatible", title: "自定义兼容服务", endpoint: "https://", models: [], live: nil),
        .init(id: "rule", title: "离线陪伴", endpoint: "", models: [], live: nil),
        .init(id: "mock", title: "模拟演示", endpoint: "", models: [], live: nil)
    ]
    static func find(_ id: String) -> KariProvider { all.first { $0.id == id } ?? all.first { $0.id == "rule" }! }
}

struct KariAIConfiguration: Codable, Equatable {
    var provider = "gemini"
    var mode = "live"
    var auth = "apiKey"
    var endpointType = "standard"
    var baseUrl = "https://generativelanguage.googleapis.com"
    var projectId = ""
    var region = "global"
    var model = "gemini-3.8-flash"
    var liveModel = "gemini-3.8-live"
    /// nil means the provider's default voice.
    var voice: String?
    var preset: KariProvider { KariProvider.find(provider) }
    var isLive: Bool { mode == "live" && preset.live != nil }
    var isOffline: Bool { ["rule", "mock"].contains(provider) }
    var credentialRef: String { "kari.\(provider).key" }
    static func fresh(_ provider: String) -> Self {
        var value = Self(); let preset = KariProvider.find(provider)
        value.provider = provider; value.baseUrl = preset.endpoint
        if provider == "vertex" { value.region = "us-central1" }
        value.model = preset.models.first ?? ""; value.liveModel = preset.liveModels.first ?? ""
        value.mode = preset.live == nil ? "text" : "live"
        return value
    }
    init() {}
    init(legacy: [String: Any], provider: String) {
        self = .fresh(provider)
        for key in ["mode", "auth", "endpointType", "baseUrl", "projectId", "region", "model", "liveModel"] {
            guard let text = legacy[key] as? String, !text.isEmpty else { continue }
            switch key {
            case "mode": mode = text
            case "auth": auth = text
            case "endpointType": endpointType = text
            case "baseUrl": baseUrl = text
            case "projectId": projectId = text
            case "region": region = text
            case "model": model = text
            default: liveModel = text.replacingOccurrences(of: "models/", with: "")
            }
        }
    }
}

enum KariError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum KariKeychain {
    private static let service = "org.example.kari.credentials"
    private static let services = [service, "app.kari.devfest.credentials"]
    private static func query(_ key: String, serviceName: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: serviceName ?? service, kSecAttrAccount as String: key]
    }
    static func read(_ key: String) throws -> String {
        try read(key) { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
    }
    // Keep existing personal builds usable without exporting or re-entering keys.
    static func read(_ key: String, lookup: ([String: Any]) -> (OSStatus, Data?)) throws -> String {
        for serviceName in services {
            var q = query(key, serviceName: serviceName)
            q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, data) = lookup(q)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data else { throw KariError.message("无法读取安全凭据，请解锁手机后重试") }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }
    static func save(_ value: String, key: String) throws {
        let q = query(key)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw KariError.message("无法保存安全凭据") }
        } else if status != errSecSuccess { throw KariError.message("无法更新安全凭据") }
    }
    static func delete(_ key: String) throws {
        try delete(key) { SecItemDelete($0 as CFDictionary) }
    }
    static func delete(_ key: String, remove: ([String: Any]) -> OSStatus) throws {
        for serviceName in services {
            let status = remove(query(key, serviceName: serviceName))
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KariError.message("无法删除凭据") }
        }
    }
}

final class KariSettings: ObservableObject {
    @Published private(set) var configuration = KariAIConfiguration()
    @Published private(set) var turnCalibration: TurnPulseCalibration?
    @Published var motionEnabled = true
    private var profiles: [String: KariAIConfiguration] = [:]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        turnCalibration = TurnPulseCalibration.load(from: defaults)
        Self.migrateStoredScenes(defaults)
        if let data = defaults.data(forKey: "kari.native.profiles.v2"), let saved = try? JSONDecoder().decode([String: KariAIConfiguration].self, from: data) {
            profiles = saved; configuration = saved[defaults.string(forKey: "kari.native.selected.v2") ?? "gemini"] ?? configuration
        } else if let json = defaults.string(forKey: "CapacitorStorage.kari.providers.v1"), let data = json.data(using: .utf8),
                  let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = old["profiles"] as? [String: [String: Any]] {
            profiles = entries.mapValues { .init(legacy: $0, provider: $0["provider"] as? String ?? "rule") }
            configuration = profiles[old["selected"] as? String ?? "rule"] ?? configuration
        }
    }
    private static func migrateStoredScenes(_ defaults: UserDefaults) {
        for (key, value) in defaults.dictionaryRepresentation() where key.lowercased().contains("scenario") && (key.hasPrefix("kari.") || key.hasPrefix("CapacitorStorage.kari.")) {
            let data = (value as? Data) ?? (value as? String)?.data(using: .utf8)
            let object: Any? = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? value
            guard let scenes = object as? [[String: Any]], !scenes.isEmpty, scenes.allSatisfy({ $0["steps"] is [[String: Any]] }) else { continue }
            let cleaned = scenes.compactMap { scene -> [String: Any]? in
                var result = scene
                let steps = (scene["steps"] as! [[String: Any]]).filter { ["move", "stop", "pause", "face", "expression"].contains($0["kind"] as? String ?? "") }
                guard steps.contains(where: { ["move", "face", "expression"].contains($0["kind"] as? String ?? "") }) else { return nil }
                result["steps"] = steps; result.removeValue(forKey: "usesHead")
                result["animationType"] = steps.contains(where: { $0["kind"] as? String == "move" }) ? "body" : "face"
                return result
            }
            if value is String, let encoded = try? JSONSerialization.data(withJSONObject: cleaned) { defaults.set(String(data: encoded, encoding: .utf8), forKey: key) }
            else if value is Data, let encoded = try? JSONSerialization.data(withJSONObject: cleaned) { defaults.set(encoded, forKey: key) }
            else { defaults.set(cleaned, forKey: key) }
        }
    }
    func profile(_ provider: String) -> KariAIConfiguration { profiles[provider] ?? .fresh(provider) }
    func save(_ config: KariAIConfiguration, key: String) throws {
        if !key.isEmpty { try KariKeychain.save(key, key: config.credentialRef) }
        var updated = profiles; updated[config.provider] = config
        defaults.set(try JSONEncoder().encode(updated), forKey: "kari.native.profiles.v2")
        defaults.set(config.provider, forKey: "kari.native.selected.v2")
        profiles = updated; configuration = config
    }
    func saveTurnCalibration(_ value: TurnPulseCalibration) {
        TurnPulseCalibration.store(value, in: defaults)
        turnCalibration = value
    }
    func clearTurnCalibration() {
        TurnPulseCalibration.store(nil, in: defaults)
        turnCalibration = nil
    }
}
