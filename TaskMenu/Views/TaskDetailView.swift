import SwiftUI

struct TaskDetailView: View {
    @Bindable var appState: AppState
    @State var task: TaskItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit Task")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    Task {
                        await appState.updateTask(task)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            TextField("Title", text: $task.title)
                .textFieldStyle(.roundedBorder)

            TextField("Notes", text: Binding(
                get: { task.notes ?? "" },
                set: { task.notes = $0.isEmpty ? nil : $0 }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(3...6)

            DatePicker(
                "Due date",
                selection: Binding(
                    get: { task.dueDate ?? Date() },
                    set: { task.dueDate = $0 }
                ),
                displayedComponents: .date
            )

            HStack {
                if task.dueDate != nil {
                    Button("Clear due date") {
                        task.due = nil
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    Task {
                        await appState.deleteTask(task)
                        dismiss()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
