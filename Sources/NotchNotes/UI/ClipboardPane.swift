import SwiftUI
import AppKit

struct ClipboardPane: View {
    @ObservedObject var store: ClipboardStore
    @State private var query = ""
    @State private var justCopied: ClipboardStore.Item.ID?

    private var list: [ClipboardStore.Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.isEmpty ? store.sorted : store.sorted.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            SearchField(placeholder: "Поиск по буферу", text: $query) {
                // подпись у переключателя: без неё непонятно, что именно он делает
                HStack(spacing: Theme.Space.s) {
                    Text(store.isEnabled ? "Запись" : "Пауза")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(store.isEnabled ? Theme.Ink.secondary : Theme.Ink.tertiary)
                    Toggle("", isOn: $store.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help("Записывать копируемое в историю")

                    IconButton(icon: "trash", hint: "Очистить (кроме закреплённых)") {
                        store.clearUnpinned()
                    }
                }
            }

            if list.isEmpty {
                EmptyState(icon: store.isEnabled ? "doc.on.clipboard" : "pause.circle",
                           title: emptyTitle,
                           subtitle: emptySubtitle,
                           actionTitle: store.isEnabled ? nil : "Включить запись",
                           action: store.isEnabled ? nil : { store.isEnabled = true })
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(list) { item in card(item) }
                    }
                    .padding(.bottom, Theme.Space.xs)
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(Theme.Ink.primary)
    }

    private var emptyTitle: String {
        if !store.isEnabled { return "Запись выключена" }
        return query.isEmpty ? "История пуста" : "Ничего не найдено"
    }

    private var emptySubtitle: String? {
        guard store.isEnabled, query.isEmpty else { return nil }
        return "Скопируйте что-нибудь — оно появится здесь"
    }

    private func card(_ item: ClipboardStore.Item) -> some View {
        HStack(spacing: Theme.Space.m) {
            if let thumb = store.thumbnail(for: item) {
                Image(nsImage: thumb)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: item.icon)
                    .font(Theme.Icon.small)
                    .foregroundStyle(item.isLink ? .cyan
                                     : item.isCode ? Theme.Accent.success : Theme.Ink.tertiary)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.oneLine)
                    .font(.system(size: 12, design: item.isCode ? .monospaced : .default))
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                HStack(spacing: Theme.Space.xs) {
                    Text(item.date, style: .relative)
                    if !item.isImage { Text("·"); Text(item.stats) }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.Ink.tertiary)
            }

            Spacer(minLength: 0)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10)).foregroundStyle(Theme.Accent.pin)
            }
            if justCopied == item.id {
                Label("Скопировано", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Accent.success)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
        .cardHighlight()
        .contentShape(Rectangle())
        .help("Нажмите, чтобы скопировать")
        .onTapGesture { copy(item) }
        .onDrag { store.itemProvider(for: item) }
        .contextMenu {
            Button("Скопировать") { copy(item) }
            Button("Поделиться…") { store.share(item) }
            if item.isLink {
                Button("Открыть в браузере") {
                    if let u = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
            if let url = store.imageURL(for: item) {
                Button("Открыть картинку") { NSWorkspace.shared.open(url) }
            }
            Button(item.isPinned ? "Открепить" : "Закрепить") { store.togglePin(item.id) }
            Divider()
            Button("Удалить", role: .destructive) { store.delete(item.id) }
        }
    }

    private func copy(_ item: ClipboardStore.Item) {
        store.copy(item)
        withAnimation(.spring(response: 0.25)) { justCopied = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation { if justCopied == item.id { justCopied = nil } }
        }
    }
}
