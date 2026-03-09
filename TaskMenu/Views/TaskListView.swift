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
                        .font(.system(size: 13, weight: .medium))
                        .rotationEffect(.degrees(appState.isLoading ? 360 : 0))
                        .animation(
                            appState.isLoading
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .default,
                            value: appState.isLoading
                        )
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(appState.isLoading)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Quick add
            QuickAddView(appState: appState)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            Divider()

            // Task list
            if appState.isLoading && appState.tasks.isEmpty {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
                Spacer()
            } else if appState.tasks.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "checklist.unchecked")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("No tasks yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Add one above to get started")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
                            .padding(.horizontal, 10)
                            .onTapGesture { selectedTask = task }
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                        }

                        if !completedTasks.isEmpty {
                            DisclosureGroup("Completed (\(completedTasks.count))") {
                                ForEach(completedTasks) { task in
                                    TaskRowView(
                                        task: task,
                                        onToggle: { Task { await appState.toggleTask(task) } },
                                        onDelete: { Task { await appState.deleteTask(task) } }
                                    )
                                    .transition(.opacity)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.easeInOut(duration: 0.25), value: appState.tasks.map(\.id))
                }
            }
        }
        .sheet(item: $selectedTask) { task in
            TaskDetailView(appState: appState, task: task)
        }
    }
}
