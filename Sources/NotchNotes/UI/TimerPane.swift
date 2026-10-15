import SwiftUI

struct TimerPane: View {
    @ObservedObject var timer: TimerModel

    var body: some View {
        HStack(spacing: 30) {
            dial
            controls
        }
        .foregroundStyle(Theme.Ink.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // пробел — старт/пауза, как в любом плеере
            KeyCommand.handlers[.timer] = { [timer] cmd in
                guard cmd == .toggle || cmd == .open else { return false }
                timer.toggle()
                return true
            }
        }
    }

    private var dialColor: Color {
        if timer.isFinished { return Theme.Accent.warning }
        return timer.pomodoroEnabled && timer.phase.isBreak
            ? Theme.Accent.success : Theme.Accent.tint
    }

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(Theme.Surface.field, lineWidth: 10)

            Circle()
                .trim(from: 0, to: timer.progress)
                .stroke(dialColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.motion(.linear(duration: 0.25)), value: timer.progress)

            VStack(spacing: 3) {
                Text(timer.formatted)
                    .font(Theme.Font.mono(34))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.primary)

                Text(timer.isFinished ? "Готово"
                     : timer.pomodoroEnabled ? timer.phase.title
                     : timer.isRunning ? "Идёт" : "Пауза")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(timer.isFinished ? Theme.Accent.warning : Theme.Ink.secondary)

                if timer.pomodoroEnabled {
                    Text("цикл \(timer.completedCycles + (timer.phase == .work ? 1 : 0))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
        }
        .frame(width: 160, height: 160)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Длительность")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Ink.tertiary)

            LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: Theme.Space.s),
                                     count: 3),
                      spacing: Theme.Space.s) {
                ForEach(timer.presets, id: \.self) { m in
                    presetButton(m)
                }
            }

            HStack(spacing: Theme.Space.s) {
                stepButton("minus", -60, hint: "Минус минута")
                stepButton("plus", 60, hint: "Плюс минута")
                Text("± 1 мин")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Ink.tertiary)
            }

            Divider().overlay(Theme.Stroke.hairline)

            HStack(spacing: Theme.Space.m) {
                Toggle("", isOn: $timer.pomodoroEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Помодоро").font(Theme.Font.label)
                    Text("перерыв 5 мин, каждый 4-й — 15")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Ink.tertiary)
                }
                Spacer(minLength: 0)
                if timer.completedCycles > 0 {
                    Button { timer.resetCycles() } label: {
                        Text("\(timer.completedCycles) 🍅")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.Surface.field, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Сбросить счётчик циклов")
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: Theme.Space.s) {
                Button { timer.toggle() } label: {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                        Text(timer.isRunning ? "Пауза" : "Старт")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Ink.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.Accent.tint,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                }
                .buttonStyle(.plain)
                .help(timer.isRunning ? "Поставить на паузу" : "Запустить таймер")

                Button { timer.reset() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 42)
                        .padding(.vertical, 10)
                        .background(Theme.Surface.field,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                }
                .buttonStyle(.plain)
                .help("Сбросить")
            }
        }
        .frame(maxWidth: 270)
    }

    private func presetButton(_ m: Int) -> some View {
        let isOn = timer.total == m * 60
        return Button { timer.setMinutes(m) } label: {
            Text("\(m) мин")
                .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Theme.Ink.primary : Theme.Ink.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isOn ? Theme.Surface.active : Theme.Surface.field,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        }
        .buttonStyle(.plain)
    }

    private func stepButton(_ icon: String, _ delta: Int, hint: String) -> some View {
        Button { timer.adjust(seconds: delta) } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: 30, height: 26)
                .background(Theme.Surface.field,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(hint)
    }
}
