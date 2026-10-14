import AppKit
import SwiftUI

struct StripItem: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage?
    let thumbnail: NSImage?
    /// Hidden rather than removed while dragged out: removing it would tear down the view that owns the drag.
    let isCarried: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.title == b.title && a.appName == b.appName && a.thumbnail === b.thumbnail
            && a.isCarried == b.isCarried
    }
}

final class StripModel: ObservableObject {
    @Published var items: [StripItem] = []
}

final class StripPanel: NSPanel {
    init(model: StripModel, onSelect: @escaping (CGWindowID, Bool) -> Void,
         onDrag: @escaping (CGWindowID, _ ended: Bool) -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Just above the desktop icons, so every open window covers the strip, as Apple's Stage Manager does.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        contentView = FirstClickHostingView(rootView: StripView(model: model, onSelect: onSelect, onDrag: onDrag))
        reposition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition() {
        let visible = NSScreen.screens[0].visibleFrame
        setFrame(NSRect(x: visible.minX, y: visible.minY, width: Geometry.stripWidth, height: visible.height), display: true)
    }
}

/// The panel never becomes key, so without this the first click on a thumbnail would be swallowed.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct StripView: View {
    @ObservedObject var model: StripModel
    @ObservedObject var settings = Settings.shared
    let onSelect: (CGWindowID, Bool) -> Void
    let onDrag: (CGWindowID, Bool) -> Void

    var body: some View {
        let style = settings.style
        GeometryReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: style.spacing) {
                ForEach(model.items) { item in
                    Thumbnail(item: item, style: style)
                        .onTapGesture { onSelect(item.id, NSEvent.modifierFlags.contains(.option)) }
                        .gesture(DragGesture(minimumDistance: 8)
                            .onChanged { _ in onDrag(item.id, false) }
                            .onEnded { _ in onDrag(item.id, true) })
                        .contextMenu {
                            Button("Add to Stage") { onSelect(item.id, false) }
                            Button("Show Only This Window") { onSelect(item.id, true) }
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, style.stripPadding)
            .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: style.centerVertically ? .center : .top)
        }
        }
        .modifier(Camera(angle: style.globalPerspective ? style.angle : 0, distance: style.cameraDistance,
                         anchor: UnitPoint(x: style.globalAnchorX, y: style.globalAnchorY)))
        .animation(.spring(duration: style.reorderDuration), value: model.items.map(\.id))
    }
}

/// One camera for the whole strip, so every thumbnail shares a single vanishing point. Built by hand
/// because `rotation3DEffect` scales perspective to the view's size, which flattens a screen-tall strip.
private struct Camera: GeometryEffect {
    var angle: Double
    var distance: Double
    var anchor: UnitPoint

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, distance) }
        set { (angle, distance) = (newValue.first, newValue.second) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = size.width * anchor.x, y = size.height * anchor.y
        var camera = CATransform3DIdentity
        camera.m34 = -1 / distance
        let tilted = CATransform3DRotate(camera, angle * .pi / 180, 0, 1, 0)
        let around = CATransform3DConcat(CATransform3DMakeTranslation(-x, -y, 0), tilted)
        return ProjectionTransform(CATransform3DConcat(around, CATransform3DMakeTranslation(x, y, 0)))
    }
}

private struct Thumbnail: View {
    let item: StripItem
    let style: Style
    @State private var hovering = false

    var body: some View {
        VStack(spacing: style.labelGap) {
            ZStack(alignment: .bottomLeading) {
                preview
                    .frame(maxWidth: style.maxWidth, maxHeight: style.maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                    .shadow(color: .black.opacity(style.shadowOpacity), radius: style.shadowRadius, y: style.shadowY)
                    .scaleEffect(x: style.squeeze, y: 1)
                    .rotation3DEffect(.degrees(ownAngle), axis: (0, 1, 0), perspective: style.perspective)
                if style.showIcon, let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: style.iconSize, height: style.iconSize)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                        .offset(x: style.iconOffsetX, y: style.iconOffsetY)
                }
            }
            if style.showLabel {
                Text(hovering && style.titleOnHover ? item.title : item.appName)
                    .font(.system(size: style.labelSize, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 2)
                    .lineLimit(1)
                    .frame(maxWidth: style.stripWidth - 30)
            }
        }
        .scaleEffect(hovering ? style.hoverScale : 1)
        .opacity(item.isCarried ? 0 : 1)
        .animation(.easeOut(duration: style.hoverDuration), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Under the global camera the strip already carries `angle`, so a thumbnail only adds the hover delta.
    private var ownAngle: Double {
        let angle = hovering ? style.hoverAngle : style.angle
        return style.globalPerspective ? angle - style.angle : angle
    }

    @ViewBuilder private var preview: some View {
        if let thumbnail = item.thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .fill(.regularMaterial)
                .aspectRatio(1.5, contentMode: .fit)
                .overlay(Text(item.title).font(.caption2).lineLimit(2).padding(8))
        }
    }
}
