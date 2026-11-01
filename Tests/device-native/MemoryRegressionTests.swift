import XCTest
import UIKit
import PDFKit
@testable import KariNative

final class MemoryRegressionTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("memory-regression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testTextFormatsAndOfficeSources() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let extractor = KariMemoryExtractor()
        for ext in ["txt", "md"] {
            let url = root.appendingPathComponent("中文." + ext)
            try "# KARI\n机器人资料测试".write(to: url, atomically: true, encoding: .utf8)
            let parts = try await extractor.extract(url)
            XCTAssertTrue(parts.first?.text.contains("机器人资料测试") == true)
        }
        let utf16 = root.appendingPathComponent("utf16.txt")
        try "UTF16 中文内容".write(to: utf16, atomically: true, encoding: .utf16)
        let utf16Parts = try await extractor.extract(utf16); XCTAssertTrue(utf16Parts.first?.text.contains("中文内容") == true)
        let docx = root.appendingPathComponent("fixture.docx")
        try Data(base64Encoded: "UEsDBBQAAAAIAPZTXl2wZNCAdwAAAMUAAAARAAAAd29yZC9kb2N1bWVudC54bWyzKbdKyU8uzU3NK1GoyM3JK7Yqt1UqLcqzKs8vSlGysym3SspPqQTRBSCiCESU2Hk7BnkqPNmx9tm09hdbW55Nm2mjDxIGkUVgEqy4JCkHTEE0JaMb8mLhimcL9jxta326bicW/foQPfoQA/ShxunDHKSPcLgdAFBLAQIUAxQAAAAIAPZTXl2wZNCAdwAAAMUAAAARAAAAAAAAAAAAAACAAQAAAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAAAQABAD8AAACmAAAAAAA=")!.write(to: docx)
        let docxParts = try await extractor.extract(docx)
        let pptx = root.appendingPathComponent("fixture.pptx")
        try Data(base64Encoded: "UEsDBBQAAAAIAPZTXl0oe3wRQQAAAFkAAAAWAAAAcHB0L3NsaWRlcy9zbGlkZTEwLnhtbLMpsCrOSVGoyM3JK7YqsFUqLcqzKlCC8hMh/EQlO5tEqwIQUQQiSuyer1nztLfx6Z4FNvogLogsApNARfpgE+0AUEsDBBQAAAAIAPZTXl2oC5doRwAAAF4AAAAVAAAAcHB0L3NsaWRlcy9zbGlkZTIueG1ssymwKs5JUajIzckrtiqwVSotyrMqUILyEyH8RCU7m0SrAhBRBCJK7LwdgzwVnq9Z82RXz9M9C2z0QWIgsghMAlXqg421AwBQSwECFAMUAAAACAD2U15dKHt8EUEAAABZAAAAFgAAAAAAAAAAAAAAgAEAAAAAcHB0L3NsaWRlcy9zbGlkZTEwLnhtbFBLAQIUAxQAAAAIAPZTXl2oC5doRwAAAF4AAAAVAAAAAAAAAAAAAACAAXUAAABwcHQvc2xpZGVzL3NsaWRlMi54bWxQSwUGAAAAAAIAAgCHAAAA7wAAAAAA")!.write(to: pptx)
        let pptxParts = try await extractor.extract(pptx)
        let xlsx = root.appendingPathComponent("fixture.xlsx")
        try Data(base64Encoded: "UEsDBBQAAAAIAPZTXl2WaaZqSgAAAFkAAAAPAAAAeGwvd29ya2Jvb2sueG1ssynPL8pOys/PVqjIzckrtiqyVSotyrMqUrKzKc5ITS0phtIKeYm5qbZKT3Ytfzq58cXCFUoKRVaZKbZKRYZK+nY2+jC1+jDj7ABQSwMEFAAAAAgA9lNeXc4P4qg9AAAAVQAAABoAAAB4bC9fcmVscy93b3JrYm9vay54bWwucmVsc7MJSs1JLMnMzyvOyCwotrNB5ip4ptgqFRkqKYQkFqWnltgqlecXZRdnpKaWFOuDKUO9itwcJX07G31UUwBQSwMEFAAAAAgA9lNeXVVjxqEbAAAAHwAAABQAAAB4bC9zaGFyZWRTdHJpbmdzLnhtbLMpLi6xsynOtLMpsfN2DPK00Qdy9UF8fZAMAFBLAwQUAAAACAD2U15dnBWLym8AAACkAAAAGAAAAHhsL3dvcmtzaGVldHMvc2hlZXQxLnhtbLMpzy/KLs5ITS2xswFTLokliXY2RfnlCkW2SoZKdjbJIIajoZJCia1SMZBfZmdgo19mZ6OfDJVzMgSLGpmhCjtDtGTm5WTmpQaXFAEVZRbb2ZTYPdmx9tm0dht9oI36IBGQDn2ghUASyQX6CIcBAFBLAQIUAxQAAAAIAPZTXl2WaaZqSgAAAFkAAAAPAAAAAAAAAAAAAACAAQAAAAB4bC93b3JrYm9vay54bWxQSwECFAMUAAAACAD2U15dzg/iqD0AAABVAAAAGgAAAAAAAAAAAAAAgAF3AAAAeGwvX3JlbHMvd29ya2Jvb2sueG1sLnJlbHNQSwECFAMUAAAACAD2U15dVWPGoRsAAAAfAAAAFAAAAAAAAAAAAAAAgAHsAAAAeGwvc2hhcmVkU3RyaW5ncy54bWxQSwECFAMUAAAACAD2U15dnBWLym8AAACkAAAAGAAAAAAAAAAAAAAAgAE5AQAAeGwvd29ya3NoZWV0cy9zaGVldDEueG1sUEsFBgAAAAAEAAQADQEAAN4BAAAAAA==")!.write(to: xlsx)
        let xlsxParts = try await extractor.extract(xlsx)
        XCTAssertTrue(docxParts.map(\.text).joined().contains("表格内容"))
        XCTAssertEqual(pptxParts.first?.text, "KARI 第二张")
        XCTAssertEqual(pptxParts.first?.location, "幻灯片 1")
        XCTAssertTrue(xlsxParts.contains { $0.location.contains("产品表") && $0.text.contains("KARI") })
        XCTAssertTrue(xlsxParts.contains { $0.text.contains("26") })
        let bad = root.appendingPathComponent("bad.docx"); try Data("not a zip".utf8).write(to: bad)
        do { _ = try await extractor.extract(bad); XCTFail("Malformed archive accepted") } catch {}
    }
    @MainActor func testPDFTextAndScannedOCR() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let text = root.appendingPathComponent("text.pdf")
        try renderer.writePDF(to: text) { context in
            context.beginPage(); ("KARI Memory Test" as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
        }
        let image = UIGraphicsImageRenderer(size: bounds.size).image { context in
            UIColor.white.setFill(); context.fill(bounds)
            ("KARI SCANNED DOCUMENT" as NSString).draw(at: CGPoint(x: 30, y: 70), withAttributes: [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black])
        }
        let scan = root.appendingPathComponent("scan.pdf")
        let scanBytes = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in context.beginPage(); image.draw(in: bounds) }
        try scanBytes.write(to: scan)
        let textData = try Data(contentsOf: text), scanData = try Data(contentsOf: scan)
        print("PDF_FIXTURE text=\(textData.count) scan=\(scanData.count) textHeader=\(String(data: textData.prefix(12), encoding: .ascii) ?? "nil")")
        XCTAssertNotNil(PDFDocument(data: textData)); XCTAssertNotNil(PDFDocument(data: scanData))
        let extractor = KariMemoryExtractor()
        let textParts = try await extractor.extract(text); XCTAssertTrue(textParts.first?.text.contains("KARI") == true); XCTAssertEqual(textParts.first?.location, "第 1 页")
        let scanParts = try await extractor.extract(scan); XCTAssertTrue(scanParts.map(\.text).joined().contains("KARI"), "Scanned PDFs use on-device OCR")
        let cache = root.appendingPathComponent("Extracted/cache.json"); try await extractor.cache(scanParts, to: cache)
        let cached = try await extractor.cached(cache); XCTAssertEqual(cached?.first?.text, scanParts.first?.text)
    }
    func testAtomicStoreAndCheckpoints() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = KariMemoryStore(root: root)
        let doc = KariMemoryDocument(name: "资料", hash: "hash", file: "file.txt")
        let chunk = KariMemoryChunk(documentID: doc.id, location: "第 2 页", text: "资料", vector: [0.6, 0.8])
        try await store.save(.init(documents: [doc], chunks: [chunk], fingerprint: "model-A"))
        let loaded = try await KariMemoryStore(root: root).load(); XCTAssertEqual(loaded.chunks.first?.vector, [0.6, 0.8]); XCTAssertEqual(loaded.fingerprint, "model-A")
        try await store.saveCheckpoint("model-A", document: doc.id, chunks: [chunk])
        let checkpoint = try await store.checkpoint("model-A", document: doc.id); XCTAssertEqual(checkpoint.first?.id, chunk.id)
        let unrelated = try await store.checkpoint("model-B", document: doc.id); XCTAssertTrue(unrelated.isEmpty)
        try await store.removeCheckpoints(document: doc.id)
        let removed = try await store.checkpoint("model-A", document: doc.id); XCTAssertTrue(removed.isEmpty)
    }
    @MainActor func testCatalogAndBGEOnDeviceWhenStaged() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let downloads = KariModelDownloads(root: root, engine: KariLocalEmbedding())
        XCTAssertEqual(downloads.catalog.count, 5)
        XCTAssertEqual(Set(downloads.catalog.map(\.id)).count, 5)
        for model in downloads.catalog { XCTAssertEqual(model.sha256.count, 64); XCTAssertTrue(model.bytes > 0); XCTAssertFalse(model.revision.isEmpty) }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("kari-memory-device-test-bge.gguf")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Stage the verified BGE fixture in the test host's tmp directory to run device inference") }
        let model = try XCTUnwrap(downloads.catalog.first { $0.id == "bge" })
        let engine = KariLocalEmbedding(); let query = try await engine.embed("机器人叫什么名字？", query: true, config: model, url: fixture)
        let passage = try await engine.embed("机器人名字是 KARI。", query: false, config: model, url: fixture)
        XCTAssertEqual(query.count, 512); XCTAssertTrue(KariMemoryMath.cosine(query, passage) > 0.3)
        await engine.unload()
    }
    @MainActor func testLocalMemoryImportSearchDisableAndDelete() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("kari-memory-device-test-bge.gguf")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Stage the verified BGE fixture first") }
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = KariModelDownloads(root: root.appendingPathComponent("Models"), engine: KariLocalEmbedding())
        let model = try XCTUnwrap(probe.catalog.first { $0.id == "bge" })
        let target = probe.file(model); try FileManager.default.copyItem(at: fixture, to: target)
        try model.sha256.write(to: target.appendingPathExtension("verified"), atomically: true, encoding: .utf8)
        let suite = "kari.memory.regression." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let memory = KariMemoryService(defaults: defaults, root: root)
        var config = memory.configuration; config.mode = "phone"; config.localModel = "bge"; memory.configuration = config
        for _ in 0..<100 where !memory.ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(memory.ready)
        let text = root.appendingPathComponent("导入测试.txt")
        try "测试资料：机器人名字是 KARI。测试文档的识别暗号是紫色海豚。".write(to: text, atomically: true, encoding: .utf8)
        let chat = KariAIConfiguration.fresh("rule")
        memory.importFiles([text, text], chat: chat)
        for _ in 0..<1500 where memory.busy { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(memory.busy); XCTAssertEqual(memory.documents.count, 1, "Duplicate imports share one document")
        XCTAssertEqual(memory.documents.first?.status, "可用", memory.message)
        let doc = try XCTUnwrap(memory.documents.first)
        let hits = try await memory.search("文档里的识别暗号是什么？", chat: chat)
        XCTAssertEqual(hits.first?.documentName, doc.name); XCTAssertTrue(hits.first?.chunk.text.contains("紫色海豚") == true)
        await memory.setEnabled(doc.id, enabled: false)
        let disabled = try await memory.search("识别暗号", chat: chat); XCTAssertTrue(disabled.isEmpty)
        await memory.setEnabled(doc.id, enabled: true)
        let enabled = try await memory.search("识别暗号", chat: chat); XCTAssertFalse(enabled.isEmpty)
        let bad = root.appendingPathComponent("损坏.docx"); try Data("bad ZIP".utf8).write(to: bad)
        memory.importFiles([bad], chat: chat)
        for _ in 0..<1500 where memory.busy { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(memory.busy)
        let preserved = try await memory.search("识别暗号", chat: chat); XCTAssertTrue(preserved.first?.chunk.text.contains("紫色海豚") == true, "A bad import cannot replace a usable index")
        await memory.delete(doc.id)
        let afterDelete = try await memory.search("识别暗号", chat: chat); XCTAssertTrue(afterDelete.isEmpty, "Deleted documents never return")
        await memory.clear()
        XCTAssertTrue(memory.documents.isEmpty)
        await memory.engine.unload()
    }

    func testDocumentInstructionsCannotAuthorizeMotion() {
        XCTAssertTrue(KariMemoryActionPolicy.isDirectCommand("请前进一下"))
        XCTAssertTrue(KariMemoryActionPolicy.isDirectCommand("Please turn left."))
        XCTAssertFalse(KariMemoryActionPolicy.isDirectCommand("文档说请前进一下"))
        XCTAssertFalse(KariMemoryActionPolicy.isDirectCommand("前进是什么意思？"))
        XCTAssertFalse(KariMemoryActionPolicy.isDirectCommand("按照资料执行动作"))
        XCTAssertEqual(KariMemoryActionPolicy.scenario(for: "前进"), "come_closer")
        XCTAssertEqual(KariMemoryActionPolicy.scenario(for: "请后退一下"), "back_up")
        XCTAssertEqual(KariMemoryActionPolicy.scenario(for: "向左转"), "look_left")
        XCTAssertEqual(KariMemoryActionPolicy.scenario(for: "Please turn right."), "look_right")
        XCTAssertNil(KariMemoryActionPolicy.scenario(for: "眨眨眼"))
        XCTAssertNil(KariMemoryActionPolicy.scenario(for: "前进是什么意思？"))
    }

}
