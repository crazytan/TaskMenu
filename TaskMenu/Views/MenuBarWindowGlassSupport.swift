import AppKit
import SwiftUI

@MainActor
enum MenuBarWindowChrome {
    static let fullWindowGlassIdentifier = NSUserInterfaceItemIdentifier(
        "dev.crazytan.TaskMenu.fullWindowLiquidGlass"
    )

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

    static func applyLiquidGlassSupport(to window: NSWindow?, enabled: Bool) {
        guard let window else { return }

        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { return }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        if enabled {
            wrapContentViewInGlassEffect(window)
        } else {
            unwrapContentViewFromGlassEffect(window)
        }
        #else
        _ = window
        _ = enabled
        #endif
    }

    static func isFullWindowGlassApplied(to window: NSWindow?) -> Bool {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *),
              let contentView = window?.contentView
        else { return false }

        return contentView.identifier == fullWindowGlassIdentifier
        #else
        _ = window
        return false
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func wrapContentViewInGlassEffect(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }
        guard contentView.identifier != fullWindowGlassIdentifier else {
            if let glassView = contentView as? NSGlassEffectView {
                configureGlassView(glassView, bounds: glassView.frame)
            }
            return
        }

        let glassView = NSGlassEffectView(frame: contentView.frame)
        configureGlassView(glassView, bounds: contentView.bounds)

        contentView.removeFromSuperview()
        contentView.frame = glassView.bounds
        contentView.autoresizingMask = [.width, .height]
        glassView.contentView = contentView
        window.contentView = glassView
    }

    @available(macOS 26.0, *)
    private static func unwrapContentViewFromGlassEffect(_ window: NSWindow) {
        guard let glassView = window.contentView as? NSGlassEffectView,
              glassView.identifier == fullWindowGlassIdentifier,
              let hostedContentView = glassView.contentView
        else { return }

        hostedContentView.removeFromSuperview()
        hostedContentView.frame = glassView.bounds
        hostedContentView.autoresizingMask = [.width, .height]
        window.contentView = hostedContentView
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(macOS 26.0, *)
    private static func configureGlassView(_ glassView: NSGlassEffectView, bounds: NSRect) {
        glassView.identifier = fullWindowGlassIdentifier
        glassView.frame = bounds
        glassView.autoresizingMask = [.width, .height]
        glassView.style = .clear
        glassView.cornerRadius = 24
        glassView.wantsLayer = true
        glassView.layer?.backgroundColor = NSColor.clear.cgColor
    }
    #endif
}

private struct MenuBarWindowGlassSupport: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("dev.crazytan.TaskMenu.windowGlassSupportProbe")
        DispatchQueue.main.async {
            MenuBarWindowChrome.applyLiquidGlassSupport(to: view.window, enabled: enabled)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            MenuBarWindowChrome.applyLiquidGlassSupport(to: nsView.window, enabled: enabled)
        }
    }
}

extension View {
    @ViewBuilder
    func taskMenuLiquidGlassWindow(enabled: Bool) -> some View {
        if MenuBarWindowChrome.supportsLiquidGlass {
            self.background {
                MenuBarWindowGlassSupport(enabled: enabled)
                    .frame(width: 0, height: 0)
            }
        } else {
            self
        }
    }
}
