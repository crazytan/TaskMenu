import SwiftUI

struct QuickAddView: View {
    @Bindable var appState: AppState
    @State private var newTaskTitle = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 16))

            TextField("Add a task...", text: $newTaskTitle)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onSubmit {
                    addTask()
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newTaskTitle = ""
        Task { await appState.addTask(title: title) }
    }
}
