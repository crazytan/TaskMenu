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
                TaskListView(appState: appState) {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                    onRequestClose?()
                }

                if let error = appState.errorMessage {
                    Divider()

                    HStack(spacing: 8) {
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

                        Spacer()
                    }

                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: 320, height: appState.isSignedIn ? 480 : nil)
        .taskMenuPopoverSurface()
        .taskMenuLiquidGlassWindow()
        .animation(.easeInOut(duration: 0.25), value: appState.isSignedIn)
        .animation(.easeInOut(duration: 0.2), value: appState.errorMessage != nil)
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
    func taskMenuPopoverSurface() -> some View {
        if #available(macOS 26.0, *) {
            self
                .containerBackground(.clear, for: .window)
                .glassEffect(.regular, in: Rectangle())
        } else {
            self.background(.regularMaterial)
        }
    }
}
