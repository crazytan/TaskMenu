import SwiftUI
import WidgetKit

/// `@main` entry point for the `TaskMenuWidget` extension. See
/// `TaskListWidget.swift` for the widget configuration itself and
/// `TaskMenuWidget/README.md` for the file map.
@main
struct TaskMenuWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaskListWidget()
    }
}
