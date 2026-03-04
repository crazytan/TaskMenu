import SwiftUI

struct TaskListView: View {
    @Bindable var appState: AppState
    @State private var selectedTask: TaskItem?

    var incompleteTasks: [TaskItem] {
        appState.tasks.filter { !$0.isCompleted }
    }

    var completedTasks: [TaskItem] {
        appState.tasks.filter { $0.isCompleted }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                ListPickerView(appState: appState)
                Spacer()
                Button {
                    Task { await appState.loadTasks() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(appState.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Quick add
            QuickAddView(appState: appState)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // Task list
            if appState.isLoading && appState.tasks.isEmpty {
                Spacer()
                ProgressView()
                    .padding()
                Spacer()
            } else if appState.tasks.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No tasks yet")
                        .foregroundStyle(.secondary)
                }
                .padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(incompleteTasks) { task in
                            TaskRowView(
                                task: task,
                                onToggle: { Task { await appState.toggleTask(task) } },
                                onDelete: { Task { await appState.deleteTask(task) } }
                            )
                            .padding(.horizontal, 16)
                            .onTapGesture { selectedTask = task }
                        }

                        if !completedTasks.isEmpty {
                            DisclosureGroup("Completed (\(completedTasks.count))") {
                                ForEach(completedTasks) { task in
                                    TaskRowView(
                                        task: task,
                                        onToggle: { Task { await appState.toggleTask(task) } },
                                        onDelete: { Task { await appState.deleteTask(task) } }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .sheet(item: $selectedTask) { task in
            TaskDetailView(appState: appState, task: task)
        }
    }
}
