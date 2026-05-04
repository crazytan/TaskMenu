import SwiftUI

private enum TaskRowLayout {
    static let spacing: CGFloat = 8
    static let disclosureWidth: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let leadingPadding: CGFloat = 2
    static let trailingPadding: CGFloat = 4
    static let indentWidth: CGFloat = 20
    static let checkboxHitSize: CGFloat = 26
}

struct TaskRowView: View {
    let task: TaskItem
    let indentLevel: Int
    let isParentCompleted: Bool
    let hasChildren: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    var onCollapseToggle: (() -> Void)?
    var onAddSubtask: (() -> Void)?

    @State private var isHovering = false
    @State private var isCheckboxHovering = false
    @State private var checkmarkScale: CGFloat = 1.0

    init(
        task: TaskItem,
        indentLevel: Int = 0,
        isParentCompleted: Bool = false,
        hasChildren: Bool = false,
        isCollapsed: Bool = false,
        onToggle: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onCollapseToggle: (() -> Void)? = nil,
        onAddSubtask: (() -> Void)? = nil
    ) {
        self.task = task
        self.indentLevel = indentLevel
        self.isParentCompleted = isParentCompleted
        self.hasChildren = hasChildren
        self.isCollapsed = isCollapsed
        self.onToggle = onToggle
        self.onDelete = onDelete
        self.onCollapseToggle = onCollapseToggle
        self.onAddSubtask = onAddSubtask
    }

    private var isGrayedOut: Bool {
        task.isCompleted || isParentCompleted
    }

    private var checkboxSymbolName: String {
        if task.isCompleted {
            return "checkmark.circle.fill"
        }
        return isCheckboxHovering ? "checkmark.circle" : "circle"
    }

    private var checkboxColor: Color {
        task.isCompleted || isCheckboxHovering ? .green : .secondary
    }

    var body: some View {
        HStack(spacing: TaskRowLayout.spacing) {
            if hasChildren {
                Button {
                    onCollapseToggle?()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .animation(.easeInOut(duration: 0.15), value: isCollapsed)
                }
                .buttonStyle(.plain)
                .frame(width: TaskRowLayout.disclosureWidth)
            } else {
                Spacer()
                    .frame(width: TaskRowLayout.disclosureWidth)
            }

            Button {
                if !task.isCompleted {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                        checkmarkScale = 1.2
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(200))
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            checkmarkScale = 1.0
                        }
                    }
                }
                onToggle()
            } label: {
                Image(systemName: checkboxSymbolName)
                    .foregroundStyle(checkboxColor)
                    .font(.system(size: 18, weight: .light))
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(checkmarkScale)
                    .frame(width: TaskRowLayout.checkboxHitSize, height: TaskRowLayout.checkboxHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onHover { hovering in
                updateCheckboxHover(hovering)
            }
            .onDisappear(perform: clearCheckboxHover)
            .help(task.isCompleted ? "Mark as incomplete" : "Mark as complete")
            .accessibilityIdentifier("task.checkbox.\(task.id)")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.body)
                    .lineLimit(2)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(isGrayedOut ? .secondary : .primary)
                    .accessibilityIdentifier("task.title.\(task.id)")

                if let date = task.dueDate {
                    Label {
                        Text(DateFormatting.relativeString(from: date))
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .font(.caption)
                    .foregroundStyle(isGrayedOut ? AnyShapeStyle(.tertiary) : AnyShapeStyle(dueDateColor(date)))
                }
            }

            Spacer()

            if let onAddSubtask {
                Button(action: onAddSubtask) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Add subtask")
                .opacity(isHovering ? 1 : 0)
            }

            if isHovering && !task.isCompleted {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Delete task")
            }
        }
        .padding(.vertical, TaskRowLayout.verticalPadding)
        .padding(.leading, TaskRowLayout.leadingPadding)
        .padding(.trailing, TaskRowLayout.trailingPadding)
        .padding(.leading, CGFloat(indentLevel) * TaskRowLayout.indentWidth)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityIdentifier("task.row.\(task.id)")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private func dueDateColor(_ date: Date) -> Color {
        if Calendar.current.isDateInToday(date) {
            return .blue
        } else if date < Date() {
            return .red
        }
        return .secondary
    }

    private func updateCheckboxHover(_ hovering: Bool) {
        guard hovering != isCheckboxHovering else { return }

        withAnimation(.easeInOut(duration: 0.12)) {
            isCheckboxHovering = hovering
        }

        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    private func clearCheckboxHover() {
        guard isCheckboxHovering else { return }
        isCheckboxHovering = false
        NSCursor.pop()
    }
}
