import Testing
@testable import VoiceInput

struct ASRRegressionTests {
    @Test func testSuccessfulHandshakesDoNotAllowEndlessReconnects() {
        var policy = CaptionReconnectPolicy()
        // Every handshake succeeds, but the service then rejects the stream.
        for (index, expected) in [1.0, 2.0, 4.0].enumerated() {
            let now = Double(index * 5)
            policy.connected(at: now)
            #expect(policy.nextDelay(at: now + 1) == expected)
        }
        policy.connected(at: 15)
        #expect(policy.nextDelay(at: 16) == nil)
    }

    @Test func testFailedHandshakesAlsoExhaustRetryBudget() {
        var policy = CaptionReconnectPolicy()
        #expect(policy.nextDelay(at: 0) == 1)
        #expect(policy.nextDelay(at: 1) == 2)
        #expect(policy.nextDelay(at: 3) == 4)
        #expect(policy.nextDelay(at: 7) == nil)
    }

    @Test func testStableConnectionReplenishesRetryBudget() {
        var policy = CaptionReconnectPolicy()
        _ = policy.nextDelay(at: 0)
        _ = policy.nextDelay(at: 2)
        policy.connected(at: 5)
        #expect(policy.nextDelay(at: 35) == 1)
        // The previous healthy connection must not reset all later failures.
        #expect(policy.nextDelay(at: 37) == 2)
    }

    @Test func testExplicitRestartReplenishesRetryBudget() {
        var policy = CaptionReconnectPolicy()
        for now in 0..<4 { _ = policy.nextDelay(at: Double(now)) }
        policy.reset()
        #expect(policy.nextDelay(at: 10) == 1)
    }
}
