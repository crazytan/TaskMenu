import AppKit

@MainActor
private enum TaskDetailViewMetrics {
    static let horizontalInset: CGFloat = 16
    static let subtaskIconWidth: CGFloat = 16
    static let subtaskAddSpacing: CGFloat = 6
    static var contentWidth: CGFloat {
        TaskMenuMetrics.popoverWidth - horizontalInset * 2
    }
    static var subtaskTitleWidth: CGFloat {
        contentWidth - subtaskIconWidth - subtaskAddSpacing
    }
}

@MainActor
final class TaskDetailAppKitViewController: NSViewController, NSTextViewDelegate {
    private let appState: AppState
    private var task: TaskItem
    private var dueDateState: TaskDetailDueDateState
    private let onDismiss: () -> Void

    private let titleField = NSTextField()
    private let notesTextView = NSTextView()
    private let dueDateContainer = NSStackView()
    private let subtaskTitleField = TaskMenuTextField(placeholder: "Add subtask...")
    private let subtaskListStack = NSStackView()
    private let appStateObserver = TaskMenuAppStateObserver()

    init(appState: AppState, task: TaskItem, onDismiss: @escaping () -> Void) {
        self.appState = appState
        self.task = task
        self.dueDateState = TaskDetailDueDateState(task: task)
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        root.addArrangedSubview(header())
        root.addArrangedSubview(content())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        renderSubtasks()
        observeAppState()
    }

