import SwiftUI

struct ListPickerView: View {
    @Bindable var appState: AppState

    var body: some View {
        if appState.taskLists.count > 1 {
            Menu {
                ForEach(appState.taskLists) { list in
                    Button {
                        Task { await appState.selectList(list.id) }
                    } label: {
                        HStack {
                            Text(list.title)
                            if list.id == appState.selectedListId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(appState.selectedList?.title ?? "Tasks")
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("list.picker")
        } else {
            Text(appState.selectedList?.title ?? "Tasks")
                .font(.headline)
        }
    }
}
