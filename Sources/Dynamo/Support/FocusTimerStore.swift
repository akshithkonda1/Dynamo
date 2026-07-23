import Foundation

@MainActor
final class FocusTimerStore: ObservableObject {
    static let shared = FocusTimerStore()

    @Published private(set) var isRunning = false
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var totalSeconds: Int = 0

    var onComplete: (() -> Void)?

    private var ticker: Timer?

    private init() {}

    func start(minutes: Int) {
        cancel()
        totalSeconds = minutes * 60
        remainingSeconds = totalSeconds
        isRunning = true
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        isRunning = false
        remainingSeconds = 0
        totalSeconds = 0
    }

    var progressFraction: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1.0 - Double(remainingSeconds) / Double(totalSeconds)
    }

    var formattedRemaining: String {
        let m = remainingSeconds / 60
        let s = remainingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func tick() {
        guard isRunning, remainingSeconds > 0 else { return }
        remainingSeconds -= 1
        if remainingSeconds == 0 {
            ticker?.invalidate()
            ticker = nil
            isRunning = false
            onComplete?()
        }
    }
}
