import AppKit

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
