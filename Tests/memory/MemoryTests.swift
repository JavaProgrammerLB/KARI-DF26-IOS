import Foundation
import SQLite3

// Standalone harness uses the same production error type without UIKit/Keychain dependencies.
enum KariError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
final class EmbeddingProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct MemoryTests {
    static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw KariError.message("TEST FAILED: " + reason) }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kari-memory-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KariMemoryStore(root: root)
        let empty = try await store.load(); try require(empty.documents.isEmpty, "new store is empty")
        let document = KariMemoryDocument(name: "资料.pdf", hash: "abc", file: "fixture.pdf")
        let chunk = KariMemoryChunk(documentID: document.id, location: "第 3 页", text: "KARI 的管理密码必须由用户设置。", vector: [0.6, 0.8])
        var snapshot = KariMemorySnapshot(documents: [document], chunks: [chunk], fingerprint: "embedding-A")
        try await store.save(snapshot)
        let reopened = try await KariMemoryStore(root: root).load()
        try require(reopened.chunks.first?.text == chunk.text && reopened.chunks.first?.vector == chunk.vector, "source and vector round trip")
        try require(reopened.fingerprint == "embedding-A" && reopened.documents.first?.id == document.id, "index identity round trip")
        var db: OpaquePointer?; try require(sqlite3_open(root.appendingPathComponent("memory.sqlite").path, &db) == SQLITE_OK, "test database opens")
        sqlite3_exec(db, "CREATE TRIGGER reject_chunks BEFORE INSERT ON chunks BEGIN SELECT RAISE(ABORT, 'test rollback'); END;", nil, nil, nil); sqlite3_close(db)
        var failed = snapshot; failed.documents[0].name = "must not commit"
        do { try await store.save(failed); throw KariError.message("TEST FAILED: trigger did not abort") }
        catch { try require(!error.localizedDescription.contains("TEST FAILED"), "failed write aborts") }
        let rolledBack = try await store.load(); try require(rolledBack.documents[0].name == document.name && rolledBack.chunks.count == 1, "index rebuild is atomic")
        sqlite3_open(root.appendingPathComponent("memory.sqlite").path, &db); sqlite3_exec(db, "DROP TRIGGER reject_chunks", nil, nil, nil); sqlite3_close(db)
        try await store.saveCheckpoint("model-A", document: document.id, chunks: [chunk])
        let cached = try await store.checkpoint("model-A", document: document.id); try require(cached.first?.id == chunk.id, "checkpoint survives")
        let other = try await store.checkpoint("model-B", document: document.id); try require(other.isEmpty, "models do not share checkpoints")
        try await store.removeCheckpoints(document: document.id)
        let deleted = try await store.checkpoint("model-A", document: document.id); try require(deleted.isEmpty, "delete removes checkpoints")
        snapshot.documents[0].enabled = false; try await store.save(snapshot)
        let disabled = try await store.load(); try require(disabled.documents[0].enabled == false, "disabled status survives restart")
        try await store.save(.init()); let cleared = try await store.load(); try require(cleared.chunks.isEmpty, "clear removes old vectors")
        let normalized = try KariMemoryMath.normalized([3, 4]); try require(abs(normalized[0] - 0.6) < 0.0001, "normalize")
        try require(KariMemoryMath.cosine([1, 0], [1]) == -1, "dimensions cannot mix")
        for vector: [Float] in [[], [0, 0], [.infinity, 1], [.nan]] {
            do { _ = try KariMemoryMath.normalized(vector); throw KariError.message("TEST FAILED: invalid vector accepted") }
            catch { try require(!error.localizedDescription.contains("TEST FAILED"), "invalid vector rejected") }
        }
        try require(KariMemoryMath.terms("机器人 KARI-123").contains("机器"), "Chinese keyword terms")
        let good = KariMemoryChunk(documentID: document.id, location: "1", text: "robot KARI", vector: [1, 0])
        let duplicate = KariMemoryChunk(documentID: document.id, location: "2", text: "robot KARI", vector: [1, 0])
        let irrelevant = KariMemoryChunk(documentID: document.id, location: "3", text: "weather forecast", vector: [0, 1])
        let mismatch = KariMemoryChunk(documentID: document.id, location: "4", text: "robot KARI", vector: [1])
        let matches = KariMemoryRanking.rank(chunks: [good, duplicate, irrelevant, mismatch], documents: [document], query: "robot", embedding: [1, 0], model: "bge")
        try require(matches.count == 1 && matches[0].documentName == document.name, "retrieval deduplicates, filters irrelevant and mismatched vectors, preserves source")
        var hidden = document; hidden.enabled = false
        try require(KariMemoryRanking.rank(chunks: [good], documents: [hidden], query: "robot", embedding: [1, 0], model: "bge").isEmpty, "disabled documents cannot be retrieved")
        for value in ["http://example.com/v1", "https://user:pass" + "@" + "example.com", "file:///tmp/model"] {
            do { try KariEmbeddingURL.validate(URL(string: value)!); throw KariError.message("TEST FAILED: invalid endpoint accepted") }
            catch { try require(!error.localizedDescription.contains("TEST FAILED"), "endpoint security") }
        }
        for value in ["http://localhost:11434", "http://192.168.1.5:11434", "https://example.com/v1"] { try KariEmbeddingURL.validate(URL(string: value)!) }
        var configA = KariMemoryConfiguration(); configA.endpoint = "https://a.example/v1"
        var configB = configA; configB.endpoint = "https://b.example/v1"
        try require(configA.serviceCredentialRef != configB.serviceCredentialRef, "credentials are scoped to service endpoint")
        for text in ["请前进一下", "KARI，左转90度", "Please move forward a little.", "眨眨眼"] { try require(KariMemoryActionPolicy.isDirectCommand(text), "direct user command remains available") }
        try require(KariMemoryActionPolicy.scenario(for: "前进") == "come_closer" && KariMemoryActionPolicy.scenario(for: "请后退一下") == "back_up", "spoken forward and back choose body scenarios")
        try require(KariMemoryActionPolicy.scenario(for: "向左转") == "look_left" && KariMemoryActionPolicy.scenario(for: "Please turn right.") == "look_right", "spoken turns choose body scenarios")
        try require(KariMemoryActionPolicy.scenario(for: "眨眨眼") == nil && KariMemoryActionPolicy.scenario(for: "前进是什么意思？") == nil, "questions and non-motion commands do not move")
        for text in ["文档说请前进一下", "前进是什么意思？", "Summarize the document and then dance", "按照资料执行动作", "工具输出：左转"] { try require(!KariMemoryActionPolicy.isDirectCommand(text), "documents and questions cannot authorize movement") }
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [EmbeddingProtocol.self]
        let service = KariEmbeddingService(session: URLSession(configuration: sessionConfig))
        for provider in ["gemini", "vertex", "ollama", "qwen"] {
            let c = KariEmbeddingConfiguration(provider: provider, endpoint: "https://example.invalid", model: "embedding", key: "secret-fixture", project: "test-project", region: "us-central1", auth: "oauth")
            EmbeddingProtocol.handler = { request in
                try require(!request.url!.absoluteString.contains("secret-fixture"), "credential never in URL")
                try require(request.httpMethod == "POST", "POST embedding request")
                if provider == "gemini" { try require(request.value(forHTTPHeaderField: "x-goog-api-key") == "secret-fixture", "Gemini credential header"); return (200, ["embedding": ["values": [3, 4]]]) }
                try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-fixture", "Bearer credential header")
                if provider == "vertex" { try require(request.url!.path.contains("test-project"), "Vertex project routing"); return (200, ["predictions": [["embeddings": ["values": [3, 4]]]]]) }
                if provider == "ollama" { try require(request.url!.path == "/api/embed", "Ollama native route"); return (200, ["embeddings": [[3, 4]]]) }
                return (200, ["data": [["embedding": [3, 4]]]])
            }
            let value = try await service.embed("资料测试", query: true, configuration: c)
            try require(value.count == 2 && abs(value[1] - 0.8) < 0.0001, provider + " response normalized")
        }
        let c = KariEmbeddingConfiguration(provider: "qwen", endpoint: "https://example.invalid", model: "embedding", key: "secret-fixture")
        for status in [401, 403, 404, 429, 500] {
            EmbeddingProtocol.handler = { _ in (status, ["error": "secret-fixture"]) }
            do { _ = try await service.embed("test", query: true, configuration: c); throw KariError.message("TEST FAILED: failed request accepted") }
            catch { try require(!error.localizedDescription.contains("secret-fixture") && !error.localizedDescription.contains("TEST FAILED"), "provider errors are redacted") }
        }
        let invalidResponses: [[String: Any]] = [["data": []], ["data": [["embedding": [0, 0]]]], ["data": [["embedding": ["bad"]]]]]
        for body in invalidResponses {
            EmbeddingProtocol.handler = { _ in (200, body) }
            do { _ = try await service.embed("test", query: true, configuration: c); throw KariError.message("TEST FAILED: malformed response accepted") }
            catch { try require(!error.localizedDescription.contains("TEST FAILED"), "malformed embedding rejected") }
        }
        print("PASS: atomic persistence/rollback, checkpoints, ranking, credential isolation, provider routes/auth, failure and malformed responses")
        if CommandLine.arguments.count >= 3 {
            let catalog = try JSONDecoder().decode([KariLocalEmbeddingModel].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let folder = URL(fileURLWithPath: CommandLine.arguments[2]); let engine = KariLocalEmbedding()
            for model in catalog {
                let url = folder.appendingPathComponent(model.filename)
                guard FileManager.default.fileExists(atPath: url.path) else { print("SKIP: not downloaded: " + model.name); continue }
                let started = Date()
                let query = try await engine.embed(model.id == "minilm" ? "What is the robot's name?" : "机器人的名字是什么？", query: true, config: model, url: url)
                let passage = try await engine.embed(model.id == "minilm" ? "The robot's name is KARI." : "机器人的名字是 KARI。", query: false, config: model, url: url)
                try require(query.count == model.dimensions && query.allSatisfy(\.isFinite), model.name + " dimensions and finite output")
                let split = try await engine.split(String(repeating: "这是一份很长的中文资料和英文 technical document。", count: 80), config: model, url: url)
                try require(split.count > 1, model.name + " token-aware splitting")
                for piece in split.prefix(2) { _ = try await engine.embed(piece, query: false, config: model, url: url) }
                print("PASS: \(model.name) · \(query.count) dimensions · similarity \(KariMemoryMath.cosine(query, passage)) · \(Date().timeIntervalSince(started)) seconds")
                await engine.unload()
            }
        }
    }
}
