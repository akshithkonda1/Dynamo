import SwiftUI

@MainActor
final class ChecklistPlugin: ObservableObject, NotchWidgetPlugin {
    let id = "checklist"
    let displayName = "Checklist"
    let systemImage = "checklist"

    let store = ChecklistStore()
    @Published var draft: String = ""

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checklist")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)

            if plugin.store.items.isEmpty {
                Text("Add a task below. Drag the handle to reorder.")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textTertiary)
            } else {
                // List + onMove enables drag reorder on macOS without an edit mode.
                List {
                    ForEach(plugin.store.items) { item in
                        row(item)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    }
                    .onMove { indices, newOffset in
                        plugin.store.move(fromOffsets: indices, toOffset: newOffset)
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
                plugin.store.toggle(id: item.id)
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
                plugin.store.remove(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
        }
        .padding(.vertical, 2)
    }
}
