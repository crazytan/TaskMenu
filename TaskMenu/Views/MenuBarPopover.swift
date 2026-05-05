import SwiftUI

struct MenuBarPopover: View {
    @Bindable var appState: AppState
    var onRequestClose: (() -> Void)?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            if appState.isShowingInitialTaskLoad {
                InitialTaskLoadingView()
                    .transition(.opacity)
            } else if !appState.isSignedIn {
                SignInView(appState: appState)
                    .transition(.opacity)
            } else {
                TaskListView(appState: appState)

                Divider()

                HStack(spacing: 8) {
                    if let error = appState.errorMessage {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text(error)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.2)) {
                                appState.errorMessage = nil
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Spacer()
                    Button {
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                        onRequestClose?()
                    } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .transition(.opacity)
            }
        }
        .frame(width: 320, height: appState.isSignedIn ? 480 : nil)
        .taskMenuPopoverSurface(
            usesFullWindowLiquidGlass: appState.experimentalFullWindowLiquidGlassEnabled
        )
        .taskMenuLiquidGlassWindow(
            enabled: appState.experimentalFullWindowLiquidGlassEnabled
        )
        .animation(.easeInOut(duration: 0.25), value: appState.isSignedIn)
        .animation(.easeInOut(duration: 0.2), value: appState.errorMessage != nil)
        .task {
            await appState.refreshForMenuPresentation()
        }
    }
}

private struct InitialTaskLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            Text("Loading tasks...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    @ViewBuilder
    func taskMenuPopoverSurface(usesFullWindowLiquidGlass: Bool) -> some View {
        if #available(macOS 26.0, *) {
            if usesFullWindowLiquidGlass {
                self.containerBackground(.clear, for: .window)
            } else {
                self
                    .containerBackground(.clear, for: .window)
                    .glassEffect(.regular, in: Rectangle())
            }
        } else {
            self.background(.regularMaterial)
        }
    }
}
