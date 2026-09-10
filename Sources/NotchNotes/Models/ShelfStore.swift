import AppKit
import Combine

/// «1 файл», «2 файла», «5 файлов» — подсказки на челке читаются по-русски
func filesWord(_ n: Int) -> String {
    if (11...14).contains(n % 100) { return "файлов" }
    switch n % 10 {
    case 1:    return "файл"
    case 2...4: return "файла"
    default:   return "файлов"
    }
}

final class ShelfStore: ObservableObject {

    struct Item: Identifiable, Codable, Hashable {
        var id = UUID()
        var path: String
        var addedAt = Date()

        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
        var ext: String { url.pathExtension.uppercased() }
        var exists: Bool { FileManager.default.fileExists(atPath: path) }

        var sizeString: String {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    @Published var items: [Item] = []

    private let fileURL: URL
    private var bag = Set<AnyCancellable>()

    init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNotes", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("shelf.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded.filter(\.exists)
        }

        $items
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] list in
                guard let self, let data = try? JSONEncoder().encode(list) else { return }
                try? data.write(to: self.fileURL, options: .atomic)
            }
            .store(in: &bag)
    }

    @discardableResult
    func add(urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard !items.contains(where: { $0.path == path }) else { continue }
            items.insert(Item(path: path), at: 0)
            added += 1
        }
        return added
    }

    func remove(_ id: Item.ID) { items.removeAll { $0.id == id } }
    func clear() { items.removeAll() }

    /// Файл могли переместить или удалить мимо нас
    func pruneMissing() { items.removeAll { !$0.exists } }

    func addFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Добавить"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.add(urls: panel.urls)
        }
    }

    // MARK: - Вынос наружу

    /// Провайдер для перетаскивания файла из полки в другое приложение.
    /// `NSItemProvider(contentsOf:)` возвращает nil для папок — тогда отдаём file-url.
    func itemProvider(for item: Item) -> NSItemProvider {
        guard item.exists else { return NSItemProvider() }
        if let p = NSItemProvider(contentsOf: item.url) {
            p.suggestedName = item.name
            return p
        }
        return NSItemProvider(object: item.url as NSURL)
    }

    func share(_ list: [Item]) {
        SharePresenter.shared.shareFiles(list.map(\.url))
    }

    func shareAll() { share(items) }

    func icon(for item: Item) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.path)
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(_ item: Item) {
        NSWorkspace.shared.open(item.url)
    }

    /// Кладём в буфер и сами файлы (Finder/Почта вставят их), и текстовые пути (терминал/IDE)
    func copy(_ list: [Item]) {
        let alive = list.filter(\.exists)
        guard !alive.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(alive.map(\.url) as [NSURL])
        pb.setString(alive.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func copyAll() { copy(items) }
}
