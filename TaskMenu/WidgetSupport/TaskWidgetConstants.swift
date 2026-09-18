import Foundation

/// Identifiers shared by the app and the `TaskMenuWidget` extension.
/// Foundation-only; safe to compile into either target. See
/// `scratch/issue-11-desktop-widget/CONTRACT.md` for the source of truth on
/// these values — do not change them without updating that contract.
enum TaskWidgetConstants {
    /// `WidgetConfiguration` kind for the single tasks widget.
    static let widgetKind = "dev.crazytan.TaskMenu.tasks-widget"

    /// File name of the shared snapshot inside the App Group container.
    static let snapshotFileName = "widget-snapshot.v1.json"

    /// Scheme used by `TaskWidgetDeepLink` to route into the popover.
    static let deepLinkScheme = "taskmenu"

    /// Darwin notification posted after a widget-originated mutation so a
    /// running TaskMenu process can reconcile. Carries no payload.
    static let changeNotificationName = "dev.crazytan.TaskMenu.widget-task-changed"

    /// Current `TaskWidgetSnapshot.schemaVersion`. Any stored snapshot with a
    /// greater version decodes to a safe empty/unavailable snapshot.
    static let currentSchemaVersion = 1
}
