import Foundation
import Testing
@testable import VoiceInput

@Suite(.serialized)
struct AccountPolishTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voiceinput-account-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL,
                     input: Data? = nil, timeout: TimeInterval = 3,
                     cancelBeforeStart: Bool = false, cancelAfter: TimeInterval? = nil) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            let task = AccountCommandTask(executable: URL(fileURLWithPath: executable),
                                          arguments: arguments, directory: directory,
                                          input: input, timeout: timeout) { result in
                #expect(Thread.isMainThread)
                continuation.resume(returning: result)
            }
            if cancelBeforeStart { task.cancel() }
            task.start()
            task.start() // Starting twice must never duplicate a process/completion.
            if let cancelAfter {
                DispatchQueue.global().asyncAfter(deadline: .now() + cancelAfter) { task.cancel() }
            }
        }
    }

    @Test func preservesUnicodeStdinAndTreatsArgumentsAsData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "语音原文\n$(touch NEVER_CREATE) `echo nope`; \\\"quote\\\""
        let echoed = await run("/bin/cat", [], in: directory, input: Data(text.utf8))
        #expect(try echoed.get() == text)
        let literal = await run("/usr/bin/printf", ["%s", text], in: directory)
        #expect(try literal.get() == text)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("NEVER_CREATE").path))
    }

    @Test func timeoutAndCancellationFinishOnMainWithoutReturningPartialOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Date()
        let timeout = await run("/bin/sleep", ["10"], in: directory, timeout: 0.05)
        if case .failure(let error) = timeout {
            guard case .timeout? = error as? AccountCommandError else {
                Issue.record("Expected timeout, got \(error)"); return
            }
        } else { Issue.record("Timed-out process returned success") }
        #expect(Date().timeIntervalSince(started) < 3)
        let cancelled = await run("/bin/sleep", ["10"], in: directory, cancelAfter: 0.05)
        if case .failure(let error) = cancelled {
            guard case .cancelled? = error as? AccountCommandError else {
                Issue.record("Expected cancellation, got \(error)"); return
            }
        } else { Issue.record("Cancelled process returned success") }
    }

    @Test func cancellationBeforeStartNeverLaunchesCommand() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("should-not-exist")
        let result = await run("/usr/bin/touch", [marker.path], in: directory, cancelBeforeStart: true)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        if case .failure(let error) = result {
            guard case .cancelled? = error as? AccountCommandError else {
                Issue.record("Expected cancellation, got \(error)"); return
            }
        } else { Issue.record("Pre-cancelled process returned success") }
    }

    @Test func processErrorDoesNotExposeStderrOrReturnPartialText() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await run("/bin/sh", ["-c", "printf partial; printf 'auth TEST_SECRET_SENTINEL' >&2; exit 7"], in: directory)
        if case .failure(let error) = result {
            #expect(!error.localizedDescription.contains("TEST_SECRET_SENTINEL"))
            #expect(!error.localizedDescription.contains("partial"))
            #expect(error.localizedDescription.contains("7"))
            #expect(error.localizedDescription.contains("Sign in"))
        } else { Issue.record("Nonzero exit returned success") }
    }

    @Test func oversizedOutputFailsInsteadOfSilentlyTruncatingTranscript() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await run("/usr/bin/head", ["-c", "1048600", "/dev/zero"], in: directory)
        if case .failure(let error) = result {
            #expect(error.localizedDescription.contains("size limit"))
        } else { Issue.record("Oversized output returned a truncated success") }
    }

    @Test func exitedCommandDoesNotWaitForDescendantInheritedPipes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date()
        let result = await run("/bin/sh", ["-c", "sleep 1 & printf done"], in: directory, timeout: 2)
        #expect(try result.get() == "done")
        #expect(Date().timeIntervalSince(start) < 0.8)
    }

    @Test func blockedLargeStdinStillRespondsToTimeout() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date()
        let result = await run("/bin/sleep", ["10"], in: directory,
                               input: Data(repeating: 65, count: 1_048_576), timeout: 0.05)
        if case .failure(let error) = result {
            guard case .timeout? = error as? AccountCommandError else {
                Issue.record("Expected timeout, got \(error)"); return
            }
        } else { Issue.record("Blocked stdin returned success") }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func codexInvocationKeepsTranscriptOutOfArgumentsAndUsesFinalMessageFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "ACCOUNT_TEST_PRIVATE_TRANSCRIPT"
        let invocation = try AccountPolishClient.invocation(provider: .codex, model: "chosen-model", directory: directory, input: text)
        #expect(invocation.standardInput == Data(text.utf8))
        #expect(!invocation.arguments.contains(where: { $0.contains(text) }))
        #expect(invocation.arguments.first == "exec")
        #expect(invocation.arguments.last == "-")
        #expect(invocation.arguments.contains("--ignore-user-config"))
        #expect(invocation.arguments.contains("--ephemeral"))
        #expect(invocation.arguments.contains("--output-last-message"))
        #expect(invocation.outputFile?.deletingLastPathComponent().path == directory.path)
        for feature in ["shell_tool", "hooks", "plugins", "apps", "multi_agent"] {
            #expect(zip(invocation.arguments, invocation.arguments.dropFirst()).contains { $0 == "--disable" && $1 == feature })
        }
        #expect(zip(invocation.arguments, invocation.arguments.dropFirst()).contains { $0 == "--model" && $1 == "chosen-model" })
    }

    @Test func grokInvocationUsesTextPromptFileAndDisablesHiddenMemoryFeature() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "ACCOUNT_TEST_PRIVATE_TRANSCRIPT"
        let invocation = try AccountPolishClient.invocation(provider: .grok, model: "", directory: directory, input: text)
        let index = try #require(invocation.arguments.firstIndex(of: "--prompt-file"))
        let prompt = URL(fileURLWithPath: invocation.arguments[index + 1])
        #expect(try String(contentsOf: prompt, encoding: .utf8) == text)
        let permissions = try FileManager.default.attributesOfItem(atPath: prompt.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(!invocation.arguments.contains(where: { $0.contains(text) }))
        #expect(invocation.arguments.contains("--no-memory"))
        #expect(prompt.pathExtension == "txt")
        #expect(zip(invocation.arguments, invocation.arguments.dropFirst()).contains { $0 == "--disallowed-tools" && $1 == "read_file,search_tool,use_tool" })
        #expect(invocation.arguments.contains("--no-subagents"))
        #expect(invocation.arguments.contains("--disable-web-search"))
        #expect(zip(invocation.arguments, invocation.arguments.dropFirst()).contains { $0 == "--deny" && $1 == "*" })
        #expect(invocation.standardInput == nil)
    }

    @Test func grokHomeIsIsolatedWhileOfficialCLIStillOwnsOriginalAuthPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = try AccountPolishClient.grokEnvironment(directory: directory, inherited: ["GROK_HOME": "/test/original-grok"])
        #expect(env["GROK_AUTH_PATH"] == "/test/original-grok/auth.json")
        #expect(env["GROK_HOME"] == directory.appendingPathComponent("grok-home").path)
        #expect(env["GROK_HOME"] != "/test/original-grok")
        #expect(env["GROK_DISABLE_API_KEY_AUTH"] == "true")
        #expect(env["GROK_MANAGED_MCPS_ENABLED"] == "false")
        for provider in ["CLAUDE", "CURSOR", "CODEX"] {
            for feature in ["MCPS", "HOOKS", "SKILLS", "RULES"] {
                #expect(env["GROK_\(provider)_\(feature)_ENABLED"] == "false")
            }
        }
        let custom = try AccountPolishClient.grokEnvironment(directory: directory,
            inherited: ["GROK_HOME": "/test/original-grok", "GROK_AUTH_PATH": "/test/custom-auth.json"])
        #expect(custom["GROK_AUTH_PATH"] == "/test/custom-auth.json")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("grok-home/auth.json").path))
    }

    @Test func grokOutputRequiresCompletedTextAndIgnoresThoughtMetadata() throws {
        let completed = #"{"text":"完整文本","thought":"private reasoning","stopReason":"end_turn"}"#
        #expect(try AccountPolishClient.grokText(from: completed) == "完整文本")
        for reason in ["max_tokens", "max_turn_requests", "refusal", "cancelled"] {
            let incomplete = "{\"text\":\"半段文字\",\"stopReason\":\"\(reason)\"}"
            #expect(throws: (any Error).self) { try AccountPolishClient.grokText(from: incomplete) }
        }
        for invalid in ["plain text", "{}", #"{"text":" ","stopReason":"end_turn"}"#] {
            #expect(throws: (any Error).self) { try AccountPolishClient.grokText(from: invalid) }
        }
    }

    @Test func fakeCodexAdapterReadsOnlyFinalMessageAndRemovesTemporarySession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-codex")
        let contents = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then
            shift
            printf '  完整润色结果  ' > "$1"
            printf '%s' "$PWD" > "$0.session-path"
            printf 'diagnostic output must not be pasted' >&1
            exit 0
          fi
          shift
        done
        exit 9
        """
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result: Result<String, Error> = await withCheckedContinuation { continuation in
            _ = AccountPolishClient.polish(provider: .codex, model: "", executablePath: script.path,
                                           text: "原文", rules: "保持原意") {
                #expect(Thread.isMainThread)
                continuation.resume(returning: $0)
            }
        }
        #expect(try result.get() == "完整润色结果")
        let sessionPath = try String(contentsOfFile: script.path + ".session-path", encoding: .utf8)
        // Adapter removes the private directory immediately after callback return.
        for _ in 0..<20 where FileManager.default.fileExists(atPath: sessionPath) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!FileManager.default.fileExists(atPath: sessionPath))
    }
}
