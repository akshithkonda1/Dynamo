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

    func collapsedView() -> AnyView {
        AnyView(CollapsedChecklistView(store: store))
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

private struct CollapsedChecklistView: View {
    @ObservedObject var store: ChecklistStore

    var body: some View {
        let remaining = store.items.filter { !$0.isDone }.count
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(NotchTheme.caption.weight(.semibold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text(remaining == 0 ? "All done" : "\(remaining) left")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textPrimary)
        }
    }
}

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
                        .foregroundStyle(.white.opacity(0.85))
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
                    .foregroundStyle(item.isDone ? Color.green.opacity(0.85) : Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)

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
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
