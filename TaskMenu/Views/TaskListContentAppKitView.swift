import AppKit

@MainActor
final class TaskListContentView: NSView {
    var onOpenTask: ((TaskItem) -> Void)?
    var onToggleTask: ((TaskItem) -> Void)?
    var onDeleteTask: ((TaskItem) -> Void)?
    var onToggleCollapsed: ((String) -> Void)?
    var onAddSubtaskRequested: ((TaskItem) -> Void)?
    var onIndentTask: ((TaskItem) -> Void)?
    var onOutdentTask: ((TaskItem) -> Void)?
    var onToggleCompletedSection: (() -> Void)?
    var onToggleCompletedSubtasksReveal: ((String) -> Void)?
    var onInlineSubtaskCommit: ((String, String) -> Void)?
    var onInlineSubtaskDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        appState: AppState,
        showCompleted: Bool,
        inlineSubtaskParentID: String?,
        revealedCompletedSubtaskParentIDs: Set<String>
    ) {
        subviews.forEach { $0.removeFromSuperview() }

        if appState.isLoading && appState.tasks.isEmpty {
            showCenteredState(symbolName: nil, title: nil, subtitle: nil, showsSpinner: true)
        } else if appState.tasks.isEmpty {
            showCenteredState(
                symbolName: "checklist.unchecked",
                title: "No tasks yet",
                subtitle: "Add one above to get started"
            )
        } else if appState.isSearching && TaskListPresentation.searchResultCount(from: appState) == 0 {
            showCenteredState(
                symbolName: "magnifyingglass",
                title: "No results",
                subtitle: nil
            )
        } else {
            showTaskRows(
                appState: appState,
                showCompleted: showCompleted,
                inlineSubtaskParentID: inlineSubtaskParentID,
                revealedCompletedSubtaskParentIDs: revealedCompletedSubtaskParentIDs
            )
        }
    }

    private func showCenteredState(
        symbolName: String?,
        title: String?,
        subtitle: String?,
        showsSpinner: Bool = false
    ) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if showsSpinner {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            stack.addArrangedSubview(spinner)
        }

        if let symbolName {
            let image = NSImageView(image: TaskMenuAppKit.symbol(symbolName, pointSize: 30, weight: .thin) ?? NSImage())
            image.contentTintColor = .tertiaryLabelColor
            stack.addArrangedSubview(image)
        }

        if let title {
            stack.addArrangedSubview(TaskMenuAppKit.label(
                title,
                font: .systemFont(ofSize: NSFont.systemFontSize),
                color: .secondaryLabelColor
            ))
        }

        if let subtitle {
            stack.addArrangedSubview(TaskMenuAppKit.label(
                subtitle,
                font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                color: .tertiaryLabelColor
            ))
        }
    }

    private func showTaskRows(
        appState: AppState,
        showCompleted: Bool,
        inlineSubtaskParentID: String?,
        revealedCompletedSubtaskParentIDs: Set<String>
    ) {
        let rowsView = TaskListRowsView()
        rowsView.onOpenTask = onOpenTask
        rowsView.onToggleTask = onToggleTask
        rowsView.onDeleteTask = onDeleteTask
        rowsView.onToggleCollapsed = onToggleCollapsed
        rowsView.onAddSubtaskRequested = onAddSubtaskRequested
        rowsView.onIndentTask = onIndentTask
        rowsView.onOutdentTask = onOutdentTask
        rowsView.onToggleCompletedSection = onToggleCompletedSection
        rowsView.onToggleCompletedSubtasksReveal = onToggleCompletedSubtasksReveal
        rowsView.onInlineSubtaskCommit = onInlineSubtaskCommit
        rowsView.onInlineSubtaskDismiss = onInlineSubtaskDismiss
        addSubview(rowsView)
        TaskMenuAppKit.pin(rowsView, to: self)
        rowsView.render(
            appState: appState,
            showCompleted: showCompleted,
            inlineSubtaskParentID: inlineSubtaskParentID,
            revealedCompletedSubtaskParentIDs: revealedCompletedSubtaskParentIDs
        )
    }
}

