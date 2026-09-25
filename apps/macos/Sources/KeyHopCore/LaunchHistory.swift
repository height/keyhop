import Foundation

public enum LaunchHistory {
    /// Receipts for one Terminal request advance its lifecycle independently of
    /// timestamp precision. Unrelated requests remain ordered by event time.
    public static func shouldReplace(_ previous: LaunchRecord, with incoming: LaunchRecord) -> Bool {
        let sameRequest = incoming.requestID != nil && incoming.requestID == previous.requestID
        guard sameRequest || incoming.launchedAt >= previous.launchedAt else { return false }
        if sameRequest && previous.state != .requested && incoming.state == .requested { return false }
        if previous.state == .exited && incoming.state == .launched
            && (sameRequest || incoming.launchedAt == previous.launchedAt) { return false }
        return true
    }
}
