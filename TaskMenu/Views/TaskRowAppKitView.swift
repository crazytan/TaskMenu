import AppKit

@MainActor
private enum TaskRowAppKitLayout {
    static let spacing: CGFloat = 8
    static let disclosureWidth: CGFloat = 10
    static let disclosureHitSize: CGFloat = 24
    static let verticalPadding: CGFloat = 6
    static let leadingPadding: CGFloat = 2
    static let trailingPadding: CGFloat = 4
    static let checkboxHitSize: CGFloat = 26
    static let hoverActionSpacing: CGFloat = 4
}

@MainActor
final class TaskRowAppKitView: TaskMenuHoverView {
    struct Configuration {
        let task: TaskItem
        let indentLevel: Int
        let isParentCompleted: Bool
        let hasChildren: Bool
        let isCollapsed: Bool
        let canIndent: Bool
        let canOutdent: Bool
        let canAddSubtask: Bool
    }

    var onOpen: (() -> Void)?
    var onToggle: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCollapseToggle: (() -> Void)?
    var onAddSubtask: (() -> Void)?
    var onIndent: (() -> Void)?
    var onOutdent: (() -> Void)?

    private let configuration: Configuration
    private let checkboxButton = TaskMenuActionButton()
    private let hoverActionsStack = NSStackView()
    private var isHoveringRow = false
    private var isHoveringCheckbox = false

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard event.clickCount == 1 else { return }
        onOpen?()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil, isHoveringCheckbox {
            NSCursor.pop()
            isHoveringCheckbox = false
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if configuration.canAddSubtask {
            menu.addItem(menuItem(title: "Add Subtask", symbolName: "text.badge.plus") { [weak self] in
                self?.onAddSubtask?()
            })
        }

        if configuration.canIndent {
            menu.addItem(menuItem(title: "Make Subtask", symbolName: "arrow.right") { [weak self] in
                self?.onIndent?()
            })
        }

        if configuration.canOutdent {
            menu.addItem(menuItem(title: "Move to Top Level", symbolName: "arrow.left") { [weak self] in
                self?.onOutdent?()
            })
        }

        if menu.items.isEmpty == false {
            menu.addItem(.separator())
        }

        menu.addItem(menuItem(title: "Delete", symbolName: "trash") { [weak self] in
            self?.onDelete?()
        })

        return menu
    }

    private func setup() {
        onHoverChanged = { [weak self] hovering in
            self?.setRowHovering(hovering)
        }

        let rootStack = NSStackView()
        rootStack.orientation = .horizontal
        rootStack.alignment = .top
        rootStack.spacing = TaskRowAppKitLayout.spacing
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        TaskMenuAppKit.pin(
            rootStack,
            to: self,
            insets: NSEdgeInsets(
                top: TaskRowAppKitLayout.verticalPadding,
                left: TaskRowAppKitLayout.leadingPadding + CGFloat(configuration.indentLevel) * TaskMenuMetrics.taskIndentWidth,
                bottom: TaskRowAppKitLayout.verticalPadding,
                right: TaskRowAppKitLayout.trailingPadding
            )
        )

        rootStack.addArrangedSubview(disclosureSlot())
        rootStack.addArrangedSubview(configuredCheckbox())
        rootStack.addArrangedSubview(textStack())
        rootStack.addArrangedSubview(TaskMenuAppKit.spacer())
        rootStack.addArrangedSubview(configuredHoverActions())
    }

