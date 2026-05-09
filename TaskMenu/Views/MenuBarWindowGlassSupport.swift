import AppKit
import SwiftUI

@MainActor
enum MenuBarWindowChrome {
    static var supportsLiquidGlass: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            true
        } else {
            false
        }
        #else
        false
        #endif
    }

    static func applyLiquidGlassSupport(to window: NSWindow?) {
        guard let window else { return }

        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { return }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        #else
        _ = window
        #endif
    }
}

private struct MenuBarWindowGlassSupport: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("dev.crazytan.TaskMenu.windowGlassSupportProbe")
        DispatchQueue.main.async {
            MenuBarWindowChrome.applyLiquidGlassSupport(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            MenuBarWindowChrome.applyLiquidGlassSupport(to: nsView.window)
        }
    }
}

extension View {
    @ViewBuilder
    func taskMenuLiquidGlassWindow() -> some View {
        if MenuBarWindowChrome.supportsLiquidGlass {
            self.background {
                MenuBarWindowGlassSupport()
                    .frame(width: 0, height: 0)
            }
        } else {
            self
        }
    }
}
