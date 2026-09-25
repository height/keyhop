import Foundation
import Testing
@testable import KeyHopCore

@Suite("Terminal receipt lifecycle")
struct LaunchHistoryTests {
    @Test func sameSecondReceiptAdvancesPendingRequestDespitePrecisionLoss() {
        let pending = LaunchRecord(profileID: "cli", state: .requested,
                                   launchedAt: Date(timeIntervalSince1970: 1_700_000_000.75),
                                   message: "Waiting", requestID: "same-request")
        let receipt = LaunchRecord(profileID: "cli", state: .launched,
                                   launchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   message: "Started", requestID: "same-request")
        #expect(LaunchHistory.shouldReplace(pending, with: receipt))
        #expect(!LaunchHistory.shouldReplace(receipt, with: pending))
    }

    @Test func completedRequestCannotRegressToOldRunningReceipt() {
        let date = Date()
        let exited = LaunchRecord(profileID: "cli", state: .exited, launchedAt: date, message: "Exited", requestID: "one")
        let running = LaunchRecord(profileID: "cli", state: .launched, launchedAt: date, message: "Running", requestID: "one")
        #expect(!LaunchHistory.shouldReplace(exited, with: running))
        #expect(LaunchHistory.shouldReplace(running, with: exited))
    }

    @Test func olderUnrelatedRequestCannotOverwriteNewAttempt() {
        let newer = LaunchRecord(profileID: "cli", state: .requested, launchedAt: Date(timeIntervalSince1970: 100), message: "New", requestID: "new")
        let older = LaunchRecord(profileID: "cli", state: .exited, launchedAt: Date(timeIntervalSince1970: 99), message: "Old", requestID: "old")
        #expect(!LaunchHistory.shouldReplace(newer, with: older))
    }
}
