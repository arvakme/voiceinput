import Foundation
import Testing
@testable import VoiceInput

struct CursorPolishTests {
    @Test func secretsAndDictationAreOnlyInStandardInput() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/cursor-polish-test")
        let helper = directory.appendingPathComponent("cursor-polish.mjs")
        let invocation = try CursorPolishClient.invocation(model: "composer-2.5", apiKey: "fake-cursor-key",
            sdkDirectory: directory.appendingPathComponent("sdk"), directory: directory, helper: helper,
            text: "private transcript $(do not execute)", rules: "Fix punctuation.")
        #expect(invocation.arguments == [helper.path])
        #expect(!invocation.environment.values.contains("fake-cursor-key"))
        let payload = try #require(JSONSerialization.jsonObject(with: invocation.standardInput) as? [String: String])
        #expect(payload["apiKey"] == "fake-cursor-key")
        #expect(payload["model"] == "composer-2.5")
        #expect(payload["input"]?.contains("private transcript $(do not execute)") == true)
        #expect(payload["nonce"]?.isEmpty == false)
        #expect(invocation.environment["NODE_OPTIONS"] == "")
        #expect(invocation.environment["CURSOR_DATA_DIR"] == directory.appendingPathComponent("cursor-data").path)
    }

    @Test func everyInvocationHasANewCompletionMarker() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/cursor-polish-test")
        func nonce() throws -> String {
            let invocation = try CursorPolishClient.invocation(model: "composer-2.5", apiKey: "fake-key",
                sdkDirectory: directory, directory: directory, helper: directory.appendingPathComponent("helper.mjs"),
                text: "test", rules: "Polish")
            let payload = try #require(JSONSerialization.jsonObject(with: invocation.standardInput) as? [String: String])
            return try #require(payload["nonce"])
        }
        #expect(try nonce() != nonce())
    }

    @Test func blankKeyOrModelCannotStartASDKRequest() {
        let directory = URL(fileURLWithPath: "/private/tmp/cursor-polish-test")
        for (key, model) in [("", "composer-2.5"), ("fake-key", " ")] {
            #expect(throws: (any Error).self) {
                try CursorPolishClient.invocation(model: model, apiKey: key, sdkDirectory: directory,
                    directory: directory, helper: directory.appendingPathComponent("helper.mjs"),
                    text: "test", rules: "Polish")
            }
        }
    }
}
