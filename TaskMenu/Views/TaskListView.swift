import SwiftUI

enum TaskRowSection: String {
    case active
    case completed
}

enum TaskListLayout {
    static let activeEndDropZoneHeight: CGFloat = 4
    static let completedHeaderTopPadding: CGFloat = 2
}

func taskRowSection(for task: TaskItem) -> TaskRowSection {
    task.isCompleted ? .completed : .active
}

func taskRowIdentity(for taskID: String, in section: TaskRowSection) -> String {
    "\(section.rawValue)-\(taskID)"
}

struct TaskListView: View {
    @Bindable var appState: AppState
    @State private var selectedTask: TaskItem?
    @State private var showCompleted = false
    @State private var activeTaskRowHeights: [String: CGFloat] = [:]
    @State private var inlineSubtaskParentID: String?

    private struct FlattenedTaskEntry: Identifiable {
        let task: TaskItem
        let indentLevel: Int
        let isParentCompleted: Bool
        let section: TaskRowSection

        var id: String {
            taskRowIdentity(for: task.id, in: section)
        }
    }

    private var displayRootTasks: [TaskItem] {
        appState.isSearching ? appState.searchFilteredRootTasks : appState.rootTasks
    }

    var incompleteRootTasks: [TaskItem] {
        displayRootTasks.filter { !$0.isCompleted }
    }

    var completedRootTasks: [TaskItem] {
        displayRootTasks.filter { $0.isCompleted }
    }

