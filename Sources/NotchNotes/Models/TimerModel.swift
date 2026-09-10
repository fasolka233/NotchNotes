import Foundation
import AppKit

final class TimerModel: ObservableObject {

    enum Phase: String {
        case work, shortBreak, longBreak

        var title: String {
            switch self {
            case .work:       return "работа"
            case .shortBreak: return "перерыв"
            case .longBreak:  return "большой перерыв"
            }
        }
        var isBreak: Bool { self != .work }
    }

    @Published private(set) var total: Int = 25 * 60
    @Published private(set) var remaining: Int = 25 * 60
    @Published private(set) var isRunning = false
    @Published private(set) var isFinished = false

    /// Помодоро: после работы автоматически стартует перерыв, каждый 4-й — длинный
    @Published var pomodoroEnabled = false
    @Published private(set) var phase: Phase = .work
    @Published private(set) var completedCycles = 0

    let presets = [5, 10, 15, 25, 45, 60]
    private var workMinutes = 25
    private let shortBreakMinutes = 5
    private let longBreakMinutes = 15

    private var ticker: Timer?
    private var endDate: Date?

    var progress: Double {
        total > 0 ? min(1, max(0, 1 - Double(remaining) / Double(total))) : 0
    }

    var formatted: String {
        let m = remaining / 60, s = remaining % 60
        if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// Показывать ли таймер на свёрнутой челке
    var isAmbient: Bool { isRunning || isFinished }

    // MARK: - Управление

    func setMinutes(_ m: Int) {
        pause()
        total = max(60, m * 60)
        remaining = total
        isFinished = false
        if phase == .work { workMinutes = m }
    }

    func resetCycles() {
        completedCycles = 0
        phase = .work
        setMinutes(workMinutes)
    }

    func adjust(seconds: Int) {
        let newTotal = max(60, min(240 * 60, total + seconds))
        let diff = newTotal - total
        total = newTotal
        if isRunning {
            remaining = max(1, remaining + diff)
            endDate = Date().addingTimeInterval(TimeInterval(remaining))
        } else {
            remaining = total
            isFinished = false
        }
    }

    func start() {
        guard !isRunning else { return }
        if remaining <= 0 { remaining = total }
        isFinished = false
        endDate = Date().addingTimeInterval(TimeInterval(remaining))
        isRunning = true

        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func pause() {
        isRunning = false
        ticker?.invalidate()
        ticker = nil
        endDate = nil
    }

    func reset() {
        pause()
        remaining = total
        isFinished = false
    }

    func toggle() { isRunning ? pause() : start() }

    // MARK: - Тик

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        if remaining == 0 { finish() }
    }

    private func finish() {
        pause()
        remaining = 0
        isFinished = true
        playChime()
        NSApp.requestUserAttention(.criticalRequest)

        guard pomodoroEnabled else { return }
        // даём услышать сигнал, потом переключаем фазу
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.advancePhase()
        }
    }

    /// Только для selfcheck: доводит таймер до состояния «отзвенел», не ожидая минут
    func forceFinishForTesting() {
        pause()
        remaining = 0
        isFinished = true
    }

    func advancePhase() {
        guard pomodoroEnabled, isFinished else { return }
        switch phase {
        case .work:
            completedCycles += 1
            phase = completedCycles % 4 == 0 ? .longBreak : .shortBreak
        case .shortBreak, .longBreak:
            phase = .work
        }

        let minutes: Int
        switch phase {
        case .work:       minutes = workMinutes
        case .shortBreak: minutes = shortBreakMinutes
        case .longBreak:  minutes = longBreakMinutes
        }

        pause()
        total = max(60, minutes * 60)
        remaining = total
        isFinished = false
        start()
    }

    private func playChime() {
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.55) {
                NSSound(named: "Glass")?.play()
            }
        }
    }
}
