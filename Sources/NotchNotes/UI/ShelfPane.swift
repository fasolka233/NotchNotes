import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ShelfPane: View {
    @ObservedObject var store: ShelfStore
    @Binding var isTargeted: Bool

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Text("Полка")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Ink.primary)
                if !store.items.isEmpty {
                    Text("\(store.items.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.Surface.field, in: Capsule())
                        .foregroundStyle(Theme.Ink.secondary)
                }

                Spacer()

                IconButton(icon: "plus", hint: "Добавить файлы…") { store.addFromOpenPanel() }

                if !store.items.isEmpty {
                    IconButton(icon: "square.and.arrow.up",
                               hint: "Поделиться всем") { store.shareAll() }
                    IconButton(icon: "doc.on.doc",
                               hint: "Скопировать все файлы") { store.copyAll() }
                    IconButton(icon: "arrow.clockwise",
                               hint: "Убрать пропавшие файлы") { store.pruneMissing() }
                    IconButton(icon: "trash", tint: Theme.Accent.danger.opacity(0.85),
                               hint: "Очистить полку") { store.clear() }
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(
                        isTargeted ? Theme.Accent.tint : Theme.Stroke.outline,
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1,
                                           dash: store.items.isEmpty ? [6, 4] : [])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.panel)
                            .fill(isTargeted ? Theme.Surface.hover : Theme.Surface.base)
                    )

                if store.items.isEmpty {
                    EmptyState(icon: "tray.and.arrow.down",
                               title: isTargeted ? "Отпустите файлы" : "Перетащите файлы сюда",
                               subtitle: isTargeted ? nil
                                    : "Или поднесите их к челке — она раскроется сама",
                               actionTitle: isTargeted ? nil : "Выбрать файлы…",
                               action: isTargeted ? nil : { store.addFromOpenPanel() })
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: Theme.Space.m) {
                            ForEach(store.items) { tile($0) }
                        }
                        .padding(Theme.Space.m)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .animation(Theme.quick, value: isTargeted)
        }
        .foregroundStyle(Theme.Ink.primary)
        .onAppear { store.pruneMissing() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func tile(_ item: ShelfStore.Item) -> some View {
        VStack(spacing: Theme.Space.s) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: store.icon(for: item))
                    .resizable()
                    .frame(width: 42, height: 42)
                    .opacity(item.exists ? 1 : 0.3)

                // пропавший файл раньше отличался только прозрачностью — легко не заметить
                if !item.exists {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Accent.warning)
                        .background(Circle().fill(.black))
                }
            }

            Text(item.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(item.exists ? Theme.Ink.secondary : Theme.Ink.tertiary)
                .frame(height: 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .cardHighlight(radius: Theme.Radius.row)
        .contentShape(Rectangle())
        .onDrag { store.itemProvider(for: item) }
        .onTapGesture(count: 2) { store.open(item) }
        .help(item.exists
              ? "\(item.name)\n\(item.sizeString)\nДвойной клик — открыть, перетащите — вынести"
              : "\(item.name)\nФайл не найден на диске")
        .contextMenu {
            Button("Открыть") { store.open(item) }
            Button("Показать в Finder") { store.reveal(item) }
            Divider()
            Button("Поделиться…") { store.share([item]) }
            Button("Скопировать файл") { store.copy([item]) }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            Divider()
            Button("Убрать с полки", role: .destructive) { store.remove(item.id) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let type = UTType.fileURL.identifier
        var found = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
            found = true
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { store.add(urls: [url]) }
            }
        }
        return found
    }
}
