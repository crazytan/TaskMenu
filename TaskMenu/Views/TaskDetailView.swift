import SwiftUI

struct TaskDetailView: View {
    @Bindable var appState: AppState
    @State var task: TaskItem
    var onDismiss: () -> Void
    @State private var subtaskTitle = ""
    @FocusState private var isSubtaskFieldFocused: Bool

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
                .accessibilityIdentifier("detail.back.button")

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
                .accessibilityIdentifier("detail.done.button")
            }

            TextField("Title", text: $task.title)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .accessibilityIdentifier("detail.title.field")

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

            // Subtasks section
            if task.parent == nil {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Subtasks")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let children = appState.subtasks(of: task.id)
                    ForEach(children) { child in
                        HStack(spacing: 6) {
                            Image(systemName: child.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(child.isCompleted ? .green : .secondary)
                                .font(.system(size: 14, weight: .light))
                            Text(child.title)
                                .font(.callout)
                                .strikethrough(child.isCompleted)
                                .foregroundStyle(child.isCompleted ? .secondary : .primary)
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.blue)
                            .font(.system(size: 14))
                        TextField("Add subtask...", text: $subtaskTitle)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .focused($isSubtaskFieldFocused)
                            .onSubmit {
                                addSubtask()
                            }
                    }
                }
            }

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

    private func addSubtask() {
        let title = subtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        subtaskTitle = ""
        Task { await appState.addSubtask(title: title, parentId: task.id) }
    }
}
