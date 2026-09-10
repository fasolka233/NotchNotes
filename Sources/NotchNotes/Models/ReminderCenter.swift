import AppKit
import Combine
import Foundation

/// Напоминалки. Опрашиваем заметки раз в 15 с и стреляем по наступившим срокам.
/// ponytail: работает, пока приложение запущено (оно живёт в меню-баре);
/// если понадобится будить систему из выключенного состояния — UNUserNotificationCenter.
final class ReminderCenter: ObservableObject {

    /// Заметка, по которой только что сработало напоминание
    @Published private(set) var fired: Note?

    private weak var store: NotesStore?
    private var ticker: Timer?

    init(store: NotesStore) {
        self.store = store
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        check()
    }

    deinit { ticker?.invalidate() }

    func check(now: Date = Date()) {
        guard let store else { return }
        let due = store.notes.filter { note in
            guard let at = note.reminderAt else { return false }
            return at <= now
        }
        guard !due.isEmpty else { return }

        for note in due {
            store.setReminder(nil, for: note.id)   // одноразовое: гасим, чтобы не звенело в цикле
        }
        alert()
        fired = due.first
    }

    private func alert() {
        guard NSApp != nil else { return }   // под --selfcheck приложения нет
        NSSound(named: "Ping")?.play()
        NSApp.requestUserAttention(.informationalRequest)
    }
}
