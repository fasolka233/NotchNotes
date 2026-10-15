import AppKit
import Combine
import Foundation
import UserNotifications

/// Напоминания и утренняя сводка. Опрашиваем заметки раз в 15 с.
///
/// Звук без следа легко прослушать, поэтому всё уходит в Центр уведомлений:
/// баннер остаётся в списке, даже если в эту минуту никого не было за Mac.
/// ponytail: работает, пока приложение запущено (оно живёт в меню-баре);
/// будить систему из выключенного состояния — уже UNCalendarNotificationTrigger.
final class ReminderCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    /// Куда вести пользователя: сработало напоминание или кликнули по баннеру
    enum Target: Equatable {
        case note(Note.ID)
        case tasks
    }

    @Published private(set) var target: Target?
    /// nil — ещё не знаем; false — уведомления запрещены в системных настройках
    @Published private(set) var notificationsAllowed: Bool?

    private weak var store: NotesStore?
    private var ticker: Timer?

    /// Без бандла (`swift run`, selfcheck) UNUserNotificationCenter роняет процесс
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil || CommandLine.arguments.contains("--selfcheck")
        ? nil : .current()

    /// Час утренней сводки
    static let digestHour = 9

    init(store: NotesStore) {
        self.store = store
        super.init()
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.refreshPermission()
        }
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
        for note in due {
            store.setReminder(nil, for: note.id)   // одноразовое: гасим, чтобы не звенело в цикле
            post(id: "reminder-\(note.id)", title: note.title,
                 body: "Напоминание", target: .note(note.id))
        }
        if let first = due.first { target = .note(first.id) }
        digestIfNeeded(now: now)
    }

    /// Раз в день, при первой проверке после 9:00. Сон Mac не мешает:
    /// проснулся в 11 — сводка придёт в 11.
    private func digestIfNeeded(now: Date) {
        // пока система не ответила про права, день не «тратим» — иначе первая
        // сводка ушла бы в никуда, пока висит запрос разрешения
        guard notificationsAllowed == true, Prefs.shared.morningDigest, let store,
              Calendar.current.component(.hour, from: now) >= Self.digestHour else { return }
        let day = Note.isoDay.string(from: now)
        guard UserDefaults.standard.string(forKey: "digest.lastDay") != day else { return }
        UserDefaults.standard.set(day, forKey: "digest.lastDay")

        guard let body = Self.digestText(today: store.tasks(.today).count,
                                         overdue: store.tasks(.overdue).count) else { return }
        post(id: "digest-\(day)", title: "Задачи на сегодня", body: body, target: .tasks)
    }

    /// «3 задачи на сегодня, из них просрочено 1». Нечего делать — молчим.
    static func digestText(today: Int, overdue: Int) -> String? {
        guard today > 0 else { return nil }
        var s = "\(today) \(plural(today, "задача", "задачи", "задач")) на сегодня"
        if overdue > 0 { s += ", из них просрочено \(overdue)" }
        return s
    }

    private func post(id: String, title: String, body: String, target: Target) {
        guard let center, notificationsAllowed != false else {
            NSSound(named: "Ping")?.play()     // уведомления запрещены — хотя бы звук
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if case .note(let id) = target { content.userInfo = ["note": id.uuidString] }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func refreshPermission() {
        center?.getNotificationSettings { [weak self] s in
            let allowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            DispatchQueue.main.async {
                self?.notificationsAllowed = allowed
                self?.check()               // разрешили — сводка не ждёт следующего тика
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Приложение для системы всегда «активно» — без этого баннер бы не показался
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["note"] as? String
        let t: Target = raw.flatMap(UUID.init(uuidString:)).map { .note($0) } ?? .tasks
        DispatchQueue.main.async { self.target = t }
        done()
    }
}

/// «1 задача», «2 задачи», «5 задач»
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    if (11...14).contains(n % 100) { return many }
    switch n % 10 {
    case 1:     return one
    case 2...4: return few
    default:    return many
    }
}
