import AppKit

@MainActor
private enum TaskListRowLayout {
    static let leadingInset: CGFloat = 4
    static let disclosureSlotSize: CGFloat = 18
    static let disclosureSpacing: CGFloat = 4
}

@MainActor
final class TaskListContentView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenTask: ((TaskItem) -> Void)?
    var onToggleTask: ((TaskItem) -> Void)?
    var onDeleteTask: ((TaskItem) -> Void)?
    var onToggleCollapsed: ((String) -> Void)?
    var onToggleCompletedSection: (() -> Void)?

    private let scrollView = NSScrollView()
    private let outlineView = TaskListOutlineView()
    private let emptyStateContainer = NSView()
    private var nodes: [TaskOutlineNode] = []
    private var nodeByTaskID: [String: TaskOutlineNode] = [:]
    private var completedGroupNode: TaskOutlineNode?
    private var collapsedTaskIDs: Set<String> = []
    private var pendingFlashTitles: Set<String> = []
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

    func flashTask(title: String) {
        pendingFlashTitles.insert(title)
    }

    func render(
        appState: AppState,
        showCompleted: Bool,
        inlineSubtaskParentID: String?,
        revealedCompletedSubtaskParentIDs: Set<String>
    ) {
        collapsedTaskIDs = appState.collapsedTaskIDs
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
              let node = outlineView.item(atRow: row) as? TaskOutlineNode,
              node.isCompletedGroup
        else {
            return
        }
        onToggleCompletedSection?()
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

        let completedTasks = tasksSortedByGooglePosition(appState.tasks.filter(\.isCompleted))
        if completedTasks.isEmpty {
            nodes = activeNodes
            return
        }

        let completedNodes = completedTasks.map { task in
            TaskOutlineNode(kind: .task(TaskListTaskEntry(
                task: task,
                indentLevel: task.parent == nil ? 0 : 1,
                isParentCompleted: false,
                section: .completed
            )))
        }
        let completedGroup = TaskOutlineNode(kind: .completedGroup(count: completedTasks.count, isExpanded: showCompleted))
        completedGroupNode = completedGroup
        nodes = activeNodes + [completedGroup] + (showCompleted ? completedNodes : [])
    }

    private func makeActiveNode(for task: TaskItem, appState: AppState, level: Int) -> TaskOutlineNode {
        let entry = TaskListTaskEntry(
            task: task,
            indentLevel: level,
            isParentCompleted: false,
            section: .active
        )
        let children = appState.subtasks(of: task.id)
            .filter { !$0.isCompleted }
            .map { makeActiveNode(for: $0, appState: appState, level: level + 1) }
        let node = TaskOutlineNode(kind: .task(entry), children: children)
        nodeByTaskID[task.id] = node
        return node
    }

    private func updateEmptyState(appState: AppState) {
        emptyStateContainer.subviews.forEach { $0.removeFromSuperview() }

        let activeCount = appState.tasks.filter { !$0.isCompleted }.count
        let shouldShowEmpty = (appState.isLoading && appState.tasks.isEmpty) || activeCount == 0
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

        if appState.isLoading {
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
            if let task = node.task, appState.collapsedTaskIDs.contains(task.id) {
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
        guard !pendingFlashTitles.isEmpty else { return }
        let matchedNodes = nodeByTaskID.values.filter { node in
            guard let task = node.task else { return false }
            return pendingFlashTitles.contains(task.title)
        }
        guard !matchedNodes.isEmpty else { return }

        for node in matchedNodes {
            guard let task = node.task else { continue }
            flashingTaskIDs.insert(task.id)
            pendingFlashTitles.remove(task.title)
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self, taskID = task.id] in
                guard let self else { return }
                self.flashingTaskIDs.remove(taskID)
                if let node = self.nodeByTaskID[taskID] {
                    let row = self.outlineView.row(forItem: node)
                    if row >= 0 {
                        self.outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                    }
                }
            }
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
        return node.isCompletedGroup ? 32 : 34
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
        } else if let task = node.task {
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
        } else if let task = node.task {
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
                self?.onToggleCollapsed?(entry.task.id)
            }
            return row
        }
    }
}

@MainActor
private final class TaskOutlineNode: NSObject {
    enum Kind {
        case completedGroup(count: Int, isExpanded: Bool)
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
}

@MainActor
private final class CompletedGroupCellView: NSTableCellView {
    var onToggle: (() -> Void)?

    init(count: Int, isExpanded: Bool) {
        super.init(frame: .zero)
        setup(count: count, isExpanded: isExpanded)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(count: Int, isExpanded: Bool) {
        wantsLayer = true
        layer?.borderWidth = 0

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

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
            accessibilityDescription: isExpanded ? "Hide completed tasks" : "Show completed tasks"
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

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TaskListRowLayout.leadingInset),
            headerStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3)
        ])
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