    private func disclosureSlot() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: TaskRowAppKitLayout.disclosureWidth),
            container.heightAnchor.constraint(equalToConstant: TaskRowAppKitLayout.disclosureHitSize)
        ])

        guard configuration.hasChildren else { return container }

        let button = TaskMenuActionButton(
            symbolName: "chevron.right",
            pointSize: 9,
            weight: .semibold,
            accessibilityDescription: configuration.isCollapsed ? "Expand subtasks" : "Collapse subtasks"
        ) { [weak self] in
            self?.onCollapseToggle?()
        }
        button.frameRotation = configuration.isCollapsed ? 0 : 90
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: TaskRowAppKitLayout.disclosureHitSize),
            button.heightAnchor.constraint(equalToConstant: TaskRowAppKitLayout.disclosureHitSize)
        ])
        return container
    }

    private func configuredCheckbox() -> NSButton {
        checkboxButton.imagePosition = .imageOnly
        checkboxButton.onPress = { [weak self] in
            self?.onToggle?()
        }
        checkboxButton.toolTip = configuration.task.isCompleted ? "Mark as incomplete" : "Mark as complete"
        checkboxButton.onHoverChanged = { [weak self] hovering in
            self?.setCheckboxHovering(hovering)
        }
        NSLayoutConstraint.activate([
            checkboxButton.widthAnchor.constraint(equalToConstant: TaskRowAppKitLayout.checkboxHitSize),
            checkboxButton.heightAnchor.constraint(equalToConstant: TaskRowAppKitLayout.checkboxHitSize)
        ])
        updateCheckboxImage()
        return checkboxButton
    }

    private func textStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let isGrayedOut = configuration.task.isCompleted || configuration.isParentCompleted
        let title = TaskMenuAppKit.label(
            configuration.task.title,
            font: .systemFont(ofSize: NSFont.systemFontSize),
            color: isGrayedOut ? .secondaryLabelColor : .labelColor,
            lines: 2
        )
        let attributedTitle = NSMutableAttributedString(string: configuration.task.title)
        if configuration.task.isCompleted {
            attributedTitle.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: attributedTitle.length)
            )
            attributedTitle.addAttribute(
                .foregroundColor,
                value: NSColor.secondaryLabelColor,
                range: NSRange(location: 0, length: attributedTitle.length)
            )
            title.attributedStringValue = attributedTitle
        }
        stack.addArrangedSubview(title)

        if let notes = taskNotesPreview(for: configuration.task) {
            stack.addArrangedSubview(TaskMenuAppKit.label(
                notes,
                font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                color: isGrayedOut ? .tertiaryLabelColor : .secondaryLabelColor,
                lines: configuration.indentLevel > 0 ? 2 : 1
            ))
        }

        if let date = configuration.task.dueDate {
            stack.addArrangedSubview(dueDateRow(for: date, isGrayedOut: isGrayedOut))
        }

        return stack
    }

    private func dueDateRow(for date: Date, isGrayedOut: Bool) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3

        let image = NSImageView(image: TaskMenuAppKit.symbol("calendar", pointSize: 11) ?? NSImage())
        image.contentTintColor = isGrayedOut ? .tertiaryLabelColor : dueDateColor(date)
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 12),
            image.heightAnchor.constraint(equalToConstant: 12)
        ])
        stack.addArrangedSubview(image)

        stack.addArrangedSubview(TaskMenuAppKit.label(
            DateFormatting.relativeString(from: date),
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: isGrayedOut ? .tertiaryLabelColor : dueDateColor(date)
        ))

        return stack
    }

    private func configuredHoverActions() -> NSStackView {
        hoverActionsStack.orientation = .horizontal
        hoverActionsStack.alignment = .centerY
        hoverActionsStack.spacing = TaskRowAppKitLayout.hoverActionSpacing
        hoverActionsStack.translatesAutoresizingMaskIntoConstraints = false
        rebuildHoverActions()
        return hoverActionsStack
    }

    private func rebuildHoverActions() {
        hoverActionsStack.arrangedSubviews.forEach { view in
            hoverActionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if configuration.canAddSubtask {
            let addButton = iconActionButton(
                symbolName: "plus",
                toolTip: "Add subtask"
            ) { [weak self] in
                self?.onAddSubtask?()
            }
            addButton.alphaValue = isHoveringRow ? 1 : 0
            hoverActionsStack.addArrangedSubview(addButton)
        }

        if isHoveringRow && !configuration.task.isCompleted {
            hoverActionsStack.addArrangedSubview(iconActionButton(
                symbolName: "trash",
                toolTip: "Delete task"
            ) { [weak self] in
                self?.onDelete?()
            })
        }
    }

    private func iconActionButton(
        symbolName: String,
        toolTip: String,
        onPress: @escaping () -> Void
    ) -> NSButton {
        let button = TaskMenuActionButton(
            symbolName: symbolName,
            pointSize: 12,
            weight: .medium,
            accessibilityDescription: toolTip,
            onPress: onPress
        )
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return button
    }

    private func setRowHovering(_ hovering: Bool) {
        guard hovering != isHoveringRow else { return }
        isHoveringRow = hovering
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            layer?.backgroundColor = hovering
                ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
                : NSColor.clear.cgColor
        }
        rebuildHoverActions()
    }

    private func setCheckboxHovering(_ hovering: Bool) {
        guard hovering != isHoveringCheckbox else { return }
        isHoveringCheckbox = hovering
        updateCheckboxImage()
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    private func updateCheckboxImage() {
        let symbolName: String
        if configuration.task.isCompleted {
            symbolName = "checkmark.circle.fill"
        } else {
            symbolName = isHoveringCheckbox ? "checkmark.circle" : "circle"
        }
        checkboxButton.image = TaskMenuAppKit.symbol(symbolName, pointSize: 18, weight: .light)
        checkboxButton.contentTintColor = configuration.task.isCompleted || isHoveringCheckbox
            ? .systemGreen
            : .secondaryLabelColor
    }

    private func dueDateColor(_ date: Date) -> NSColor {
        if Calendar.current.isDateInToday(date) {
            return .systemBlue
        } else if date < Date() {
            return .systemRed
        }
        return .secondaryLabelColor
    }

    private func menuItem(title: String, symbolName: String, action: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, symbolName: symbolName, action: action)
    }
}
