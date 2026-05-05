import SwiftUI
import UniformTypeIdentifiers

enum TaskRowSection: String {
    case active
    case completed
}

enum TaskListLayout {
    static let activeEndDropZoneHeight: CGFloat = 4
    static let completedHeaderTopPadding: CGFloat = 2
}

enum TaskDropPlacement: Equatable {
    case before
    case after
}

struct TaskDropContext: Equatable {
    let draggedTaskID: String
    let targetTaskID: String?
    let placement: TaskDropPlacement
    let destinationSiblingIndex: Int
}

struct TaskDropIndicator: Equatable {
    let targetTaskID: String?
    let placement: TaskDropPlacement
}

func taskRowSection(for task: TaskItem) -> TaskRowSection {
    task.isCompleted ? .completed : .active
}

func taskRowIdentity(for taskID: String, in section: TaskRowSection) -> String {
    "\(section.rawValue)-\(taskID)"
}

func taskDropPlacement(locationY: CGFloat, rowHeight: CGFloat) -> TaskDropPlacement {
    rowHeight > 0 && locationY > rowHeight / 2 ? .after : .before
}

func taskDropContext(
    draggedTaskID: String?,
    targetTask: TaskItem,
    locationY: CGFloat,
    rowHeight: CGFloat,
    activeTasks: [TaskItem]
) -> TaskDropContext? {
    guard let draggedTaskID,
          let draggedTask = activeTasks.first(where: { $0.id == draggedTaskID && !$0.isCompleted }),
          !targetTask.isCompleted,
          draggedTask.id != targetTask.id,
          draggedTask.parent == targetTask.parent
    else {
        return nil
    }

    let activeSiblings = activeTasks.filter { !$0.isCompleted && $0.parent == draggedTask.parent }
    guard let sourceIndex = activeSiblings.firstIndex(where: { $0.id == draggedTaskID }),
          let targetIndex = activeSiblings.firstIndex(where: { $0.id == targetTask.id })
    else {
        return nil
    }

    let placement = taskDropPlacement(locationY: locationY, rowHeight: rowHeight)
    let destinationSiblingIndex = targetIndex + (placement == .after ? 1 : 0)

    return makeTaskDropContext(
        draggedTaskID: draggedTaskID,
        targetTaskID: targetTask.id,
        placement: placement,
        sourceIndex: sourceIndex,
        destinationSiblingIndex: destinationSiblingIndex,
        activeSiblingIDs: activeSiblings.map(\.id)
    )
}

func taskEndDropContext(draggedTaskID: String?, activeTasks: [TaskItem]) -> TaskDropContext? {
    guard let draggedTaskID,
          let draggedTask = activeTasks.first(where: { $0.id == draggedTaskID && !$0.isCompleted }),
          draggedTask.parent == nil
    else {
        return nil
    }

    let rootTasks = activeTasks.filter { !$0.isCompleted && $0.parent == nil }
    guard let sourceIndex = rootTasks.firstIndex(where: { $0.id == draggedTaskID }) else {
        return nil
    }

    return makeTaskDropContext(
        draggedTaskID: draggedTaskID,
        targetTaskID: nil,
        placement: .after,
        sourceIndex: sourceIndex,
        destinationSiblingIndex: rootTasks.count,
        activeSiblingIDs: rootTasks.map(\.id)
    )
}

private func makeTaskDropContext(
    draggedTaskID: String,
    targetTaskID: String?,
    placement: TaskDropPlacement,
    sourceIndex: Int,
    destinationSiblingIndex: Int,
    activeSiblingIDs: [String]
) -> TaskDropContext? {
    var reorderedIDs = activeSiblingIDs
    reorderedIDs.move(
        fromOffsets: IndexSet(integer: sourceIndex),
        toOffset: min(max(destinationSiblingIndex, 0), activeSiblingIDs.count)
    )

    guard reorderedIDs != activeSiblingIDs else { return nil }

    return TaskDropContext(
        draggedTaskID: draggedTaskID,
        targetTaskID: targetTaskID,
        placement: placement,
        destinationSiblingIndex: destinationSiblingIndex
    )
}

