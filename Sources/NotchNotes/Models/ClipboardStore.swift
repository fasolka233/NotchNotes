import AppKit
import Combine

final class ClipboardStore: ObservableObject {

    struct Item: Identifiable, Codable, Hashable {
        var id = UUID()
        var text: String
        var date = Date()
        var isPinned = false
        /// Имя PNG в подпапке images — для скриншотов и картинок из буфера
        var imageFile: String?

        var isImage: Bool { imageFile != nil }

        var oneLine: String {
            text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var isLink: Bool {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.hasPrefix("http://") || t.hasPrefix("https://")
        }

        /// Грубая эвристика «это код» — по скобкам, отступам и типичным ключевым словам
        var isCode: Bool {
            guard !isImage, text.contains("\n") else { return false }
            let markers = ["{", "}", ";", "()", "=>", "def ", "func ", "class ",
                           "import ", "return ", "<div", "SELECT ", "#include"]
            let hits = markers.filter { text.contains($0) }.count
            return hits >= 2 || text.contains("\n    ") || text.contains("\n\t")
        }

        var icon: String {
            if isImage { return "photo" }
            if isLink { return "link" }
            if isCode { return "chevron.left.forwardslash.chevron.right" }
            if text.contains("\n") { return "text.alignleft" }
            return "textformat.abc"
        }

        /// Строка «12 слов · 87 симв.» — удобно при выписках и цитировании
        var stats: String {
            guard !isImage else { return text }
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            return "\(words) сл. · \(text.count) симв."
        }
    }

    @Published var items: [Item] = []
    @Published var isEnabled = true {
        didSet { isEnabled ? startPolling() : stopPolling() }
    }

    private var ticker: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private let maxItems = 80
    private let fileURL: URL
    private let imagesDir: URL
    private var bag = Set<AnyCancellable>()
    private var thumbCache: [String: NSImage] = [:]

    init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNotes", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("clipboard.json")
        imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        }

        $items
            .dropFirst()
            .debounce(for: .seconds(0.6), scheduler: RunLoop.main)
            .sink { [weak self] list in
                guard let self, let data = try? JSONEncoder().encode(list) else { return }
                try? data.write(to: self.fileURL, options: .atomic)
            }
            .store(in: &bag)

        startPolling()
    }

    deinit { stopPolling() }

    var sorted: [Item] {
        items.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.date > b.date
        }
    }

    // MARK: - Опрос буфера

    private func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopPolling() {
        ticker?.invalidate()
        ticker = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount

        // не сохраняем пароли из менеджеров паролей
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if let types = pb.types, types.contains(concealed) { return }

        if let raw = pb.string(forType: .string),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addText(raw)
            return
        }
        // скриншот / картинка — строки в буфере нет
        if let image = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            addImage(image)
        }
    }

    private func addText(_ raw: String) {
        guard raw.count <= 200_000 else { return }
        if let i = items.firstIndex(where: { $0.text == raw && !$0.isImage }) {
            items[i].date = Date()
        } else {
            items.insert(Item(text: raw), at: 0)
        }
        trim()
    }

    private func addImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }

        let name = UUID().uuidString + ".png"
        guard (try? png.write(to: imagesDir.appendingPathComponent(name), options: .atomic)) != nil
        else { return }

        let size = image.size
        let label = "Изображение \(Int(size.width))×\(Int(size.height))"
        items.insert(Item(text: label, imageFile: name), at: 0)
        trim()
    }

    // MARK: - Картинки

    func imageURL(for item: Item) -> URL? {
        item.imageFile.map { imagesDir.appendingPathComponent($0) }
    }

    func thumbnail(for item: Item) -> NSImage? {
        guard let name = item.imageFile else { return nil }
        if let cached = thumbCache[name] { return cached }
        guard let img = NSImage(contentsOf: imagesDir.appendingPathComponent(name)) else { return nil }
        thumbCache[name] = img
        return img
    }

    /// Удаляем PNG вместе с записью, иначе папка растёт вечно
    private func discardFiles(_ list: [Item]) {
        for item in list {
            guard let name = item.imageFile else { continue }
            thumbCache[name] = nil
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
        }
    }

    private func trim() {
        guard items.count > maxItems else { return }
        var kept = items.filter(\.isPinned)
        let rest = items.filter { !$0.isPinned }
            .sorted { $0.date > $1.date }
            .prefix(max(0, maxItems - kept.count))
        let dropped = Set(items.map(\.id)).subtracting(kept.map(\.id)).subtracting(rest.map(\.id))
        discardFiles(items.filter { dropped.contains($0.id) })
        kept.append(contentsOf: rest)
        items = kept
    }

    // MARK: - Действия

    func copy(_ item: Item) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let url = imageURL(for: item), let img = NSImage(contentsOf: url) {
            pb.writeObjects([img])
        } else {
            pb.setString(item.text, forType: .string)
        }
        lastChange = pb.changeCount          // чтобы не задублировалось
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].date = Date()
        }
    }

    func share(_ item: Item) {
        if let url = imageURL(for: item) {
            SharePresenter.shared.shareFiles([url])
        } else {
            SharePresenter.shared.share([item.text])
        }
    }

    func togglePin(_ id: Item.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isPinned.toggle()
    }

    func delete(_ id: Item.ID) {
        discardFiles(items.filter { $0.id == id })
        items.removeAll { $0.id == id }
    }

    func clearUnpinned() {
        discardFiles(items.filter { !$0.isPinned })
        items.removeAll { !$0.isPinned }
    }

    /// Перетаскивание элемента из истории в другое приложение
    func itemProvider(for item: Item) -> NSItemProvider {
        if let url = imageURL(for: item), let p = NSItemProvider(contentsOf: url) { return p }
        return NSItemProvider(object: item.text as NSString)
    }
}
