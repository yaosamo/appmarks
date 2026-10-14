import AppKit

/// The thumbnail that follows the pointer while it is dragged out of the strip. The strip panel is only
/// as wide as the strip and clips its own content, so the drag image needs a window of its own.
final class DragGhost: NSPanel {
    private let imageView = NSImageView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        contentView = imageView
    }

    func show(_ image: NSImage?, at point: NSPoint) {
        guard let image else { return orderOut(nil) }
        let width = 220.0
        let size = NSSize(width: width, height: width * image.size.height / max(image.size.width, 1))
        imageView.image = image
        setFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), display: true)
        alphaValue = 0.85
        orderFrontRegardless()
    }
}