func shouldPlaceInlineSubtaskField(
    after task: TaskItem,
    parentID: String?,
    isSearching: Bool,
    section: TaskRowSection
) -> Bool {
    guard let parentID else { return false }
    guard !isSearching else { return false }
    guard section == .active else { return false }
    return task.id == parentID
}

func visibleSubtasks(
    _ subtasks: [TaskItem],
    under parent: TaskItem,
    isSearching: Bool,
    completedSubtasksRevealed: Bool
) -> [TaskItem] {
    guard !isSearching, !parent.isCompleted, !completedSubtasksRevealed else {
        return subtasks
    }

    return subtasks.filter { !$0.isCompleted }
}

func completedSubtasksRevealCount(
    _ subtasks: [TaskItem],
    under parent: TaskItem,
    isSearching: Bool
) -> Int {
    guard !isSearching, !parent.isCompleted else { return 0 }
    return subtasks.filter(\.isCompleted).count
}

func completedSubtasksRevealTitle(count: Int, isRevealed: Bool) -> String {
    if isRevealed {
        return "Hide completed subtasks"
    }

    let label = count == 1 ? "completed subtask" : "completed subtasks"
    return "Show \(count) \(label)"
}

struct TaskListView: View {
    @Bindable var appState: AppState
    @State private var selectedTask: TaskItem?
    @State private var showCompleted = false
    @State private var activeTaskRowHeights: [String: CGFloat] = [:]
    @State private var inlineSubtaskParentID: String?
    @State private var revealedCompletedSubtaskParentIDs: Set<String> = []
    @State private var draggedTaskID: String?
    @State private var dropIndicator: TaskDropIndicator?

    private struct FlattenedTaskEntry: Identifiable {
        let task: TaskItem
        let indentLevel: Int
        let isParentCompleted: Bool
        let section: TaskRowSection

        var id: String {
            taskRowIdentity(for: task.id, in: section)
        }
    }

    fileprivate struct CompletedSubtasksRevealEntry: Identifiable {
        let parentID: String
        let count: Int
        let indentLevel: Int
        let isRevealed: Bool
        let section: TaskRowSection

        var id: String {
            "\(section.rawValue)-completed-subtasks-\(parentID)"
        }
    }

    private enum TaskListEntry: Identifiable {
        case task(FlattenedTaskEntry)
        case completedSubtasksReveal(CompletedSubtasksRevealEntry)

