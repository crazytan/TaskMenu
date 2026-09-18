import Foundation

/// Orders tasks by Google's `position` string, preserving API order when
/// positions are missing or tie (`""` sorts first, so a stale local position
/// never trumps a task the server hasn't repositioned yet). Shared by the
/// app (`AppState`, `TaskSortOrder`) and the widget extension, so it lives
/// outside `AppState.swift` and only depends on `TaskItem`.
func tasksSortedByGooglePosition(_ tasks: [TaskItem]) -> [TaskItem] {
    tasks.enumerated()
        .sorted { left, right in
            switch (left.element.position, right.element.position) {
            case let (leftPosition?, rightPosition?) where leftPosition != rightPosition:
                return leftPosition < rightPosition
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.offset < right.offset
            }
        }
        .map(\.element)
}
