import AppKit

enum BridgeTheme {
    static let canvas = color(0xEAE8E1)
    static let surface = color(0xF8F7F2)
    static let text = color(0x31383C)
    static let muted = color(0x5D686B)
    static let accent = color(0x506D7D)
    static let separator = color(0xC6C3BB)

    static func configure(_ window: NSWindow) {
        window.appearance = NSAppearance(named: .aqua)
    }

    static func applySurface(to view: NSView, color: NSColor) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
    }

    static func stylePrimaryButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.bezelColor = accent
        button.contentTintColor = .white
    }

    static func styleSecondaryButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.bezelColor = canvas
        button.contentTintColor = accent
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
