import SwiftUI

struct TaskDetailDueDateState {
    var isEnabled: Bool
    var selection: Date

    init(task: TaskItem, defaultDate: @autoclosure () -> Date = Date()) {
        if let dueDate = task.dueDate {
            isEnabled = true
            selection = dueDate
        } else {
            isEnabled = false
            selection = defaultDate()
        }
    }

    mutating func enable(defaultDate: @autoclosure () -> Date = Date()) {
        guard !isEnabled else { return }
        isEnabled = true
        selection = defaultDate()
    }

    mutating func clear() {
        isEnabled = false
    }

    func applying(to task: TaskItem) -> TaskItem {
        var updatedTask = task
        if isEnabled {
            updatedTask.dueDate = selection
        } else {
            updatedTask.clearDueDate()
        }
        return updatedTask
    }
}

struct TaskDetailView: View {
    @Bindable var appState: AppState
    @State var task: TaskItem
    var onDismiss: () -> Void
    @State private var subtaskTitle = ""
    @State private var dueDateState: TaskDetailDueDateState
    @FocusState private var isSubtaskFieldFocused: Bool

    init(appState: AppState, task: TaskItem, onDismiss: @escaping () -> Void) {
        self.appState = appState
        self.onDismiss = onDismiss
        _task = State(initialValue: task)
        _dueDateState = State(initialValue: TaskDetailDueDateState(task: task))
    }

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
                    let updatedTask = dueDateState.applying(to: task)
                    Task {
                        await appState.updateTask(updatedTask)
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

            HStack {
                Text("Due date")
                    .font(.callout)
                Spacer()
                if dueDateState.isEnabled {
                    DatePicker(
                        "",
                        selection: $dueDateState.selection,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .controlSize(.small)
                } else {
                    Button("Add due date") {
                        dueDateState.enable()
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            }

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
                if dueDateState.isEnabled {
                    Button("Clear due date") {
                        dueDateState.clear()
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
