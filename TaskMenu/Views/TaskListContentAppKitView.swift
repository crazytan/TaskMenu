import AppKit

@MainActor
private enum TaskListRowLayout {
    static let leadingInset: CGFloat = 4
    static let disclosureSlotSize: CGFloat = 18
    static let disclosureSpacing: CGFloat = 4
    static let completedSubtasksDisclosureLeadingOffset: CGFloat = 6
    static let completedGroupRowHeight: CGFloat = 32
    static let completedSubtasksGroupRowHeight: CGFloat = 26
}

@MainActor
final class TaskListContentView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenTask: ((TaskItem) -> Void)?
    var onToggleTask: ((TaskItem) -> Void)?
    var onDeleteTask: ((TaskItem) -> Void)?
    var onToggleCollapsed: ((String) -> Void)?
    var onToggleCompletedSection: (() -> Void)?
    var onToggleCompletedSubtasks: ((String) -> Void)?
    /// (moved task, new parent task ID or nil for top level, previous sibling task ID or nil for first).
    var onMoveTask: ((TaskItem, String?, String?) -> Void)?

    private static let taskDragType = NSPasteboard.PasteboardType("dev.crazytan.TaskMenu.task-drag")

    private let scrollView = NSScrollView()
    private let outlineView = TaskListOutlineView()
    private let emptyStateContainer = NSView()
    private var nodes: [TaskOutlineNode] = []
    private var nodeByKey: [String: TaskOutlineNode] = [:]
    private var nodeByTaskID: [String: TaskOutlineNode] = [:]
    private var completedGroupNode: TaskOutlineNode?
    private var collapsedTaskIDs: Set<String> = []
    private var expandedCompletedSubtaskParentIDs: Set<String> = []
    private var isSearching = false
    private var pendingFlashTaskIDs: Set<String> = []
    private var flashingTaskIDs: Set<String> = []
    private var suppressExpansionCallbacks = false
    private var hasRenderedOnce = false
    /// Identifies the list/search context of the last render; a context switch
    /// (different list, search keystroke) re-renders without row animations.
    private var lastRenderContextKey = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var scrollOffset: NSPoint {
        scrollView.contentView.bounds.origin
    }

    func restoreScrollOffset(_ offset: NSPoint) {
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func flashTask(taskID: String) {
        if nodeByTaskID[taskID] != nil {
            applyFlash(taskID: taskID)
        } else {
            pendingFlashTaskIDs.insert(taskID)
        }
    }

    func render(
        appState: AppState,
        showCompleted: Bool,
        expandedCompletedSubtaskParentIDs: Set<String>
    ) {
        isSearching = appState.isSearching
        // Collapse state is ignored while searching so matching subtasks stay visible.
        let newCollapsedTaskIDs = isSearching ? [] : appState.collapsedTaskIDs
        self.expandedCompletedSubtaskParentIDs = expandedCompletedSubtaskParentIDs

        let contextKey = "\(appState.selectedListId ?? "")|\(appState.searchText)"
        let animated = hasRenderedOnce
            && contextKey == lastRenderContextKey
            && window != nil
            && !emptyStateWillChangeVisibility(appState: appState)
        lastRenderContextKey = contextKey

        if animated {
            applyAnimatedRender(appState: appState, showCompleted: showCompleted, newCollapsedTaskIDs: newCollapsedTaskIDs)
        } else {
            collapsedTaskIDs = newCollapsedTaskIDs
            rebuildNodes(appState: appState, showCompleted: showCompleted)
            outlineView.reloadData()
            restoreExpansionState()
        }
        updateEmptyState(appState: appState)
        applyPendingFlashes()
        hasRenderedOnce = true
    }

    /// Row animations look wrong when the whole list swaps with the empty
    /// state, so those renders fall back to a plain reload.
    private func emptyStateWillChangeVisibility(appState: AppState) -> Bool {
        let showsNoResults = !appState.tasks.isEmpty
            && appState.isSearching
            && appState.searchFilteredTasks.isEmpty
        let willShowEmpty = appState.tasks.isEmpty || showsNoResults
        return willShowEmpty != scrollView.isHidden
    }

    // MARK: - Animated Diff Rendering

    /// Reconciles the outline against the new app state with row animations:
    /// per-parent keyed index diffs inside a begin/endUpdates batch, animated
    /// expand/collapse for disclosure changes, and cell reloads for rows whose
    /// content changed. Falls back to fades when Reduce Motion is on.
    private func applyAnimatedRender(
        appState: AppState,
        showCompleted: Bool,
        newCollapsedTaskIDs: Set<String>
    ) {
        let previousNodeByKey = nodeByKey
        let previousCollapsedTaskIDs = collapsedTaskIDs
        collapsedTaskIDs = newCollapsedTaskIDs

        let previousTopNodes = nodes
        let previousSignatures = previousNodeByKey.mapValues { $0.signature }
        let previousChildren = previousNodeByKey.mapValues { $0.children }

        rebuildNodes(appState: appState, showCompleted: showCompleted, reusingNodesFrom: previousNodeByKey)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let removeAnimation: NSTableView.AnimationOptions = reduceMotion ? .effectFade : [.slideUp, .effectFade]
        let insertAnimation: NSTableView.AnimationOptions = reduceMotion ? .effectFade : [.slideDown, .effectFade]

        var keptNodes: [TaskOutlineNode] = []
        var insertedNodes: [TaskOutlineNode] = []

        outlineView.beginUpdates()
        applyChildDiffs(
            parent: nil,
            oldChildren: previousTopNodes,
            previousChildrenByKey: previousChildren,
            removeAnimation: removeAnimation,
            insertAnimation: insertAnimation,
            keptNodes: &keptNodes,
            insertedNodes: &insertedNodes
        )
        outlineView.endUpdates()

        // Newly inserted parents start collapsed; expand them to match state
        // without animating (their row just slid in).
        suppressExpansionCallbacks = true
        for node in insertedNodes where !node.children.isEmpty {
            if let task = node.task, collapsedTaskIDs.contains(task.id) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        }
        suppressExpansionCallbacks = false

        // Kept parents whose disclosure state changed animate open/closed.
        for node in keptNodes {
            guard let task = node.task, !node.children.isEmpty else { continue }
            let wasCollapsed = previousCollapsedTaskIDs.contains(task.id)
            let isCollapsed = collapsedTaskIDs.contains(task.id)
            guard wasCollapsed != isCollapsed else { continue }
            suppressExpansionCallbacks = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.22
                if isCollapsed {
                    outlineView.animator().collapseItem(node)
                } else {
                    outlineView.animator().expandItem(node)
                }
            }
            suppressExpansionCallbacks = false
        }

        // Refresh rows whose content changed (titles, counts, chevrons, ...).
        for node in keptNodes where previousSignatures[node.key] != node.signature {
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }
    }

    /// Emits animated remove/insert batches for one parent's children and
    /// recurses into kept nodes. Removed subtrees vanish with their root row,
    /// and inserted subtrees arrive with theirs, so neither recurses.
    private func applyChildDiffs(
        parent: TaskOutlineNode?,
        oldChildren: [TaskOutlineNode],
        previousChildrenByKey: [String: [TaskOutlineNode]],
        removeAnimation: NSTableView.AnimationOptions,
        insertAnimation: NSTableView.AnimationOptions,
        keptNodes: inout [TaskOutlineNode],
        insertedNodes: inout [TaskOutlineNode]
    ) {
        let newChildren = parent?.children ?? nodes
        let difference = newChildren.map { $0.key }.difference(from: oldChildren.map { $0.key })

        var removedOffsets = IndexSet()
        var insertedKeys = Set<String>()
        var insertedOffsets = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removedOffsets.insert(offset)
            case .insert(let offset, let key, _):
                insertedOffsets.insert(offset)
                insertedKeys.insert(key)
            }
        }
        if !removedOffsets.isEmpty {
            outlineView.removeItems(at: removedOffsets, inParent: parent, withAnimation: removeAnimation)
        }
        if !insertedOffsets.isEmpty {
            outlineView.insertItems(at: insertedOffsets, inParent: parent, withAnimation: insertAnimation)
        }

        for child in newChildren {
            if insertedKeys.contains(child.key) {
                insertedNodes.append(child)
                collectInsertedDescendants(of: child, into: &insertedNodes)
            } else {
                keptNodes.append(child)
                applyChildDiffs(
                    parent: child,
                    oldChildren: previousChildrenByKey[child.key] ?? [],
                    previousChildrenByKey: previousChildrenByKey,
                    removeAnimation: removeAnimation,
                    insertAnimation: insertAnimation,
                    keptNodes: &keptNodes,
                    insertedNodes: &insertedNodes
                )
            }
        }
    }

    private func collectInsertedDescendants(of node: TaskOutlineNode, into insertedNodes: inout [TaskOutlineNode]) {
        for child in node.children {
            insertedNodes.append(child)
            collectInsertedDescendants(of: child, into: &insertedNodes)
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        TaskMenuAppKit.configureTaskListScrollIndicators(scrollView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 34
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.indentationPerLevel = 0
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineViewClicked)
        outlineView.menuForRow = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        outlineView.onActivateSelectedRow = { [weak self] in
            guard let self else { return }
            self.openTask(atRow: self.outlineView.selectedRow)
        }
        outlineView.registerForDraggedTypes([Self.taskDragType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)

        scrollView.documentView = outlineView
        addSubview(scrollView)
        TaskMenuAppKit.pin(scrollView, to: self)

        emptyStateContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyStateContainer.isHidden = true
        addSubview(emptyStateContainer)
        TaskMenuAppKit.pin(emptyStateContainer, to: self)
    }

    @objc private func outlineViewClicked() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? TaskOutlineNode
        else {
            return
        }
        if node.isCompletedGroup {
            onToggleCompletedSection?()
        } else if let parentID = node.completedSubtasksParentID {
            onToggleCompletedSubtasks?(parentID)
        } else if node.task != nil {
            openTask(atRow: row)
        }
    }

    /// Deselects the row before opening so returning from the detail screen
    /// shows no lingering highlight. Arrow keys move the selection without
    /// opening; only clicks and Return-key activation navigate.
    private func openTask(atRow row: Int) {
        guard let node = outlineView.item(atRow: row) as? TaskOutlineNode,
              let task = node.task
        else {
            return
        }
        outlineView.deselectRow(row)
        onOpenTask?(task)
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard let node = outlineView.item(atRow: row) as? TaskOutlineNode,
              let task = node.task
        else {
            return nil
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: "Delete", symbolName: "trash") { [weak self] in
            self?.onDeleteTask?(task)
        })
        return menu
    }

    private func rebuildNodes(
        appState: AppState,
        showCompleted: Bool,
        reusingNodesFrom previousNodeByKey: [String: TaskOutlineNode] = [:]
    ) {
        nodeByKey = [:]
        nodeByTaskID = [:]
        completedGroupNode = nil

        let builder = NodeBuilder(previousNodeByKey: previousNodeByKey)

        let activeRoots = TaskListPresentation.incompleteRootTasks(from: appState)
        let activeNodes = activeRoots.map { makeActiveNode(for: $0, appState: appState, level: 0, builder: builder, parentKey: nil) }

        let completedTasks = completedTasksForFinalSection(
            TaskListPresentation.completedSectionSourceTasks(from: appState)
        )
        if completedTasks.isEmpty {
            nodes = activeNodes
            registerNodes(nodes)
            return
        }

        let completedNodes = completedTasks.map { task in
            builder.node(
                kind: .task(TaskListTaskEntry(
                    task: task,
                    indentLevel: task.parent == nil ? 0 : 1,
                    section: .completed
                )),
                parentKey: nil
            )
        }
        // The completed section is auto-expanded while searching.
        let isExpanded = showCompleted || isSearching
        let completedGroup = builder.node(
            kind: .completedGroup(count: completedTasks.count, isExpanded: isExpanded),
            parentKey: nil
        )
        completedGroupNode = completedGroup
        nodes = activeNodes + [completedGroup] + (isExpanded ? completedNodes : [])
        registerNodes(nodes)
    }

    private func registerNodes(_ topNodes: [TaskOutlineNode]) {
        func register(_ node: TaskOutlineNode) {
            nodeByKey[node.key] = node
            if let task = node.task {
                nodeByTaskID[task.id] = node
            }
            node.children.forEach(register)
        }
        topNodes.forEach(register)
    }

    private func makeActiveNode(
        for task: TaskItem,
        appState: AppState,
        level: Int,
        builder: NodeBuilder,
        parentKey: String?
    ) -> TaskOutlineNode {
        let entry = TaskListTaskEntry(
            task: task,
            indentLevel: level,
            section: task.isCompleted ? .completed : .active
        )
        let nodeKey = TaskOutlineNode.key(forTaskID: task.id)
        // While searching, matching completed subtasks render inline instead of
        // behind the completed-subtasks disclosure.
        var children = TaskListPresentation.displaySubtasks(of: task.id, from: appState)
            .filter { isSearching || !$0.isCompleted }
            .map { makeActiveNode(for: $0, appState: appState, level: level + 1, builder: builder, parentKey: nodeKey) }
        let completedSubtasks = isSearching
            ? []
            : completedSubtasksForOpenParent(task.id, tasks: appState.tasks)
        if !completedSubtasks.isEmpty {
            let isExpanded = expandedCompletedSubtaskParentIDs.contains(task.id)
            children.append(builder.node(
                kind: .completedSubtasksGroup(
                    parentID: task.id,
                    count: completedSubtasks.count,
                    isExpanded: isExpanded,
                    indentLevel: level + 1
                ),
                parentKey: nodeKey
            ))
            if isExpanded {
                children.append(contentsOf: completedSubtasks.map { child in
                    builder.node(
                        kind: .task(TaskListTaskEntry(
                            task: child,
                            indentLevel: level + 1,
                            section: .completed
                        )),
                        parentKey: nodeKey
                    )
                })
            }
        }
        let node = builder.node(kind: .task(entry), parentKey: parentKey)
        node.children = children
        node.isCollapsed = collapsedTaskIDs.contains(task.id)
        return node
    }

    private func updateEmptyState(appState: AppState) {
        emptyStateContainer.subviews.forEach { $0.removeFromSuperview() }

        let showsNoResults = !appState.tasks.isEmpty
            && appState.isSearching
            && appState.searchFilteredTasks.isEmpty
        let shouldShowEmpty = appState.tasks.isEmpty || showsNoResults
        let wasShowingEmpty = !emptyStateContainer.isHidden
        emptyStateContainer.isHidden = !shouldShowEmpty
        scrollView.isHidden = shouldShowEmpty

        // Crossfade when the list and the empty state swap places.
        if shouldShowEmpty != wasShowingEmpty, hasRenderedOnce, window != nil {
            let incoming: NSView = shouldShowEmpty ? emptyStateContainer : scrollView
            incoming.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                incoming.animator().alphaValue = 1
            }
        }
        guard shouldShowEmpty else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyStateContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyStateContainer.centerYAnchor)
        ])

        if showsNoResults {
            let image = NSImageView(image: TaskMenuAppKit.symbol("magnifyingglass", pointSize: 28, weight: .thin) ?? NSImage())
            image.contentTintColor = .tertiaryLabelColor
            stack.addArrangedSubview(image)
            stack.addArrangedSubview(TaskMenuAppKit.label(
                "No results",
                font: .systemFont(ofSize: 13),
                color: .secondaryLabelColor
            ))
        } else if appState.isLoading {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.setAccessibilityLabel("Loading tasks")
            spinner.startAnimation(nil)
            stack.addArrangedSubview(spinner)
        } else {
            let image = NSImageView(image: TaskMenuAppKit.symbol("checklist.unchecked", pointSize: 30, weight: .thin) ?? NSImage())
            image.contentTintColor = .tertiaryLabelColor
            stack.addArrangedSubview(image)
            stack.addArrangedSubview(TaskMenuAppKit.label(
                "No open tasks",
                font: .systemFont(ofSize: 13),
                color: .secondaryLabelColor
            ))
        }
    }

    private func restoreExpansionState() {
        suppressExpansionCallbacks = true
        defer { suppressExpansionCallbacks = false }

        for node in nodeByTaskID.values where !node.children.isEmpty {
            if let task = node.task, collapsedTaskIDs.contains(task.id) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        }

        if let completedGroupNode {
            outlineView.reloadItem(completedGroupNode)
        }
    }

    private func applyPendingFlashes() {
        guard !pendingFlashTaskIDs.isEmpty else { return }
        for taskID in pendingFlashTaskIDs where nodeByTaskID[taskID] != nil {
            pendingFlashTaskIDs.remove(taskID)
            applyFlash(taskID: taskID)
        }
    }

    private func applyFlash(taskID: String) {
        flashingTaskIDs.insert(taskID)
        reloadRow(forTaskID: taskID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.flashingTaskIDs.remove(taskID)
            self.reloadRow(forTaskID: taskID)
        }
    }

    private func reloadRow(forTaskID taskID: String) {
        guard let node = nodeByTaskID[taskID] else { return }
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? TaskOutlineNode {
            return node.children.count
        }
        return nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? TaskOutlineNode {
            return node.children[index]
        }
        return nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TaskOutlineNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? TaskOutlineNode else { return 34 }
        switch node.kind {
        case .completedGroup:
            return TaskListRowLayout.completedGroupRowHeight
        case .completedSubtasksGroup:
            return TaskListRowLayout.completedSubtasksGroupRowHeight
        case .task:
            return 34
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? TaskOutlineNode else { return false }
        return node.task != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !suppressExpansionCallbacks,
              let node = notification.userInfo?["NSObject"] as? TaskOutlineNode
        else {
            return
        }
        if node.isCompletedGroup {
            onToggleCompletedSection?()
        } else if let task = node.task, !isSearching {
            onToggleCollapsed?(task.id)
        }
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard !suppressExpansionCallbacks,
              let node = notification.userInfo?["NSObject"] as? TaskOutlineNode
        else {
            return
        }
        if node.isCompletedGroup {
            onToggleCompletedSection?()
        } else if let task = node.task, !isSearching {
            onToggleCollapsed?(task.id)
        }
    }

    // MARK: - Drag And Drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard !isSearching,
              let node = item as? TaskOutlineNode,
              let entry = node.taskEntry,
              entry.section == .active
        else {
            return nil
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(entry.task.id, forType: Self.taskDragType)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let draggedNode = draggedNode(from: info) else { return [] }
        // Keep the row-highlight feedback for drop-on-row nesting.
        if index == NSOutlineViewDropOnItemIndex,
           let node = item as? TaskOutlineNode,
           !isSearching,
           draggedNode.taskEntry?.section == .active,
           canDrop(draggedNode, under: node) {
            return .move
        }
        guard let target = resolveDropTarget(
            item: item,
            childIndex: index,
            draggedNode: draggedNode,
            location: outlineView.convert(info.draggingLocation, from: nil)
        ) else {
            return []
        }
        outlineView.setDropItem(target.parentNode, dropChildIndex: target.childIndex)
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let draggedNode = draggedNode(from: info),
              let draggedTask = draggedNode.task,
              let target = resolveDropTarget(
                item: item,
                childIndex: index,
                draggedNode: draggedNode,
                location: outlineView.convert(info.draggingLocation, from: nil)
              )
        else {
            return false
        }

        // The dragged row is still in the sibling list at this point, so a drop
        // directly below itself resolves to previous == itself: a no-op.
        var previousTaskID: String?
        if target.childIndex > 0 {
            let siblings = activeSiblingNodes(under: target.parentNode)
            previousTaskID = siblings[target.childIndex - 1].task?.id
        }
        guard previousTaskID != draggedTask.id else { return false }

        onMoveTask?(draggedTask, target.parentNode?.task?.id, previousTaskID)
        return true
    }

    private struct TaskDropTarget {
        /// Destination parent node; nil is the top level.
        let parentNode: TaskOutlineNode?
        /// Insertion index within the destination's active sibling nodes.
        let childIndex: Int
    }

    private func draggedNode(from info: NSDraggingInfo) -> TaskOutlineNode? {
        guard let taskID = info.draggingPasteboard.string(forType: Self.taskDragType) else { return nil }
        return nodeByTaskID[taskID]
    }

    /// Incomplete task nodes under the given parent (or the top level), i.e.
    /// the sibling group a drag can reorder. Completed rows and the completed
    /// disclosure groups always render after them and are excluded.
    private func activeSiblingNodes(under parentNode: TaskOutlineNode?) -> [TaskOutlineNode] {
        let candidates = parentNode?.children ?? nodes
        return Array(candidates.prefix(while: { $0.taskEntry?.section == .active }))
    }

    private func resolveDropTarget(
        item: Any?,
        childIndex: Int,
        draggedNode: TaskOutlineNode,
        location: NSPoint
    ) -> TaskDropTarget? {
        guard !isSearching, draggedNode.taskEntry?.section == .active else { return nil }

        if let node = item as? TaskOutlineNode {
            guard canDrop(draggedNode, under: node) else { return nil }
            let siblingCount = activeSiblingNodes(under: node).count
            // Dropping on the row itself nests the task as the last subtask.
            let resolvedIndex = childIndex == NSOutlineViewDropOnItemIndex
                ? siblingCount
                : min(childIndex, siblingCount)
            return TaskDropTarget(parentNode: node, childIndex: resolvedIndex)
        }

        guard item == nil else { return nil }
        let rootSiblings = activeSiblingNodes(under: nil)
        // Drops on empty space or below the completed section land at the end
        // of the top-level active tasks.
        let resolvedIndex = childIndex == NSOutlineViewDropOnItemIndex
            ? rootSiblings.count
            : min(childIndex, rootSiblings.count)

        // With outline indentation disabled, the gap between an expanded
        // parent row and its first child is proposed as a root drop even
        // though the insertion line shows the first-subtask position; treat it
        // as one. Root placement after the parent stays reachable through the
        // gap below the parent's last visible child.
        if resolvedIndex > 0 {
            let parentCandidate = rootSiblings[resolvedIndex - 1]
            if !parentCandidate.children.isEmpty,
               outlineView.isItemExpanded(parentCandidate),
               isLocation(location, directlyBelowRowOf: parentCandidate),
               canDrop(draggedNode, under: parentCandidate) {
                return TaskDropTarget(parentNode: parentCandidate, childIndex: 0)
            }
        }

        return TaskDropTarget(parentNode: nil, childIndex: resolvedIndex)
    }

    private func isLocation(_ location: NSPoint, directlyBelowRowOf node: TaskOutlineNode) -> Bool {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        let rowRect = outlineView.rect(ofRow: row)
        return location.y <= rowRect.maxY + rowRect.height / 2
    }

    /// Whether the dragged task may become a child of `parentNode`. Reordering
    /// under the current parent is always allowed; re-parenting is limited to
    /// leaf tasks nesting under top-level tasks, matching Google Tasks' single
    /// level of subtasks.
    private func canDrop(_ draggedNode: TaskOutlineNode, under parentNode: TaskOutlineNode) -> Bool {
        guard let parentEntry = parentNode.taskEntry,
              parentEntry.section == .active,
              parentNode !== draggedNode,
              !isNode(parentNode, inSubtreeOf: draggedNode)
        else {
            return false
        }
        if draggedNode.task?.parent == parentEntry.task.id {
            return true
        }
        return parentEntry.indentLevel == 0 && draggedNode.children.isEmpty
    }

    private func isNode(_ node: TaskOutlineNode, inSubtreeOf ancestor: TaskOutlineNode) -> Bool {
        ancestor.children.contains { child in
            child === node || isNode(node, inSubtreeOf: child)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TaskOutlineNode else { return nil }

        switch node.kind {
        case .completedGroup(let count, let isExpanded):
            let row = CompletedGroupCellView(count: count, isExpanded: isExpanded)
            row.onToggle = { [weak self] in
                self?.onToggleCompletedSection?()
            }
            return row
        case .completedSubtasksGroup(let parentID, let count, let isExpanded, let indentLevel):
            let row = CompletedGroupCellView(
                count: count,
                isExpanded: isExpanded,
                indentLevel: indentLevel,
                showsSeparator: false,
                leadingOffset: TaskListRowLayout.completedSubtasksDisclosureLeadingOffset,
                centerYOffset: 0,
                expandedDescription: "Hide completed subtasks",
                collapsedDescription: "Show completed subtasks"
            )
            row.onToggle = { [weak self] in
                self?.onToggleCompletedSubtasks?(parentID)
            }
            return row
        case .task(let entry):
            let row = TaskOutlineTaskCellView(
                entry: entry,
                isFlashing: entry.section == .active && flashingTaskIDs.contains(entry.task.id),
                hasChildren: !node.children.isEmpty,
                isCollapsed: collapsedTaskIDs.contains(entry.task.id)
            )
            row.onToggle = { [weak self] in
                self?.onToggleTask?(entry.task)
            }
            row.onToggleCollapse = { [weak self] in
                guard let self, !self.isSearching else { return }
                self.onToggleCollapsed?(entry.task.id)
            }
            return row
        }
    }
}

/// Creates outline nodes for a render pass, reusing the previous render's
/// instances for unchanged keys so `NSOutlineView` keeps item identity across
/// animated diffs. A node is only reused under its previous parent; a task
/// that moved to a different parent gets a fresh instance so one batch never
/// removes and reinserts the same object.
@MainActor
private final class NodeBuilder {
    private let previousNodeByKey: [String: TaskOutlineNode]

    init(previousNodeByKey: [String: TaskOutlineNode]) {
        self.previousNodeByKey = previousNodeByKey
    }

    func node(kind: TaskOutlineNode.Kind, parentKey: String?) -> TaskOutlineNode {
        let key = TaskOutlineNode.key(for: kind)
        if let existing = previousNodeByKey[key], existing.parentKey == parentKey {
            existing.kind = kind
            existing.children = []
            existing.isCollapsed = false
            return existing
        }
        return TaskOutlineNode(kind: kind, parentKey: parentKey)
    }
}

@MainActor
private final class TaskOutlineNode: NSObject {
    enum Kind {
        case completedGroup(count: Int, isExpanded: Bool)
        case completedSubtasksGroup(parentID: String, count: Int, isExpanded: Bool, indentLevel: Int)
        case task(TaskListTaskEntry)
    }

    var kind: Kind
    var children: [TaskOutlineNode]
    var isCollapsed = false
    let parentKey: String?

    init(kind: Kind, children: [TaskOutlineNode] = [], parentKey: String? = nil) {
        self.kind = kind
        self.children = children
        self.parentKey = parentKey
    }

    static func key(forTaskID taskID: String) -> String {
        "task:\(taskID)"
    }

    static func key(for kind: Kind) -> String {
        switch kind {
        case .completedGroup:
            return "completed-group"
        case .completedSubtasksGroup(let parentID, _, _, _):
            return "completed-subtasks:\(parentID)"
        case .task(let entry):
            return key(forTaskID: entry.task.id)
        }
    }

    var key: String {
        Self.key(for: kind)
    }

    /// Cheap description of everything the row's cell renders; kept rows
    /// reload when it changes between renders.
    var signature: String {
        switch kind {
        case .completedGroup(let count, let isExpanded):
            return "group|\(count)|\(isExpanded)"
        case .completedSubtasksGroup(let parentID, let count, let isExpanded, let indentLevel):
            return "subgroup|\(parentID)|\(count)|\(isExpanded)|\(indentLevel)"
        case .task(let entry):
            let due = entry.task.due ?? ""
            return "task|\(entry.task.title)|\(entry.task.isCompleted)|\(due)|\(entry.indentLevel)|\(entry.section)|\(children.isEmpty)|\(isCollapsed)"
        }
    }

    var task: TaskItem? {
        taskEntry?.task
    }

    var taskEntry: TaskListTaskEntry? {
        if case .task(let entry) = kind {
            return entry
        }
        return nil
    }

    var isCompletedGroup: Bool {
        if case .completedGroup = kind {
            return true
        }
        return false
    }

    var completedSubtasksParentID: String? {
        if case .completedSubtasksGroup(let parentID, _, _, _) = kind {
            return parentID
        }
        return nil
    }
}

@MainActor
private final class CompletedGroupCellView: NSTableCellView {
    var onToggle: (() -> Void)?

    init(
        count: Int,
        isExpanded: Bool,
        indentLevel: Int = 0,
        showsSeparator: Bool = true,
        leadingOffset: CGFloat = 0,
        centerYOffset: CGFloat = 3,
        expandedDescription: String = "Hide completed tasks",
        collapsedDescription: String = "Show completed tasks"
    ) {
        super.init(frame: .zero)
        setup(
            count: count,
            isExpanded: isExpanded,
            indentLevel: indentLevel,
            showsSeparator: showsSeparator,
            leadingOffset: leadingOffset,
            centerYOffset: centerYOffset,
            expandedDescription: expandedDescription,
            collapsedDescription: collapsedDescription
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(
        count: Int,
        isExpanded: Bool,
        indentLevel: Int,
        showsSeparator: Bool,
        leadingOffset: CGFloat,
        centerYOffset: CGFloat,
        expandedDescription: String,
        collapsedDescription: String
    ) {
        wantsLayer = true
        layer?.borderWidth = 0
        let leading = TaskListRowLayout.leadingInset + CGFloat(indentLevel) * TaskMenuMetrics.taskIndentWidth + leadingOffset

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = TaskListRowLayout.disclosureSpacing
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStack)

        let chevron = TaskMenuActionButton(
            symbolName: isExpanded ? "chevron.down" : "chevron.right",
            pointSize: 9,
            weight: .semibold,
            accessibilityDescription: isExpanded ? expandedDescription : collapsedDescription
        ) { [weak self] in
            self?.onToggle?()
        }
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: TaskListRowLayout.disclosureSlotSize),
            chevron.heightAnchor.constraint(equalToConstant: TaskListRowLayout.disclosureSlotSize)
        ])
        headerStack.addArrangedSubview(chevron)

        let label = TaskMenuAppKit.label(
            "Completed · \(count)",
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
        )
        headerStack.addArrangedSubview(label)

        var constraints = [
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            headerStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: centerYOffset)
        ]

        if showsSeparator {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(separator)
            constraints.append(contentsOf: [
                separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor),
                separator.topAnchor.constraint(equalTo: topAnchor, constant: 2)
            ])
        }

        NSLayoutConstraint.activate(constraints)
    }
}

