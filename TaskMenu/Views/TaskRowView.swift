import SwiftUI

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

    var body: some View {
        HStack(spacing: 10) {
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
                .frame(width: 12)
            } else {
                Spacer()
                    .frame(width: 12)
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
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? .green : .secondary)
                    .font(.system(size: 18, weight: .light))
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(checkmarkScale)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.body)
                    .lineLimit(2)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(isGrayedOut ? .secondary : .primary)

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
                .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .padding(.leading, CGFloat(indentLevel) * 20)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
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
}
