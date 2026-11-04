import Foundation
import CryptoKit
import Accelerate

struct KariMemoryDocument: Codable, Identifiable {
    var id = UUID()
    var name: String
    var hash: String
    var file: String
    var enabled = true
    var status = "等待处理"
    var error = ""
    var created = Date()
}
struct KariMemoryChunk: Codable, Identifiable {
    var id = UUID()
    var documentID: UUID
    var location: String
    var text: String
    var vector: [Float] = []
}
struct KariMemoryHit: Identifiable {
    var id: UUID { chunk.id }
    var chunk: KariMemoryChunk
    var documentName: String
    var score: Float
    var reference: String { "[M-\(id.uuidString)]" }
    var context: String { "\(reference) \(documentName) · \(chunk.location)\n\(chunk.text)" }
    var json: [String: Any] { ["id": reference, "document": documentName, "location": chunk.location, "text": chunk.text] }
}
struct KariMemoryConfiguration: Codable, Equatable {
    var mode = "follow"
    var provider = "qwen"
    var endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    var model = "text-embedding-v4"
    var localModel = "embeddinggemma"
    var project = ""
    var region = "us-central1"
    var source = "auto"
    var serviceCredentialRef: String {
        "kari.memory." + SHA256.hash(data: Data((provider + "|" + endpoint).utf8)).map { String(format: "%02x", $0) }.joined() + ".key"
    }
}
struct KariEmbeddingConfiguration: Equatable {
    var provider: String
    var endpoint: String
    var model: String
    var key: String
    var project = ""
    var region = ""
    var auth = "apiKey"
    var fingerprint: String { [provider, endpoint, model, project, region, "chunks-v1"].joined(separator: "|") }
}
struct KariMemorySnapshot: Codable {
    var version = 1
    var documents: [KariMemoryDocument] = []
    var chunks: [KariMemoryChunk] = []
    var fingerprint = ""
}
struct KariLocalEmbeddingModel: Identifiable, Codable {
    var id: String
    var name: String
    var subtitle: String
    var repository: String
    var revision: String
    var filename: String
    var sha256: String
    var bytes: Int64
    var dimensions: Int
    var maxTokens: Int
    var pooling: String
    var license: String
    // Mirrors are explicit file URLs for the exact same bytes, never guessed from an HF repository name.
    var mirrors: [String] = []
    var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")! }
    func input(_ text: String, query: Bool) -> String {
        switch id {
        case "embeddinggemma": return query ? "task: search result | query: \(text)" : "title: none | text: \(text)"
        case "qwen": return query ? "Instruct: Given a question, retrieve relevant passages that answer the question\nQuery: \(text)" : text
        case "e5": return (query ? "query: " : "passage: ") + text
        case "bge": return query ? "为这个句子生成表示以用于检索相关文章：\(text)" : text
        default: return text
        }
    }
}

enum KariMemoryMath {
    static func normalized(_ value: [Float]) throws -> [Float] {
        guard !value.isEmpty, value.allSatisfy({ $0.isFinite }) else { throw KariError.message("向量服务返回无效数据") }
        let norm = sqrt(value.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw KariError.message("向量服务返回空向量") }
        return value.map { $0 / norm }
    }
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
    static func terms(_ value: String) -> Set<String> {
        let lower = value.lowercased()
        var terms = Set(lower.components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty })
        let chars = Array(lower.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) })
        for i in chars.indices { terms.insert(String(chars[i])); if i + 1 < chars.count { terms.insert(String(chars[i]) + String(chars[i + 1])) } }
        return terms
    }
}

enum KariMemoryRanking {
    static func rank(chunks: [KariMemoryChunk], documents: [KariMemoryDocument], query: String, embedding: [Float], model: String) -> [KariMemoryHit] {
        let enabled = Dictionary(uniqueKeysWithValues: documents.filter(\.enabled).map { ($0.id, $0.name) })
        let terms = KariMemoryMath.terms(query)
        let floor: Float = model == "e5" ? 0.78 : model == "bge" ? 0.45 : 0.3
        let ranked = chunks.compactMap { chunk -> KariMemoryHit? in
            guard let name = enabled[chunk.documentID], chunk.vector.count == embedding.count else { return nil }
            let cosine = KariMemoryMath.cosine(chunk.vector, embedding)
            let text = chunk.text.lowercased()
            let overlap = Float(terms.filter { text.contains($0) }.count) / Float(max(1, terms.count))
            guard cosine >= floor || overlap >= 0.3 else { return nil }
            return .init(chunk: chunk, documentName: name, score: cosine * 0.8 + overlap * 0.2)
        }.sorted { $0.score == $1.score ? $0.id.uuidString < $1.id.uuidString : $0.score > $1.score }
        var results: [KariMemoryHit] = []; var seen = Set<String>(); var length = 0
        for hit in ranked {
            guard seen.insert(hit.chunk.text).inserted else { continue }
            guard results.count < 5, length + hit.chunk.text.count <= 4500 else { continue }
            results.append(hit); length += hit.chunk.text.count
        }
        return results
    }
}

enum KariEmbeddingURL {
    static func validate(_ url: URL) throws {
        guard ["http", "https"].contains(url.scheme), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { throw KariError.message("请填写有效的向量服务地址") }
        if url.scheme == "http" {
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            let localIP = octets.count == 4 && (octets[0] == 10 || octets[0] == 127 || octets[0] == 192 && octets[1] == 168 || octets[0] == 172 && (16...31).contains(octets[1]))
            guard localIP || host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".local") else { throw KariError.message("公网向量服务必须使用 HTTPS") }
        }
    }
}

// Only the user's own separate command can authorize an action after document context enters a conversation.
// Retrieved text and model-written tool arguments are never inputs to this check.
enum KariMemoryActionPolicy {
    static func isDirectCommand(_ text: String) -> Bool {
        guard text.count <= 240 else { return false }
        if MotionPlan.parse(utterance: text) != nil { return true }
        let value = text.lowercased().filter { !$0.isWhitespace && !"，。！？,.!?:：".contains($0) }
        let chinese = "^(?:你好卡里|嘿卡里|kari|卡里)?(?:请你|请|帮我|给我|麻烦你)?(?:往前走|往后走|往后退|向后退|向前走|向后走|往左转|往右转|向左转|向右转|前进|后退|往前|往后|向前|向后|往左|往右|向左|向右|左转|右转|转一圈|转圈|跳舞|动一动|做个动作|打个招呼|眨眨眼|眨眼|笑一下|开心一点)(?:一下|一点|一会儿|两步|一次|一圈|[0-9一二三四五六七八九十]+(?:秒|度|步))?(?:吧|好吗|可以吗)?$"
        let english = "^(?:heykari|kari)?(?:please)?(?:moveforward|goforward|movebackward|gobackward|turnleft|turnright|spin|dance|wave|blink|smile)(?:abit|alittle|once|for[0-9]+seconds?)?(?:please)?$"
        return value.range(of: chinese, options: .regularExpression) != nil || value.range(of: english, options: .regularExpression) != nil
    }
    /// Maps a tool argument to a face scenario. A Chinese direction name maps to its catalog pulse; other scenario ids pass through unchanged.
    static func resolveToolScenario(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direction = MotionDirection(rawValue: value) { return direction.scenario }
        let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard normalized.range(of: "^[a-z][a-z0-9_]{0,48}$", options: .regularExpression) != nil else { return nil }
        return normalized
    }
}
