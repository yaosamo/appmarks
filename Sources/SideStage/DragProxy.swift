import AppKit
import QuartzCore

/// Stands in for a window while it is dragged toward the strip: macOS cannot scale or tilt another
/// app's window, so the window is hidden and this image shrinks and turns into the strip's perspective.
final class DragProxy: NSPanel {
    private let imageLayer = CALayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(imageLayer)
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resize
        contentView = view
    }

    /// Covers the whole primary screen, so a projection reaching past the image's own bounds is never clipped.
    func show(_ image: NSImage?) {
        imageLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        setFrame(NSScreen.screens[0].frame, display: false)
        orderFrontRegardless()
    }

    /// `frame` is in Accessibility coordinates; `progress` runs 0 (full window) to 1 (over the strip),
    /// and the tilt grows with it into the same projection the strip draws its thumbnails with.
    func update(frame: CGRect, progress: Double, style: Style) {
        let screen = NSScreen.screens[0]
        let center = CGPoint(x: frame.midX, y: screen.frame.height - frame.midY)
        let angle = style.angle * progress * .pi / 180

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(origin: .zero, size: frame.size)
        imageLayer.position = center
        imageLayer.cornerRadius = 10 + (style.cornerRadius - 10) * progress
        var camera = CATransform3DIdentity
        if style.globalPerspective {
            // The strip's single camera, pivoting on its vanishing point rather than on this image.
            camera.m34 = -1 / style.cameraDistance
            let visible = screen.visibleFrame
            let pivot = CGPoint(x: visible.minX + style.globalAnchorX * style.stripWidth - center.x,
                                y: visible.maxY - style.globalAnchorY * visible.height - center.y)
            let tilted = CATransform3DRotate(camera, angle, 0, 1, 0)
            let around = CATransform3DConcat(CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0), tilted)
            imageLayer.transform = CATransform3DConcat(around, CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
        } else {
            camera.m34 = -style.perspective / max(frame.width, frame.height)
            imageLayer.transform = CATransform3DRotate(camera, angle, 0, 1, 0)
        }
        CATransaction.commit()
    }
}