        var id: String {
            switch self {
            case .task(let entry):
                entry.id
            case .completedSubtasksReveal(let entry):
                entry.id
            }
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
                        let flatIncomplete = flattenedListEntries(roots: incompleteRootTasks, section: .active)
                        ForEach(flatIncomplete) { entry in
                            switch entry {
                            case .task(let taskEntry):
                                taskRow(for: taskEntry)

                                if shouldShowInlineSubtaskField(after: taskEntry) {
                                    InlineSubtaskField(
                                        parentId: inlineSubtaskParentID!,
                                        indentLevel: 1,
                                        appState: appState,
                                        onDismiss: { inlineSubtaskParentID = nil }
                                    )
                                    .padding(.leading, 4)
                                    .padding(.trailing, 10)
                                }
                            case .completedSubtasksReveal(let revealEntry):
                                CompletedSubtasksRevealRow(entry: revealEntry) {
                                    toggleCompletedSubtasksReveal(for: revealEntry.parentID)
                                }
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
                                let flatCompleted = flattenedListEntries(roots: completedRootTasks, section: .completed)
                                ForEach(flatCompleted) { entry in
                                    switch entry {
                                    case .task(let taskEntry):
                                        taskRow(for: taskEntry)
                                    case .completedSubtasksReveal(let revealEntry):
                                        CompletedSubtasksRevealRow(entry: revealEntry) {
                                            toggleCompletedSubtasksReveal(for: revealEntry.parentID)
                                        }
                                        .padding(.leading, 4)
                                        .padding(.trailing, 10)
                                    }
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
    private func flattenedListEntries(roots: [TaskItem], section: TaskRowSection) -> [TaskListEntry] {
        var result: [TaskListEntry] = []

        func walk(_ task: TaskItem, level: Int, parentCompleted: Bool) {
            result.append(.task(
                FlattenedTaskEntry(
                    task: task,
                    indentLevel: level,
                    isParentCompleted: parentCompleted,
                    section: section
                )
            ))
            let isCollapsed = appState.collapsedTaskIDs.contains(task.id)
            if !isCollapsed {
                let allChildren = appState.isSearching
                    ? appState.searchFilteredSubtasks(of: task.id)
                    : appState.subtasks(of: task.id)
                let isRevealed = revealedCompletedSubtaskParentIDs.contains(task.id)
                let visibleChildren = visibleSubtasks(
                    allChildren,
                    under: task,
                    isSearching: appState.isSearching,
                    completedSubtasksRevealed: isRevealed
                )

                for child in visibleChildren {
                    walk(child, level: level + 1, parentCompleted: parentCompleted || task.isCompleted)
                }

                let hiddenCompletedCount = completedSubtasksRevealCount(
                    allChildren,
                    under: task,
                    isSearching: appState.isSearching
                )
                if hiddenCompletedCount > 0 {
                    result.append(.completedSubtasksReveal(
                        CompletedSubtasksRevealEntry(
                            parentID: task.id,
                            count: hiddenCompletedCount,
                            indentLevel: level + 1,
                            isRevealed: isRevealed,
                            section: section
                        )
                    ))
                }
            }
        }

        for root in roots {
            walk(root, level: 0, parentCompleted: false)
        }
        return result
    }

    private func toggleCompletedSubtasksReveal(for parentID: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if revealedCompletedSubtaskParentIDs.contains(parentID) {
                revealedCompletedSubtaskParentIDs.remove(parentID)
            } else {
                revealedCompletedSubtaskParentIDs.insert(parentID)
            }
        }
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
            if task.isCompleted {
                activeTaskRow(for: entry, hasChildren: hasChildren)
            } else {
                activeTaskRow(for: entry, hasChildren: hasChildren)
                    .onDrag {
                        draggedTaskID = task.id
                        return NSItemProvider(object: task.id as NSString)
                    }
                    .overlay(alignment: .top) {
                        dropInsertionLine(targetTaskID: task.id, placement: .before)
                    }
                    .overlay(alignment: .bottom) {
                        dropInsertionLine(targetTaskID: task.id, placement: .after)
                    }
                    .onDrop(
                        of: [UTType.plainText.identifier],
                        delegate: TaskRowDropDelegate(
                            draggedTaskID: draggedTaskID,
                            targetTask: task,
                            activeTasks: appState.tasks.filter { !$0.isCompleted },
                            rowHeight: activeTaskRowHeights[task.id] ?? 0,
                            updateIndicator: { dropIndicator = $0 },
                            performMove: { context in
                                _ = moveTask(withID: context.draggedTaskID, toSiblingIndex: context.destinationSiblingIndex)
                                clearDropState()
                            }
                        )
                    )
            }
        } else {
            taskRowBase(for: entry, hasChildren: hasChildren)
                .id(entry.id)
                .transition(.opacity)
        }
    }

    private func activeTaskRow(for entry: FlattenedTaskEntry, hasChildren: Bool) -> some View {
        let task = entry.task

        return taskRowBase(for: entry, hasChildren: hasChildren)
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
    }

    private var activeTaskEndDropZone: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(height: TaskListLayout.activeEndDropZoneHeight)

            dropInsertionLine(targetTaskID: nil, placement: .after)
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.plainText.identifier],
            delegate: TaskEndDropDelegate(
                draggedTaskID: draggedTaskID,
                activeTasks: appState.tasks.filter { !$0.isCompleted },
                updateIndicator: { dropIndicator = $0 },
                performMove: { context in
                    _ = moveTask(withID: context.draggedTaskID, toSiblingIndex: context.destinationSiblingIndex)
                    clearDropState()
                }
            )
        )
    }

