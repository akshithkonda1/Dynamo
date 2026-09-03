import Foundation

/// Calendar / reminder sneak-peek stages, scaled to the user's lead window.
enum CalendarPeekPolicy {
    /// `now` · optional `t5` / `t15` · `tlead` for the first fire at the lead edge.
    /// `nil` when outside the announce window (too far out, or started >90s ago).
    static func stage(intervalUntilStart: TimeInterval, leadMinutes: Int) -> String? {
        let lead = TimeInterval(min(60, max(5, leadMinutes))) * 60
        guard intervalUntilStart <= lead, intervalUntilStart > -90 else { return nil }
        if intervalUntilStart <= 45 { return "now" }
        if lead >= 12 * 60, intervalUntilStart <= 5 * 60 + 20 { return "t5" }
        if lead >= 25 * 60, intervalUntilStart <= 15 * 60 + 20 { return "t15" }
        return "tlead"
    }
}
