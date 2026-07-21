import Foundation

/// Saves system volume, ducks to a target percent during Meeting, restores after.
@MainActor
final class MeetingVolumeDucker {
    private var savedPercent: Int?
    private var isDucked = false
    /// Absolute system UI percent while in meeting (product: 25%).
    var targetPercent: Int = 25

    var isActive: Bool { isDucked }

    func enter() {
        SystemVolumeController.shared.start()
        SystemVolumeController.shared.refreshFromSystem()
        if !isDucked {
            savedPercent = SystemVolumeController.shared.percent
        }
        let target = min(100, max(1, targetPercent))
        let current = SystemVolumeController.shared.percent
        if current > target {
            SystemVolumeController.shared.suppressExternalAnnouncements(for: 1.0)
            SystemVolumeController.shared.setPercent(target)
        }
        isDucked = true
    }

    func exit() {
        guard isDucked else { return }
        if let saved = savedPercent {
            SystemVolumeController.shared.suppressExternalAnnouncements(for: 1.0)
            SystemVolumeController.shared.setPercent(saved)
        }
        savedPercent = nil
        isDucked = false
    }
}
