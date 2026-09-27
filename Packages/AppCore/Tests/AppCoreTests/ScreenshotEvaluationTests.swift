import AppCore
import Foundation
import ShareCore
import Testing

/// 本機真實素材評測；清單與輸出放在忽略的 build 目錄，不將社群原圖提交到公開庫。
/// 清單格式為 [{"id":"sample","path":"/absolute/image.png"}]。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SCREENSHOT_EVAL_MANIFEST"] != nil))
struct ScreenshotEvaluationTests {
    struct Sample: Codable { let id: String; let path: String }
    struct Result: Codable {
        let id: String
        let maxPixel: Int?
        let bytes: Int
        let lines: [String]
        let suggestedName: String?
        let durationSeconds: Double
    }

    @Test func evaluateProvidedImages() async throws {
        let env = ProcessInfo.processInfo.environment
        let manifest = try #require(env["SCREENSHOT_EVAL_MANIFEST"])
        let output = try #require(env["SCREENSHOT_EVAL_OUTPUT"])
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var results: [Result] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for sample in samples {
            let original = try Data(contentsOf: URL(fileURLWithPath: sample.path))
            for size in [nil, 1024, 2048] as [Int?] {
                let data = try #require(size.map { ImageDownscale.jpeg(from: original, maxPixel: $0) } ?? original)
                let start = Date()
                let lines = await ScreenshotText.recognize(jpeg: data)
                results.append(Result(id: sample.id, maxPixel: size, bytes: data.count, lines: lines,
                                      suggestedName: ScreenshotText.guess(from: lines).name,
                                      durationSeconds: Date().timeIntervalSince(start)))
                if let size {
                    try data.write(to: directory.appendingPathComponent("\(sample.id)-\(size).jpg"))
                }
                // 每張完成即落盤，長時間評測中斷時仍保留已完成的觀測。
                try encoder.encode(results).write(to: directory.appendingPathComponent("ocr.json"), options: .atomic)
            }
        }
        #expect(results.count == samples.count * 3)
    }
}
