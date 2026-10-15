import Foundation
import Combine

/// Настройки из окна «Настройки…»: глобальные сочетания и утренняя сводка.
final class Prefs: ObservableObject {

    static let shared = Prefs()

    enum Shortcut: String, CaseIterable, Identifiable {
        case toggle, capture

        var id: String { rawValue }
        var hotKeyID: UInt32 { self == .toggle ? 1 : 2 }

        var title: String {
            switch self {
            case .toggle:  return "Открыть / закрыть панель"
            case .capture: return "Быстрая задача во «Входящие»"
            }
        }

        var fallback: HotKey.Combo { self == .toggle ? .toggle : .capture }
    }

    @Published private(set) var combos: [Shortcut: HotKey.Combo] = [:]
    /// Почему сочетание не работает — показываем в настройках рядом с ним
    @Published private(set) var problems: [Shortcut: String] = [:]

    @Published var morningDigest: Bool {
        didSet { defaults.set(morningDigest, forKey: "digest.enabled") }
    }

    private let defaults = UserDefaults.standard
    private var keys: [Shortcut: HotKey] = [:]

    private init() {
        morningDigest = defaults.object(forKey: "digest.enabled") as? Bool ?? true
        for s in Shortcut.allCases {
            let saved = defaults.data(forKey: "hotkey." + s.rawValue)
                .flatMap { try? JSONDecoder().decode(HotKey.Combo.self, from: $0) }
            combos[s] = saved ?? s.fallback
        }
    }

    /// Регистрирует сочетания. Вызывается один раз при запуске.
    func install(_ actions: [Shortcut: () -> Void]) {
        for (s, action) in actions { keys[s] = HotKey(id: s.hotKeyID, action: action) }
        Shortcut.allCases.forEach(register)
    }

    func set(_ combo: HotKey.Combo, for s: Shortcut) {
        combos[s] = combo
        defaults.set(try? JSONEncoder().encode(combo), forKey: "hotkey." + s.rawValue)
        Shortcut.allCases.forEach(register)   // конфликт мог появиться или уйти у соседа
    }

    func reset(_ s: Shortcut) {
        defaults.removeObject(forKey: "hotkey." + s.rawValue)
        combos[s] = s.fallback
        Shortcut.allCases.forEach(register)
    }

    /// Пока записываем новое сочетание, старое не должно срабатывать
    func suspend() { keys.values.forEach { $0.unregister() } }
    func resume() { Shortcut.allCases.forEach(register) }

    private func register(_ s: Shortcut) {
        guard let key = keys[s], let combo = combos[s] else { return }
        key.unregister()
        if let other = Shortcut.allCases.first(where: { $0 != s && combos[$0] == combo }),
           other.hotKeyID < s.hotKeyID {
            problems[s] = "Совпадает с «\(other.title)»"
        } else if HotKey.isTakenBySystem(combo) {
            problems[s] = "Занято системой (Spotlight, раскладка…) — выберите другое"
        } else if !key.register(combo) {
            problems[s] = "Занято другим приложением — выберите другое"
        } else {
            problems[s] = nil
        }
    }
}