    private func header() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(
                top: 14,
                left: TaskDetailViewMetrics.horizontalInset,
                bottom: 12,
                right: TaskDetailViewMetrics.horizontalInset
            )
        )

        stack.addArrangedSubview(TaskMenuActionButton(
            symbolName: "chevron.left",
            pointSize: 13,
            weight: .medium,
            accessibilityDescription: "Back"
        ) { [weak self] in
            self?.onDismiss()
        })

        stack.addArrangedSubview(TaskMenuAppKit.label(
            "Edit Task",
            font: .boldSystemFont(ofSize: NSFont.systemFontSize)
        ))
        stack.addArrangedSubview(TaskMenuAppKit.spacer())

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteTask))
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        stack.addArrangedSubview(deleteButton)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(saveTask))
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.keyEquivalent = "\r"
        stack.addArrangedSubview(doneButton)

        return container
    }

    private func content() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(
                top: 0,
                left: TaskDetailViewMetrics.horizontalInset,
                bottom: TaskDetailLayout.contentBottomPadding,
                right: TaskDetailViewMetrics.horizontalInset
            )
        )

        configureTitleField()
        stack.addArrangedSubview(titleField)

        stack.addArrangedSubview(notesFieldContainer())
        stack.addArrangedSubview(dueDateRow())

        if task.parent == nil {
            stack.addArrangedSubview(subtaskSection())
        }

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        return container
    }

    private func configureTitleField() {
        titleField.stringValue = task.title
        titleField.placeholderString = "Title"
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleField.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth)
        ])
    }

    private func notesFieldContainer() -> NSView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        notesTextView.string = task.notes ?? ""
        notesTextView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notesTextView.isRichText = false
        notesTextView.allowsUndo = true
        notesTextView.delegate = self
        notesTextView.textContainerInset = NSSize(width: 4, height: 4)
        scrollView.documentView = notesTextView

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth),
            scrollView.heightAnchor.constraint(equalToConstant: 84)
        ])
        return scrollView
    }

    private func dueDateRow() -> NSView {
        dueDateContainer.orientation = .horizontal
        dueDateContainer.alignment = .centerY
        dueDateContainer.spacing = 8
        renderDueDateControls()
        return dueDateContainer
    }

    private func renderDueDateControls() {
        dueDateContainer.arrangedSubviews.forEach { view in
            dueDateContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        dueDateContainer.addArrangedSubview(TaskMenuAppKit.label(
            "Due date",
            font: .systemFont(ofSize: NSFont.systemFontSize)
        ))
        dueDateContainer.addArrangedSubview(TaskMenuAppKit.spacer())

        if dueDateState.isEnabled {
            let picker = NSDatePicker()
            picker.datePickerElements = .yearMonthDay
            picker.datePickerStyle = .textFieldAndStepper
            picker.controlSize = .small
            picker.dateValue = dueDateState.selection
            picker.target = self
            picker.action = #selector(dueDateChanged(_:))
            dueDateContainer.addArrangedSubview(picker)

            dueDateContainer.addArrangedSubview(TaskMenuActionButton(
                symbolName: "xmark",
                pointSize: 10,
                weight: .semibold,
                accessibilityDescription: "Clear due date"
            ) { [weak self] in
                self?.dueDateState.clear()
                self?.renderDueDateControls()
            })
        } else {
            let addButton = NSButton(title: "Add due date", target: self, action: #selector(enableDueDate))
            addButton.controlSize = .small
            addButton.bezelStyle = .rounded
            dueDateContainer.addArrangedSubview(addButton)
        }
    }

    private func subtaskSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth).isActive = true

        stack.addArrangedSubview(TaskMenuAppKit.label(
            "Subtasks",
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: .secondaryLabelColor
        ))

        let addStack = NSStackView()
        addStack.orientation = .horizontal
        addStack.alignment = .centerY
        addStack.spacing = TaskDetailViewMetrics.subtaskAddSpacing
        let plus = NSImageView(image: TaskMenuAppKit.symbol("plus.circle", pointSize: 14) ?? NSImage())
        plus.contentTintColor = .systemBlue
        plus.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            plus.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.subtaskIconWidth),
            plus.heightAnchor.constraint(equalToConstant: TaskDetailViewMetrics.subtaskIconWidth)
        ])
        addStack.addArrangedSubview(plus)
        subtaskTitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtaskTitleField.onCommit = { [weak self] _ in
            self?.addSubtask()
        }
        addStack.addArrangedSubview(subtaskTitleField)
        NSLayoutConstraint.activate([
            subtaskTitleField.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.subtaskTitleWidth)
        ])
        stack.addArrangedSubview(addStack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = subtaskListStack
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        subtaskListStack.orientation = .vertical
        subtaskListStack.alignment = .leading
        subtaskListStack.spacing = TaskDetailLayout.subtaskRowSpacing
        subtaskListStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: TaskDetailLayout.subtaskListMinimumHeight(forCount: appState.subtasks(of: task.id).count))
        ])

        return stack
    }

    private func renderSubtasks() {
        subtaskListStack.arrangedSubviews.forEach { view in
            subtaskListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let children = subtasksWithCompletedLast(appState.subtasks(of: task.id))
        for child in children {
            subtaskListStack.addArrangedSubview(subtaskRow(for: child))
        }
    }

    private func subtaskRow(for child: TaskItem) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: TaskDetailLayout.subtaskRowHeight)
        ])

        let symbol = child.isCompleted ? "checkmark.circle.fill" : "circle"
        let icon = NSImageView(image: TaskMenuAppKit.symbol(symbol, pointSize: 14, weight: .light) ?? NSImage())
        icon.contentTintColor = child.isCompleted ? .systemGreen : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16)
        ])
        stack.addArrangedSubview(icon)

        let label = TaskMenuAppKit.label(
            child.title,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: child.isCompleted ? .secondaryLabelColor : .labelColor
        )
        if child.isCompleted {
            let text = NSMutableAttributedString(string: child.title)
            text.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: text.length)
            )
            label.attributedStringValue = text
        }
        stack.addArrangedSubview(label)

        return stack
    }

    private func observeAppState() {
        appStateObserver.observe { [appState, task] in
            _ = appState.tasks
            _ = appState.subtasks(of: task.id)
        } onChange: { [weak self] in
            self?.renderSubtasks()
        }
    }

    @objc private func enableDueDate() {
        dueDateState.enable()
        renderDueDateControls()
    }

    @objc private func dueDateChanged(_ sender: NSDatePicker) {
        dueDateState.selection = sender.dateValue
    }

    @objc private func saveTask() {
        task.title = titleField.stringValue
        let notes = notesTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        task.notes = notes.isEmpty ? nil : notesTextView.string
        let updatedTask = dueDateState.applying(to: task)
        Task { [appState, onDismiss] in
            await appState.updateTask(updatedTask)
            onDismiss()
        }
    }

    @objc private func deleteTask() {
        let task = task
        Task { [appState, onDismiss] in
            await appState.deleteTask(task)
            onDismiss()
        }
    }

    private func addSubtask() {
        let title = subtaskTitleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        subtaskTitleField.stringValue = ""
        Task { [appState, task] in
            await appState.addSubtask(title: title, parentId: task.id)
        }
    }
}
