// Draws the still layers of the launch video (1920×1080) into a folder:
//   canvas.png   dark ground, pink wash from the top, the footage card's soft shadow
//   mask.png     the footage card's rounded corners (white on black, for alphamerge)
//   cap-N.png    one caption per beat, centred in the 230 px band above the footage
//   title.png / end-store.png / end-launch.png   full-frame text for the opening and closing cards
//   icon.png     the app icon at 240 px
//
//   swift AppStore/launch/cards.swift <out-dir> <icon-1024.png>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconSource = NSImage(contentsOfFile: CommandLine.arguments[2])!
let size = CGSize(width: 1920, height: 1080)
// The footage card: 1640×922 (16:9), centred, bleeding off the bottom edge.
let card = CGRect(x: 140, y: 230, width: 1640, height: 922)
let radius: CGFloat = 28

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let ground = color(0x14171D), ink = color(0xECEEF2), quiet = color(0x9199A8), pink = color(0xF2409D)

func rounded(_ px: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: px, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: px) } ?? base
}

/// Draws in top-left coordinates, like the video.
func render(_ name: String, opaque: Bool = false, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ns
    let ctx = ns.cgContext
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

/// Centred text; `y` is the line's vertical centre.
func text(_ string: String, _ font: NSFont, _ fill: NSColor, centerY y: CGFloat, kern: CGFloat) {
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    let s = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: fill, .paragraphStyle: p, .kern: kern])
    let h = s.boundingRect(with: CGSize(width: size.width - 160, height: 400), options: .usesLineFragmentOrigin).height
    s.draw(with: CGRect(x: 80, y: y - h / 2, width: size.width - 160, height: h), options: .usesLineFragmentOrigin)
}

func wash(_ ctx: CGContext, center: CGPoint, radius r: CGFloat, alpha: CGFloat) {
    let g = CGGradient(colorsSpace: nil, colors: [pink.withAlphaComponent(alpha).cgColor, pink.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
}

render("canvas.png") { ctx in
    ctx.setFillColor(ground.cgColor); ctx.fill(CGRect(origin: .zero, size: size))
    wash(ctx, center: CGPoint(x: size.width / 2, y: -80), radius: 1300, alpha: 0.20)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 20), blur: 70, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(ground.cgColor); ctx.fillPath()
    ctx.restoreGState()
}

// Same size as the card; scaled footage is merged with it, then laid on the canvas at the card's origin.
do {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(card.width), pixelsHigh: Int(card.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(origin: .zero, size: card.size))
    ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: card.size), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("mask.png"))
}

let captions = [
    "All your windows, as bubbles",
    "Click one to jump right to it",
    "Drop it on your window. It snaps on.",
    "And follows you wherever you go",
]
for (i, caption) in captions.enumerated() {
    render("cap-\(i + 1).png") { _ in text(caption, rounded(76, .semibold), ink, centerY: 120, kern: -1.5) }
}

let icon = 240.0
render("icon.png") { _ in
    iconSource.draw(in: CGRect(x: (size.width - icon) / 2, y: 250, width: icon, height: icon))
}
render("title.png") { _ in
    text("Bubbleg", rounded(132, .bold), ink, centerY: 596, kern: -3)
    text("Every window on your Mac, one click away", rounded(48, .medium), quiet, centerY: 738, kern: -0.5)
}
render("end-store.png") { _ in
    text("Bubbleg", rounded(132, .bold), ink, centerY: 596, kern: -3)
    text("For Mac", rounded(48, .medium), quiet, centerY: 738, kern: -0.5)
}
render("end-launch.png") { _ in
    text("Bubbleg", rounded(132, .bold), ink, centerY: 596, kern: -3)
    text("Free for Mac · bubbleg.yaosamo.com", rounded(48, .medium), quiet, centerY: 738, kern: -0.5)
}
render("ground.png") { ctx in
    ctx.setFillColor(ground.cgColor); ctx.fill(CGRect(origin: .zero, size: size))
    wash(ctx, center: CGPoint(x: size.width / 2, y: 370), radius: 900, alpha: 0.22)
}
print("wrote layers to \(out.path)")
