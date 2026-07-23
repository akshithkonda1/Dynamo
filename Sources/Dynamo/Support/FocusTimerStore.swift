import Foundation

enum PomodoroPhase: String {
    case work, shortBreak, longBreak

    var label: String {
        switch self {
        case .work: return "Work"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }

    var systemImage: String {
        switch self {
        case .work: return "timer"
        case .shortBreak: return "cup.and.saucer"
        case .longBreak: return "figure.walk"
        }
    }
}

@MainActor
final class FocusTimerStore: ObservableObject {
    static let shared = FocusTimerStore()

    @Published private(set) var isRunning = false
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var totalSeconds: Int = 0

    // Pomodoro
    @Published private(set) var isPomodoroMode = false
    @Published private(set) var pomodoroPhase: PomodoroPhase = .work
    @Published private(set) var completedCycles: Int = 0

    var onComplete: (() -> Void)?
    var onPomodoroTransition: ((PomodoroPhase) -> Void)?

    private var pomodoroWorkMinutes = 25
    private var pomodoroBreakMinutes = 5
    private var ticker: Timer?

    private init() {}

    func start(minutes: Int) {
        isPomodoroMode = false
        completedCycles = 0
        pomodoroPhase = .work
        beginCountdown(minutes: minutes)
    }

    func startPomodoro(workMinutes: Int = 25, breakMinutes: Int = 5) {
        isPomodoroMode = true
        pomodoroWorkMinutes = workMinutes
        pomodoroBreakMinutes = breakMinutes
        pomodoroPhase = .work
        completedCycles = 0
        beginCountdown(minutes: workMinutes)
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        isRunning = false
        remainingSeconds = 0
        totalSeconds = 0
        isPomodoroMode = false
        completedCycles = 0
        pomodoroPhase = .work
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

    private func beginCountdown(minutes: Int) {
        ticker?.invalidate()
        totalSeconds = minutes * 60
        remainingSeconds = totalSeconds
        isRunning = true
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard isRunning, remainingSeconds > 0 else { return }
        remainingSeconds -= 1
        if remainingSeconds == 0 {
            ticker?.invalidate()
            ticker = nil
            isRunning = false
            handleCompletion()
        }
    }

    private func handleCompletion() {
        guard isPomodoroMode else {
            onComplete?()
            return
        }
        switch pomodoroPhase {
        case .work:
            completedCycles += 1
            if completedCycles % 4 == 0 {
                pomodoroPhase = .longBreak
                onPomodoroTransition?(.longBreak)
                beginCountdown(minutes: 15)
            } else {
                pomodoroPhase = .shortBreak
                onPomodoroTransition?(.shortBreak)
                beginCountdown(minutes: pomodoroBreakMinutes)
            }
        case .shortBreak, .longBreak:
            pomodoroPhase = .work
            onPomodoroTransition?(.work)
            beginCountdown(minutes: pomodoroWorkMinutes)
        }
    }
}