@MainActor
private final class TaskOutlineTaskCellView: NSTableCellView {
    var onToggle: (() -> Void)?
    var onToggleCollapse: (() -> Void)?

    private let entry: TaskListTaskEntry
    private let isFlashing: Bool
    private let hasChildren: Bool
    private let isCollapsed: Bool

    init(entry: TaskListTaskEntry, isFlashing: Bool, hasChildren: Bool, isCollapsed: Bool) {
        self.entry = entry
        self.isFlashing = isFlashing
        self.hasChildren = hasChildren
        self.isCollapsed = isCollapsed
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = isFlashing
            ? NSColor.controlAccentColor.withAlphaComponent(0.11).cgColor
            : NSColor.clear.cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: self,
            insets: NSEdgeInsets(
                top: 5,
                left: TaskListRowLayout.leadingInset + CGFloat(entry.indentLevel) * TaskMenuMetrics.taskIndentWidth,
                bottom: 5,
                right: 14
            )
        )

        let disclosureSlot = makeDisclosureSlot()
        stack.addArrangedSubview(disclosureSlot)
        stack.setCustomSpacing(TaskListRowLayout.disclosureSpacing, after: disclosureSlot)

        let checkButton = TaskMenuActionButton(
            symbolName: entry.task.isCompleted ? "checkmark.circle.fill" : "circle",
            pointSize: entry.indentLevel > 0 ? 16 : 18,
            weight: .regular,
            accessibilityDescription: entry.task.isCompleted
                ? "Mark \(entry.task.title) incomplete"
                : "Mark \(entry.task.title) complete"
        ) { [weak self] in
            self?.onToggle?()
        }
        checkButton.contentTintColor = entry.task.isCompleted ? .controlAccentColor : .secondaryLabelColor
        checkButton.refusesFirstResponder = true
        checkButton.usesPointingHandCursor = true
        NSLayoutConstraint.activate([
            checkButton.widthAnchor.constraint(equalToConstant: 26),
            checkButton.heightAnchor.constraint(lessThanOrEqualToConstant: 24)
        ])
        stack.addArrangedSubview(checkButton)

