import SwiftUI

struct TaskDetailView: View {
    @Bindable var appState: AppState
    @State var task: TaskItem
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)

                Text("Edit Task")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    Task {
                        await appState.updateTask(task)
                        onDismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            TextField("Title", text: $task.title)
                .textFieldStyle(.roundedBorder)
                .font(.body)

            TextField("Notes", text: Binding(
                get: { task.notes ?? "" },
                set: { task.notes = $0.isEmpty ? nil : $0 }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .lineLimit(3...6)

            DatePicker(
                "Due date",
                selection: Binding(
                    get: { task.dueDate ?? Date() },
                    set: { task.dueDate = $0 }
                ),
                displayedComponents: .date
            )
            .datePickerStyle(.stepperField)
            .controlSize(.small)

            Divider()

            HStack {
                if task.dueDate != nil {
                    Button("Clear due date") {
                        task.due = nil
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                }
                Spacer()
                Button(role: .destructive) {
                    Task {
                        await appState.deleteTask(task)
                        onDismiss()
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
