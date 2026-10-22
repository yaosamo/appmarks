import AppKit
import SwiftUI

struct SwitcherItem: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let icon: NSImage?
    let thumbnail: NSImage?
    var isFocused = false
    var isMinimized = false

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.title == b.title && a.thumbnail === b.thumbnail && a.isFocused == b.isFocused
            && a.isMinimized == b.isMinimized
    }
}

/// The appmark under the pointer, if any.
final class AppmarkHover: ObservableObject {
    @Published var hovered: CGWindowID?
}

/// The panel never becomes key, so without this the first click on an appmark would be swallowed.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where each appmark sits, at rest and with the one under the pointer grown to a `switcherHoverSize`
/// square. It grows away from the window, so the edge facing it stays put, and its neighbours slide
/// aside rather than being covered; nothing follows the pointer. The panel is sized up front for the
/// largest appmark grown, and `resting` is the box the appmarks fill at rest.
struct AppmarkLayout {
    let size: CGSize
    let resting: CGRect
    let backdropPadding: CGFloat
    let cornerRadius: CGFloat

    private let vertical: Bool
    /// Growing toward smaller x (a column left of its window edge) or smaller y (a row above it).
    private let growsTowardStart: Bool
    private let along: [CGFloat]
    private let across: [CGFloat]
    /// Each appmark's length along the axis and thickness across it once hovered.
    private let grownAlong: [CGFloat]
    private let grownAcross: [CGFloat]
    private let spacing: CGFloat
    private let ids: [CGWindowID]
    /// Where the resting stack starts along its axis, in the panel.
    private let start: CGFloat

    init(items: [SwitcherItem], style: Style, vertical: Bool, growsTowardStart: Bool) {
        self.vertical = vertical
        self.growsTowardStart = growsTowardStart
        backdropPadding = style.switcherBackground ? 5 : 0
        cornerRadius = style.switcherCornerRadius
        spacing = style.switcherSpacing
        ids = items.map(\.id)

        let height = CGFloat(style.switcherHeight)
        let sizes = items.map { item -> CGSize in
            let aspect = item.thumbnail.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1.5 } ?? 1.5
            return CGSize(width: height * aspect, height: height)
        }
        let box = CGFloat(style.switcherHoverSize)
        let along = sizes.map { vertical ? $0.height : $0.width }
        let across = sizes.map { vertical ? $0.width : $0.height }
        self.along = along
        self.across = across
        // Hovered, every appmark fills the box whatever its window's shape, and never shrinks.
        let grown = sizes.map { CGSize(width: max($0.width, box), height: max($0.height, box)) }
        let grownAlong = grown.map { vertical ? $0.height : $0.width }
        let grownAcross = grown.map { vertical ? $0.width : $0.height }
        self.grownAlong = grownAlong
        self.grownAcross = grownAcross

        let length = along.reduce(0, +) + spacing * CGFloat(max(along.count - 1, 0))
        // An appmark grows around its centre, so half its growth lands on each side of the stack.
        let margin = (zip(grownAlong, along).map { $0 - $1 }.max() ?? 0) / 2
        // Room for the backdrop, shadows and the icon badge that pokes out of an appmark's corner.
        let edge = backdropPadding + 10
        start = edge + margin
        let restingCross = across.max() ?? 0
        let crossExtent = (grownAcross.max() ?? 0) + 2 * edge
        let crossStart = growsTowardStart ? crossExtent - edge - restingCross : edge
        let alongExtent = length + 2 * (edge + margin)
        size = vertical ? CGSize(width: crossExtent, height: alongExtent) : CGSize(width: alongExtent, height: crossExtent)
        resting = vertical ? CGRect(x: crossStart, y: start, width: restingCross, height: length)
                           : CGRect(x: start, y: crossStart, width: length, height: restingCross)
    }

    /// Each appmark's frame in the panel (top-left origin), with `hovered` grown or all at rest. The
    /// hovered appmark grows around its resting centre, so its neighbours slide aside by half each way.
    func frames(hovered: CGWindowID?) -> [CGRect] {
        let grown = hovered.flatMap { ids.firstIndex(of: $0) }
        var starts: [CGFloat] = []
        var cursor: CGFloat = 0
        for i in along.indices {
            starts.append(cursor)
            cursor += (i == grown ? grownAlong[i] : along[i]) + spacing
        }
        var shift: CGFloat = 0
        if let grown {
            let restingCentre = along[..<grown].reduce(0, +) + spacing * CGFloat(grown) + along[grown] / 2
            shift = restingCentre - (starts[grown] + grownAlong[grown] / 2)
        }

        return along.indices.map { i in
            let length = i == grown ? grownAlong[i] : along[i]
            let thickness = i == grown ? grownAcross[i] : across[i]
            let a = start + starts[i] + shift
            let c = growsTowardStart ? resting.maxEdge(vertical: vertical) - thickness : resting.minEdge(vertical: vertical)
            return vertical ? CGRect(x: c, y: a, width: thickness, height: length)
                            : CGRect(x: a, y: c, width: length, height: thickness)
        }
    }

    /// The appmark under `point` as the appmarks are drawn now, with `hovered` grown; gaps go to the
    /// nearer side. Nil once the point leaves their outline.
    func item(at point: CGPoint, hovered: CGWindowID?) -> CGWindowID? {
        let frames = frames(hovered: hovered)
        guard backdrop(frames).contains(point) else { return nil }
        let at = vertical ? point.y : point.x
        let index = frames.indices.last { at >= frames[$0].minEdge(vertical: !vertical) - spacing / 2 } ?? 0
        return ids.indices.contains(index) ? ids[index] : nil
    }

    func backdrop(_ frames: [CGRect]) -> CGRect {
        frames.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -backdropPadding, dy: -backdropPadding)
    }
}

private extension CGRect {
    /// The cross-axis edges: x for a column, y for a row.
    func minEdge(vertical: Bool) -> CGFloat { vertical ? minX : minY }
    func maxEdge(vertical: Bool) -> CGFloat { vertical ? maxX : maxY }
}

struct SwitcherChip: View {
    let item: SwitcherItem
    let style: Style
    let size: CGSize

    var body: some View {
        let badge = min(size.height * 0.5, 32)
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail = item.thumbnail {
                    // Fills the square a hovered appmark grows to, cropped rather than stretched.
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: style.switcherCornerRadius).fill(.regularMaterial)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: style.switcherCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: style.switcherCornerRadius)
                .strokeBorder(item.isFocused ? Color.accentColor : .primary.opacity(0.15), lineWidth: item.isFocused ? 2 : 0.5))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            if style.switcherShowIcon, let icon = item.icon {
                Image(nsImage: icon).resizable()
                    .frame(width: badge, height: badge)
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Behind-window vibrancy, which follows the system's light or dark appearance. SwiftUI materials only
/// blend with the panel's own clear content, so they render the same murky dark in either mode.
struct Backdrop: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        // The panel is never key, and an inactive effect view drops its vibrancy.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let edge = cornerRadius * 2 + 1
        let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        view.maskImage = mask
    }
}
