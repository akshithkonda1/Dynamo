import SwiftUI

@MainActor
final class ChecklistPlugin: ObservableObject, NotchWidgetPlugin {
    let id = "checklist"
    let displayName = "Checklist"
    let systemImage = "checklist"

    let store = ChecklistStore()
    @Published var draft: String = ""

    var expandedContentHeight: CGFloat { 250 }

    func start() {
        store.start()
    }

    func stop() {
        store.stop()
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedChecklistView(plugin: self))
    }

    func submitDraft() {
        store.add(text: draft)
        draft = ""
    }
}

// MARK: - Views

private struct ExpandedChecklistView: View {
    @ObservedObject var plugin: ChecklistPlugin
    @ObservedObject private var store: ChecklistStore

    init(plugin: ChecklistPlugin) {
        self.plugin = plugin
        self._store = ObservedObject(wrappedValue: plugin.store)
    }

    private var doneCount: Int { store.items.filter(\.isDone).count }
    private var totalCount: Int { store.items.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchSectionHeader(
                "Checklist",
                trailing: totalCount > 0
                    ? AnyView(
                        Text("\(doneCount)/\(totalCount)")
                            .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                            .foregroundStyle(NotchTheme.textTertiary)
                    )
                    : nil
            )

            if store.items.isEmpty {
                Text("No tasks yet — add one below. Drag the handle to reorder.")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .padding(.vertical, 4)
            } else {
                // List + onMove enables drag reorder on macOS without an edit mode.
                List {
                    ForEach(store.items) { item in
                        row(item)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    }
                    .onMove { indices, newOffset in
                        store.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 140)
            }

            HStack(spacing: 8) {
                TextField("New item", text: Binding(
                    get: { plugin.draft },
                    set: { plugin.draft = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { plugin.submitDraft() }

                Button {
                    plugin.submitDraft()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(NotchTheme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(plugin.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ item: ChecklistItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.textQuaternary)

            Button {
                store.toggle(id: item.id)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isDone ? NotchTheme.positive : NotchTheme.textSecondary)
            }
            .buttonStyle(.notchIcon(diameter: 22))

            Text(item.text)
                .font(NotchTheme.body)
                .foregroundStyle(item.isDone ? NotchTheme.textQuaternary : NotchTheme.textPrimary)
                .strikethrough(item.isDone)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.remove(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
        }
        .notchRowBackground()
    }
}