    private var searchResultCount: Int {
        appState.searchFilteredTasks.count
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
                if appState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await appState.refreshTasks() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Quick add
            QuickAddView(appState: appState)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter tasks…", text: $appState.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .accessibilityIdentifier("search.field")
                if !appState.searchText.isEmpty {
                    Button {
                        appState.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.04))
            )
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
            } else if appState.isSearching && searchResultCount == 0 {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("No results")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding()
                Spacer()
            } else {
                if appState.isSearching {
                    Text("\(searchResultCount) result\(searchResultCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        let flatIncomplete = flattenedTasks(roots: incompleteRootTasks, section: .active)
                        ForEach(flatIncomplete) { entry in
                            taskRow(for: entry)

                            if shouldShowInlineSubtaskField(after: entry, in: flatIncomplete) {
                                InlineSubtaskField(
                                    parentId: inlineSubtaskParentID!,
                                    indentLevel: 1,
                                    appState: appState,
                                    onDismiss: { inlineSubtaskParentID = nil }
                                )
                                .padding(.leading, 4)
                                .padding(.trailing, 10)
                            }
                        }

                        if incompleteRootTasks.count > 1 {
                            activeTaskEndDropZone
                        }

                        if !completedRootTasks.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showCompleted.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .rotationEffect(.degrees(showCompleted ? 90 : 0))
                                    Text("Completed (\(completedRootTasks.count))")
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, TaskListLayout.completedHeaderTopPadding)
                            .accessibilityIdentifier("completed.toggle")

                            if showCompleted || appState.isSearching {
                                let flatCompleted = flattenedTasks(roots: completedRootTasks, section: .completed)
                                ForEach(flatCompleted) { entry in
                                    taskRow(for: entry)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(
                        .easeInOut(duration: 0.25),
                        value: appState.tasks.map { taskRowIdentity(for: $0.id, in: taskRowSection(for: $0)) }
                    )
                }
            }
        }
    }

    /// Flattens the task tree into a list of (task, indentLevel, isParentCompleted) for rendering.
    private func flattenedTasks(roots: [TaskItem], section: TaskRowSection) -> [FlattenedTaskEntry] {
        var result: [FlattenedTaskEntry] = []

        func walk(_ task: TaskItem, level: Int, parentCompleted: Bool) {
            result.append(
                FlattenedTaskEntry(
                    task: task,
                    indentLevel: level,
                    isParentCompleted: parentCompleted,
                    section: section
                )
            )
            let isCollapsed = appState.collapsedTaskIDs.contains(task.id)
            if !isCollapsed {
                let children = appState.isSearching
                    ? appState.searchFilteredSubtasks(of: task.id)
                    : appState.subtasks(of: task.id)
                for child in children {
                    walk(child, level: level + 1, parentCompleted: parentCompleted || task.isCompleted)
                }
            }
        }

        for root in roots {
            walk(root, level: 0, parentCompleted: false)
        }
        return result
    }

    private func triggerInlineSubtask(for task: TaskItem) {
        if appState.collapsedTaskIDs.contains(task.id) {
            withAnimation(.easeInOut(duration: 0.2)) {
                appState.toggleCollapsed(task.id)
            }
        }
        inlineSubtaskParentID = task.id
    }

    private func taskRowBase(for entry: FlattenedTaskEntry, hasChildren: Bool) -> some View {
        let task = entry.task

        return TaskRowView(
            task: task,
            indentLevel: entry.indentLevel,
            isParentCompleted: entry.isParentCompleted,
            hasChildren: hasChildren,
            isCollapsed: appState.collapsedTaskIDs.contains(task.id),
            onToggle: { Task { await appState.toggleTask(task) } },
            onDelete: { Task { await appState.deleteTask(task) } },
            onCollapseToggle: hasChildren ? { withAnimation(.easeInOut(duration: 0.2)) { appState.toggleCollapsed(task.id) } } : nil,
            onAddSubtask: task.parent == nil && !task.isCompleted ? { triggerInlineSubtask(for: task) } : nil
        )
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTask = task
            }
        }
        .contextMenu {
            if task.parent == nil && !task.isCompleted {
                Button {
                    triggerInlineSubtask(for: task)
                } label: {
                    Label("Add Subtask", systemImage: "text.badge.plus")
                }
            }

            if appState.canIndentTask(task) {
                Button {
                    Task { await appState.indentTask(task) }
                } label: {
                    Label("Make Subtask", systemImage: "arrow.right")
                }
            }

            if appState.canOutdentTask(task) {
                Button {
                    Task { await appState.outdentTask(task) }
                } label: {
                    Label("Move to Top Level", systemImage: "arrow.left")
                }
            }

            Divider()

            Button(role: .destructive) {
                Task { await appState.deleteTask(task) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func taskRow(for entry: FlattenedTaskEntry) -> some View {
        let task = entry.task
        let hasChildren = appState.hasSubtasks(task.id)

        if entry.section == .active {
            taskRowBase(for: entry, hasChildren: hasChildren)
                .id(entry.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    activeTaskRowHeights[task.id] = height
                }
                .draggable(task.id)
                .dropDestination(for: String.self) { items, location in
                    handleDrop(of: items, onto: task, location: location)
                }
        } else {
            taskRowBase(for: entry, hasChildren: hasChildren)
                .id(entry.id)
                .transition(.opacity)
        }
    }

    private var activeTaskEndDropZone: some View {
        Color.clear
            .frame(height: TaskListLayout.activeEndDropZoneHeight)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                handleDropToEnd(of: items)
            }
    }

    private func handleDrop(of taskIDs: [String], onto targetTask: TaskItem, location: CGPoint) -> Bool {
        guard let draggedTaskID = taskIDs.first else { return false }
        let incompleteTasks = appState.tasks.filter { !$0.isCompleted }
        guard let targetIndex = incompleteTasks.firstIndex(where: { $0.id == targetTask.id }) else {
            return false
        }

        let rowHeight = activeTaskRowHeights[targetTask.id] ?? 0
        let destinationIndex = rowHeight > 0 && location.y > rowHeight / 2 ? targetIndex + 1 : targetIndex
        return moveTask(withID: draggedTaskID, toActiveIndex: destinationIndex)
    }

    private func handleDropToEnd(of taskIDs: [String]) -> Bool {
        guard let draggedTaskID = taskIDs.first else { return false }
        let incompleteTasks = appState.tasks.filter { !$0.isCompleted }
        return moveTask(withID: draggedTaskID, toActiveIndex: incompleteTasks.count)
    }

    private func moveTask(withID taskID: String, toActiveIndex destinationIndex: Int) -> Bool {
        let incompleteTasks = appState.tasks.filter { !$0.isCompleted }
        guard let task = incompleteTasks.first(where: { $0.id == taskID }) else { return false }

        Task { @MainActor in
            await appState.moveTask(task, toActiveIndex: destinationIndex)
        }
        return true
    }

    private func shouldShowInlineSubtaskField(after entry: FlattenedTaskEntry, in entries: [FlattenedTaskEntry]) -> Bool {
        guard let parentID = inlineSubtaskParentID else { return false }
        guard !appState.isSearching else { return false }
        guard entry.section == .active else { return false }

        if entry.task.id == parentID {
            if !appState.hasSubtasks(parentID) || appState.collapsedTaskIDs.contains(parentID) {
                return true
            }
        }

        if entry.task.parent == parentID {
            guard let entryIndex = entries.firstIndex(where: { $0.task.id == entry.task.id }) else { return false }
            let nextIndex = entryIndex + 1
            if nextIndex >= entries.count || entries[nextIndex].task.parent != parentID {
                return true
            }
        }

        return false
    }

}

private struct InlineSubtaskField: View {
    let parentId: String
    let indentLevel: Int
    let appState: AppState
    let onDismiss: () -> Void

    @State private var title = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
                .frame(width: 10)

            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))

            TextField("Add subtask…", text: $title)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isFocused)
                .accessibilityIdentifier("inline.subtask.field")
                .onSubmit {
                    let trimmed = title.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    let taskTitle = trimmed
                    title = ""
                    Task { await appState.addSubtask(title: taskTitle, parentId: parentId) }
                }
                .onExitCommand {
                    onDismiss()
                }

            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .padding(.leading, CGFloat(indentLevel) * 20)
        .onAppear {
            isFocused = true
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                onDismiss()
            }
        }
    }
}
