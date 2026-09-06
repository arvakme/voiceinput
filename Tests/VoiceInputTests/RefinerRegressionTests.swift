import Foundation
import Testing
@testable import VoiceInput

struct RefinerRegressionTests {
    private func response(_ content: Any, finishReason: String? = "stop") throws -> Data {
        var choice: [String: Any] = ["message": ["role": "assistant", "content": content]]
        if let finishReason { choice["finish_reason"] = finishReason }
        return try JSONSerialization.data(withJSONObject: ["choices": [choice]])
    }

    @Test func testCompletedUnicodeTextIsPreserved() throws {
        let text = "修复 VoiceInput 的取消逻辑，保留 API 名称。"
        #expect(try Refiner.parseCompletion(response("  \(text)\n"), stepLabel: "Polish") == text)
    }

    @Test func testEmptyOutputCannotReplaceBestTranscript() throws {
        for text in ["", " \n\t", "\"\"", "“   ”"] {
            #expect(throws: (any Error).self) {
                try Refiner.parseCompletion(response(text), stepLabel: "Translate")
            }
        }
    }

    @Test func testPartialOrFilteredOutputCannotBeInserted() throws {
        for reason in ["length", "content_filter", "error", "tool_calls"] {
            #expect(throws: (any Error).self) {
                try Refiner.parseCompletion(response("only part of the sentence", finishReason: reason), stepLabel: "Polish")
            }
        }
    }

    @Test func testReasoningOnlyResponseFailsSafely() throws {
        #expect(throws: (any Error).self) {
            try Refiner.parseCompletion(response(NSNull()), stepLabel: "Polish")
        }
    }

    @Test func testCompatibleEndpointWithoutFinishReasonRemainsSupported() throws {
        #expect(try Refiner.parseCompletion(response("Hello there.", finishReason: nil), stepLabel: "Polish") == "Hello there.")
    }

    @Test func testMalformedResponseFailsSafely() {
        #expect(throws: (any Error).self) {
            try Refiner.parseCompletion(Data("not JSON".utf8), stepLabel: "Polish")
        }
    }
}
