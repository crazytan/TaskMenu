import SwiftUI

struct TaskListView: View {
    @Bindable var appState: AppState
    @State private var selectedTask: TaskItem?
    @State private var showCompleted = false
    @State private var refreshRotation: Double = 0

    var incompleteTasks: [TaskItem] {
        appState.tasks.filter { !$0.isCompleted }
    }

    var completedTasks: [TaskItem] {
        appState.tasks.filter { $0.isCompleted }
    }

    var body: some View {
        if let task = selectedTask {
            TaskDetailView(appState: appState, task: task, onDismiss: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedTask = nil
                }
            })
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            taskListContent
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private var taskListContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                ListPickerView(appState: appState)
                Spacer()
                Button {
                    Task { await appState.refreshTasks() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .rotationEffect(.degrees(refreshRotation))
                        .onChange(of: appState.isLoading) { _, isLoading in
                            if isLoading {
                                startSpinning()
                            }
                        }
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
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedTask = task
                                }
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                        }

                        if !completedTasks.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showCompleted.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .rotationEffect(.degrees(showCompleted ? 90 : 0))
                                    Text("Completed (\(completedTasks.count))")
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)

                            if showCompleted {
                                ForEach(completedTasks) { task in
                                    TaskRowView(
                                        task: task,
                                        onToggle: { Task { await appState.toggleTask(task) } },
                                        onDelete: { Task { await appState.deleteTask(task) } }
                                    )
                                    .padding(.horizontal, 10)
                                    .transition(.opacity)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.easeInOut(duration: 0.25), value: appState.tasks.map(\.id))
                }
            }
        }
    }

    private func startSpinning() {
        // Continuously add 360° rotations while loading
        func spin() {
            guard appState.isLoading else { return }
            withAnimation(.linear(duration: 1)) {
                refreshRotation += 360
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                spin()
            }
        }
        spin()
    }
}