        let title = TaskMenuAppKit.label(
            entry.task.title,
            font: .systemFont(ofSize: entry.indentLevel > 0 ? 12.5 : 13),
            color: entry.task.isCompleted ? .tertiaryLabelColor : .labelColor,
            lines: 1
        )
        if entry.task.isCompleted {
            let attributed = NSMutableAttributedString(string: entry.task.title)
            attributed.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: attributed.length)
            )
            attributed.addAttribute(
                .foregroundColor,
                value: NSColor.tertiaryLabelColor,
                range: NSRange(location: 0, length: attributed.length)
            )
            title.attributedStringValue = attributed
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Truncated titles stay recoverable on hover.
        title.toolTip = entry.task.title
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(TaskMenuAppKit.spacer())

        if let dueDate = entry.task.dueDate {
            stack.addArrangedSubview(TaskMenuAppKit.label(
                DateFormatting.relativeString(from: dueDate),
                font: .systemFont(ofSize: 11),
                color: dueDateColor(dueDate)
            ))
        }
    }

    private func makeDisclosureSlot() -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: TaskListRowLayout.disclosureSlotSize),
            slot.heightAnchor.constraint(equalToConstant: TaskListRowLayout.disclosureSlotSize)
        ])
        guard hasChildren else { return slot }

        let chevron = TaskMenuActionButton(
            symbolName: isCollapsed ? "chevron.right" : "chevron.down",
            pointSize: 9,
            weight: .semibold,
            accessibilityDescription: isCollapsed
                ? "Expand subtasks of \(entry.task.title)"
                : "Collapse subtasks of \(entry.task.title)"
        ) { [weak self] in
            self?.onToggleCollapse?()
        }
        slot.addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: TaskListRowLayout.disclosureSlotSize),
            chevron.heightAnchor.constraint(equalToConstant: TaskListRowLayout.disclosureSlotSize)
        ])
        return slot
    }

    private func dueDateColor(_ date: Date) -> NSColor {
        if Calendar.current.isDateInToday(date) {
            return .controlAccentColor
        } else if date < Calendar.current.startOfDay(for: Date()) {
            return .systemRed
        }
        return .secondaryLabelColor
    }
}

/// Keys that activate (open) the selected task row.
enum TaskListKeyboardCommands {
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    static func isActivationKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == returnKeyCode || keyCode == keypadEnterKeyCode
    }
}

@MainActor
private final class TaskListOutlineView: NSOutlineView {
    var menuForRow: ((Int) -> NSMenu?)?
    var onActivateSelectedRow: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if TaskListKeyboardCommands.isActivationKeyCode(event.keyCode), selectedRow >= 0 {
            onActivateSelectedRow?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        return menuForRow?(row)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        return NSRect(x: 0, y: frame.origin.y, width: bounds.width, height: frame.height)
    }
}