@MainActor
private final class TaskListRowsView: NSView {
    var onOpenTask: ((TaskItem) -> Void)?
    var onToggleTask: ((TaskItem) -> Void)?
    var onDeleteTask: ((TaskItem) -> Void)?
    var onToggleCollapsed: ((String) -> Void)?
    var onAddSubtaskRequested: ((TaskItem) -> Void)?
    var onIndentTask: ((TaskItem) -> Void)?
    var onOutdentTask: ((TaskItem) -> Void)?
    var onToggleCompletedSection: (() -> Void)?
    var onToggleCompletedSubtasksReveal: ((String) -> Void)?
    var onInlineSubtaskCommit: ((String, String) -> Void)?
    var onInlineSubtaskDismiss: (() -> Void)?

    private let listStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        appState: AppState,
        showCompleted: Bool,
        inlineSubtaskParentID: String?,
        revealedCompletedSubtaskParentIDs: Set<String>
    ) {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        TaskMenuAppKit.configureTaskListScrollIndicators(scrollView)
        addSubview(scrollView)
        TaskMenuAppKit.pin(scrollView, to: self)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content

        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(listStack)
        TaskMenuAppKit.pin(
            listStack,
            to: content,
            insets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        )
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            listStack.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        if appState.isSearching {
            let count = TaskListPresentation.searchResultCount(from: appState)
            let resultLabel = TaskMenuAppKit.label(
                "\(count) result\(count == 1 ? "" : "s")",
                font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                color: .secondaryLabelColor
            )
            listStack.addArrangedSubview(paddedContainer(resultLabel, left: 14, right: 14, top: 4, bottom: 0))
        }

        addEntries(
            TaskListPresentation.flattenedEntries(
                roots: TaskListPresentation.incompleteRootTasks(from: appState),
                section: .active,
                appState: appState,
                revealedCompletedSubtaskParentIDs: revealedCompletedSubtaskParentIDs
            ),
            appState: appState,
            inlineSubtaskParentID: inlineSubtaskParentID
        )

        let completedRoots = TaskListPresentation.completedRootTasks(from: appState)
        if !completedRoots.isEmpty {
            listStack.addArrangedSubview(completedHeader(count: completedRoots.count, isExpanded: showCompleted))
            if showCompleted || appState.isSearching {
                addEntries(
                    TaskListPresentation.flattenedEntries(
                        roots: completedRoots,
                        section: .completed,
                        appState: appState,
                        revealedCompletedSubtaskParentIDs: revealedCompletedSubtaskParentIDs
                    ),
                    appState: appState,
                    inlineSubtaskParentID: inlineSubtaskParentID
                )
            }
        }
    }

    private func addEntries(
        _ entries: [TaskListEntry],
        appState: AppState,
        inlineSubtaskParentID: String?
    ) {
        for entry in entries {
            switch entry {
            case .task(let taskEntry):
                listStack.addArrangedSubview(taskRow(for: taskEntry, appState: appState))
                if shouldPlaceInlineSubtaskField(
                    after: taskEntry.task,
                    parentID: inlineSubtaskParentID,
                    isSearching: appState.isSearching,
                    section: taskEntry.section
                ) {
                    listStack.addArrangedSubview(inlineSubtaskField(parentID: taskEntry.task.id, indentLevel: 1))
                }
            case .completedSubtasksReveal(let revealEntry):
                listStack.addArrangedSubview(completedSubtasksRevealRow(entry: revealEntry))
            }
        }
    }

    private func taskRow(for entry: TaskListTaskEntry, appState: AppState) -> NSView {
        let task = entry.task
        let row = TaskRowAppKitView(configuration: TaskRowAppKitView.Configuration(
            task: task,
            indentLevel: entry.indentLevel,
            isParentCompleted: entry.isParentCompleted,
            hasChildren: appState.hasSubtasks(task.id),
            isCollapsed: appState.collapsedTaskIDs.contains(task.id),
            canIndent: appState.canIndentTask(task),
            canOutdent: appState.canOutdentTask(task),
            canAddSubtask: task.parent == nil && !task.isCompleted
        ))
        row.onOpen = { [weak self] in
            self?.onOpenTask?(task)
        }
        row.onToggle = { [weak self] in
            self?.onToggleTask?(task)
        }
        row.onDelete = { [weak self] in
            self?.onDeleteTask?(task)
        }
        row.onCollapseToggle = { [weak self] in
            self?.onToggleCollapsed?(task.id)
        }
        row.onAddSubtask = { [weak self] in
            self?.onAddSubtaskRequested?(task)
        }
        row.onIndent = { [weak self] in
            self?.onIndentTask?(task)
        }
        row.onOutdent = { [weak self] in
            self?.onOutdentTask?(task)
        }

        return paddedContainer(row, left: 4, right: 10, top: 0, bottom: 0)
    }

    private func completedHeader(count: Int, isExpanded: Bool) -> NSView {
        let button = TaskMenuActionButton(
            symbolName: "chevron.right",
            pointSize: 10,
            accessibilityDescription: isExpanded ? "Hide completed tasks" : "Show completed tasks"
        ) { [weak self] in
            self?.onToggleCompletedSection?()
        }
        button.title = "Completed (\(count))"
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.contentTintColor = .secondaryLabelColor
        return paddedContainer(
            button,
            left: 14,
            right: 14,
            top: TaskListLayout.completedHeaderTopPadding,
            bottom: 0
        )
    }

    private func completedSubtasksRevealRow(entry: CompletedSubtasksRevealEntry) -> NSView {
        let button = TaskMenuActionButton(
            symbolName: "chevron.right",
            pointSize: 9,
            weight: .semibold,
            accessibilityDescription: completedSubtasksRevealTitle(count: entry.count, isRevealed: entry.isRevealed)
        ) { [weak self] in
            self?.onToggleCompletedSubtasksReveal?(entry.parentID)
        }
        button.title = completedSubtasksRevealTitle(count: entry.count, isRevealed: entry.isRevealed)
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.contentTintColor = .secondaryLabelColor
        return paddedContainer(
            button,
            left: 4 + 2 + CGFloat(entry.indentLevel) * TaskMenuMetrics.taskIndentWidth,
            right: 10,
            top: 5,
            bottom: 5
        )
    }

    private func inlineSubtaskField(parentID: String, indentLevel: Int) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8

        let leadingSlot = NSView()
        leadingSlot.translatesAutoresizingMaskIntoConstraints = false
        leadingSlot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        stack.addArrangedSubview(leadingSlot)

        let plus = NSImageView(image: TaskMenuAppKit.symbol("plus.circle", pointSize: 16) ?? NSImage())
        plus.contentTintColor = .secondaryLabelColor
        plus.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            plus.widthAnchor.constraint(equalToConstant: 18),
            plus.heightAnchor.constraint(equalToConstant: 18)
        ])
        stack.addArrangedSubview(plus)

        let field = TaskMenuTextField(placeholder: "Add subtask...")
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.onCommit = { [weak self, weak field] text in
            let title = text.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            field?.stringValue = ""
            self?.onInlineSubtaskCommit?(title, parentID)
        }
        field.onEscape = { [weak self] in
            self?.onInlineSubtaskDismiss?()
        }
        field.onEndEditing = { [weak self] in
            self?.onInlineSubtaskDismiss?()
        }
        stack.addArrangedSubview(field)

        DispatchQueue.main.async { [weak field] in
            field?.window?.makeFirstResponder(field)
        }

        return paddedContainer(
            stack,
            left: 4 + 2 + CGFloat(indentLevel) * TaskMenuMetrics.taskIndentWidth,
            right: 10,
            top: 6,
            bottom: 6
        )
    }

    private func paddedContainer(
        _ child: NSView,
        left: CGFloat,
        right: CGFloat,
        top: CGFloat,
        bottom: CGFloat
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        TaskMenuAppKit.pin(
            child,
            to: container,
            insets: NSEdgeInsets(top: top, left: left, bottom: bottom, right: right)
        )
        return container
    }
}
