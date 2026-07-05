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

    private let scrollView = NSScrollView()
    private let outlineView = TaskListOutlineView()
    private let emptyStateContainer = NSView()
    private var nodes: [TaskOutlineNode] = []
    private var nodeByTaskID: [String: TaskOutlineNode] = [:]
    private var completedGroupNode: TaskOutlineNode?
    private var collapsedTaskIDs: Set<String> = []
    private var expandedCompletedSubtaskParentIDs: Set<String> = []
    private var isSearching = false
    private var pendingFlashTaskIDs: Set<String> = []
    private var flashingTaskIDs: Set<String> = []
    private var suppressExpansionCallbacks = false

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
        collapsedTaskIDs = isSearching ? [] : appState.collapsedTaskIDs
        self.expandedCompletedSubtaskParentIDs = expandedCompletedSubtaskParentIDs
        rebuildNodes(appState: appState, showCompleted: showCompleted)
        updateEmptyState(appState: appState)
        outlineView.reloadData()
        restoreExpansionState(appState: appState)
        applyPendingFlashes()
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
        }
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

    private func rebuildNodes(appState: AppState, showCompleted: Bool) {
        nodeByTaskID = [:]
        completedGroupNode = nil

        let activeRoots = TaskListPresentation.incompleteRootTasks(from: appState)
        let activeNodes = activeRoots.map { makeActiveNode(for: $0, appState: appState, level: 0) }

        let completedTasks = completedTasksForFinalSection(
            TaskListPresentation.completedSectionSourceTasks(from: appState)
        )
        if completedTasks.isEmpty {
            nodes = activeNodes
            return
        }

        let completedNodes = completedTasks.map { task in
            TaskOutlineNode(kind: .task(TaskListTaskEntry(
                task: task,
                indentLevel: task.parent == nil ? 0 : 1,
                section: .completed
            )))
        }
        // The completed section is auto-expanded while searching.
        let isExpanded = showCompleted || isSearching
        let completedGroup = TaskOutlineNode(kind: .completedGroup(count: completedTasks.count, isExpanded: isExpanded))
        completedGroupNode = completedGroup
        nodes = activeNodes + [completedGroup] + (isExpanded ? completedNodes : [])
    }

    private func makeActiveNode(for task: TaskItem, appState: AppState, level: Int) -> TaskOutlineNode {
        let entry = TaskListTaskEntry(
            task: task,
            indentLevel: level,
            section: task.isCompleted ? .completed : .active
        )
        // While searching, matching completed subtasks render inline instead of
        // behind the completed-subtasks disclosure.
        var children = TaskListPresentation.displaySubtasks(of: task.id, from: appState)
            .filter { isSearching || !$0.isCompleted }
            .map { makeActiveNode(for: $0, appState: appState, level: level + 1) }
        let completedSubtasks = isSearching
            ? []
            : completedSubtasksForOpenParent(task.id, tasks: appState.tasks)
        if !completedSubtasks.isEmpty {
            let isExpanded = expandedCompletedSubtaskParentIDs.contains(task.id)
            children.append(TaskOutlineNode(kind: .completedSubtasksGroup(
                parentID: task.id,
                count: completedSubtasks.count,
                isExpanded: isExpanded,
                indentLevel: level + 1
            )))
            if isExpanded {
                children.append(contentsOf: completedSubtasks.map { child in
                    TaskOutlineNode(kind: .task(TaskListTaskEntry(
                        task: child,
                        indentLevel: level + 1,
                        section: .completed
                    )))
                })
            }
        }
        let node = TaskOutlineNode(kind: .task(entry), children: children)
        nodeByTaskID[task.id] = node
        return node
    }

    private func updateEmptyState(appState: AppState) {
        emptyStateContainer.subviews.forEach { $0.removeFromSuperview() }

        let showsNoResults = !appState.tasks.isEmpty
            && appState.isSearching
            && appState.searchFilteredTasks.isEmpty
        let shouldShowEmpty = appState.tasks.isEmpty || showsNoResults
        emptyStateContainer.isHidden = !shouldShowEmpty
        scrollView.isHidden = shouldShowEmpty
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

    private func restoreExpansionState(appState: AppState) {
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

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0,
              let node = outlineView.item(atRow: selectedRow) as? TaskOutlineNode,
              let task = node.task
        else {
            return
        }
        outlineView.deselectRow(selectedRow)
        onOpenTask?(task)
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

@MainActor
private final class TaskOutlineNode: NSObject {
    enum Kind {
        case completedGroup(count: Int, isExpanded: Bool)
        case completedSubtasksGroup(parentID: String, count: Int, isExpanded: Bool, indentLevel: Int)
        case task(TaskListTaskEntry)
    }

    let kind: Kind
    let children: [TaskOutlineNode]

    init(kind: Kind, children: [TaskOutlineNode] = []) {
        self.kind = kind
        self.children = children
    }

    var task: TaskItem? {
        if case .task(let entry) = kind {
            return entry.task
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
            accessibilityDescription: entry.task.isCompleted ? "Mark incomplete" : "Mark complete"
        ) { [weak self] in
            self?.onToggle?()
        }
        checkButton.contentTintColor = entry.task.isCompleted ? .controlAccentColor : .secondaryLabelColor
        checkButton.refusesFirstResponder = true
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
            accessibilityDescription: isCollapsed ? "Expand subtasks" : "Collapse subtasks"
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

@MainActor
private final class TaskListOutlineView: NSOutlineView {
    var menuForRow: ((Int) -> NSMenu?)?

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