    @ViewBuilder
    private func dropInsertionLine(targetTaskID: String?, placement: TaskDropPlacement) -> some View {
        if dropIndicator == TaskDropIndicator(targetTaskID: targetTaskID, placement: placement) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 14)
        }
    }

    private func clearDropState() {
        draggedTaskID = nil
        dropIndicator = nil
    }

    private func moveTask(withID taskID: String, toSiblingIndex destinationIndex: Int) -> Bool {
        guard let task = appState.tasks.first(where: { $0.id == taskID && !$0.isCompleted }) else { return false }

        Task { @MainActor in
            await appState.moveTask(task, toSiblingIndex: destinationIndex)
        }
        return true
    }

    private func shouldShowInlineSubtaskField(after entry: FlattenedTaskEntry) -> Bool {
        shouldPlaceInlineSubtaskField(
            after: entry.task,
            parentID: inlineSubtaskParentID,
            isSearching: appState.isSearching,
            section: entry.section
        )
    }

}

private struct TaskRowDropDelegate: DropDelegate {
    let draggedTaskID: String?
    let targetTask: TaskItem
    let activeTasks: [TaskItem]
    let rowHeight: CGFloat
    let updateIndicator: (TaskDropIndicator?) -> Void
    let performMove: (TaskDropContext) -> Void

    func dropEntered(info: DropInfo) {
        updateIndicator(context(for: info).map {
            TaskDropIndicator(targetTaskID: $0.targetTaskID, placement: $0.placement)
        })
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let context = context(for: info) else {
            updateIndicator(nil)
            return DropProposal(operation: .forbidden)
        }

        updateIndicator(TaskDropIndicator(targetTaskID: context.targetTaskID, placement: context.placement))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        updateIndicator(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let context = context(for: info) else {
            updateIndicator(nil)
            return false
        }

        performMove(context)
        return true
    }

    private func context(for info: DropInfo) -> TaskDropContext? {
        taskDropContext(
            draggedTaskID: draggedTaskID,
            targetTask: targetTask,
            locationY: info.location.y,
            rowHeight: rowHeight,
            activeTasks: activeTasks
        )
    }
}

private struct TaskEndDropDelegate: DropDelegate {
    let draggedTaskID: String?
    let activeTasks: [TaskItem]
    let updateIndicator: (TaskDropIndicator?) -> Void
    let performMove: (TaskDropContext) -> Void

    func dropEntered(info: DropInfo) {
        updateIndicator(context().map {
            TaskDropIndicator(targetTaskID: $0.targetTaskID, placement: $0.placement)
        })
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let context = context() else {
            updateIndicator(nil)
            return DropProposal(operation: .forbidden)
        }

        updateIndicator(TaskDropIndicator(targetTaskID: context.targetTaskID, placement: context.placement))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        updateIndicator(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let context = context() else {
            updateIndicator(nil)
            return false
        }

        performMove(context)
        return true
    }

    private func context() -> TaskDropContext? {
        taskEndDropContext(draggedTaskID: draggedTaskID, activeTasks: activeTasks)
    }
}

private struct CompletedSubtasksRevealRow: View {
    let entry: TaskListView.CompletedSubtasksRevealEntry
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Spacer()
                    .frame(width: 10)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(entry.isRevealed ? -90 : 0))

                Text(completedSubtasksRevealTitle(count: entry.count, isRevealed: entry.isRevealed))
                    .font(.caption)

                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.leading, 2)
            .padding(.trailing, 4)
            .padding(.leading, CGFloat(entry.indentLevel) * 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("completed.subtasks.toggle.\(entry.parentID)")
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
