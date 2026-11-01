// Renders the intro of the dynamic cut as PNG frames (1920×1080, 30 fps): the empty desktop, Bubbleg's panel
// flying in, the real bubbles dropping into it one by one, then the windows fading in around them. It ends on
// exactly the first frame of the take, so the cut into live footage doesn't move.
//
//   swift AppStore/launch/intro.swift <plate.png> <ref.png> <out-dir>
//
// plate.png: the 3840×2160 capture region with no windows (so no panel); ref.png: the same region with the
// windows and the docked panel, as the take starts. Geometry below is in those 4K pixels.
import AppKit
import CoreImage

let args = CommandLine.arguments
let plate = CIImage(contentsOf: URL(fileURLWithPath: args[1]))!
let ref = CIImage(contentsOf: URL(fileURLWithPath: args[2]))!
let out = URL(fileURLWithPath: args[3])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let fps = 30.0, duration = 2.8
// Camera: close on the panel (1920×1080 of the 4K plate, so 1:1 and sharp), then a smooth pull back while the
// windows appear, landing on the take's opening framing, 2880×1620 from (0, 270).
let camClose = CGRect(x: 0, y: 464, width: 1920, height: 1080)
let camWide = CGRect(x: 0, y: 200, width: 3200, height: 1800)  // the take's one fixed framing
func camera(_ t: Double) -> CGRect {
    let p = min(max((t - 1.95) / 0.85, 0), 1)
    let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
    return CGRect(x: mix(camClose.minX, camWide.minX), y: mix(camClose.minY, camWide.minY),
                  width: mix(camClose.width, camWide.width), height: mix(camClose.height, camWide.height))
}
let outSize = CGSize(width: 1920, height: 1080)
let H = 2160.0

// Measured on ref.png (top-left origin).
let panel = CGRect(x: 18, y: 683, width: 194, height: 642)
let bubbles: [(thumb: CGRect, icon: CGRect)] = [
    (CGRect(x: 24, y: 690, width: 168, height: 116), CGRect(x: 144, y: 757, width: 52, height: 52)),
    (CGRect(x: 24, y: 818, width: 170, height: 116), CGRect(x: 146, y: 885, width: 52, height: 52)),
    (CGRect(x: 26, y: 947, width: 160, height: 114), CGRect(x: 139, y: 1014, width: 52, height: 52)),
    (CGRect(x: 24, y: 1074, width: 182, height: 116), CGRect(x: 159, y: 1142, width: 52, height: 52)),
    (CGRect(x: 24, y: 1202, width: 166, height: 118), CGRect(x: 137, y: 1270, width: 52, height: 52)),
]

let ci = CIContext()
func cg(_ image: CIImage, _ rect: CGRect) -> CGImage {
    // CIImage is bottom-left; convert a top-left rect.
    ci.createCGImage(image, from: CGRect(x: rect.minX, y: H - rect.maxY, width: rect.width, height: rect.height))!
}
let plateCG = cg(plate, CGRect(x: 0, y: 0, width: 3840, height: 2160))
let refCG = cg(ref, CGRect(x: 0, y: 0, width: 3840, height: 2160))
// The empty panel: the desktop behind it, blurred and darkened, like the real material.
let panelBG: CGImage = {
    let blurred = plate.clampedToExtent().applyingGaussianBlur(sigma: 30).cropped(to: plate.extent)
    return cg(blurred, panel)
}()
let bubbleCGs = bubbles.map { b in cg(ref, b.thumb.union(b.icon)) }

func easeOutBack(_ p: Double) -> Double {
    let c1 = 1.70158, c3 = c1 + 1
    return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
}
func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

for frame in 0..<Int(duration * fps) {
    let t = Double(frame) / fps
    let ctx = CGContext(data: nil, width: Int(outSize.width), height: Int(outSize.height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Map 4K top-left coordinates into the output (bottom-left) through the camera.
    let cam = camera(t)
    let s = outSize.width / cam.width
    func map(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - cam.minX) * s, y: outSize.height - (r.maxY - cam.minY) * s, width: r.width * s, height: r.height * s)
    }
    ctx.draw(plateCG, in: map(CGRect(x: 0, y: 0, width: 3840, height: 2160)))

    // Panel: flies in from off the left edge, springing past its spot and settling.
    let pIn = clamp((t - 0.5) / 0.55)
    if pIn > 0 {
        let dx = -300 * (1 - easeOutBack(pIn))
        let rect = map(panel.offsetBy(dx: dx, dy: 0))
        ctx.saveGState()
        ctx.setAlpha(clamp(pIn * 4))
        let path = CGPath(roundedRect: rect, cornerWidth: 24 * s, cornerHeight: 24 * s, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(path); ctx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path); ctx.clip()
        ctx.draw(panelBG, in: rect)
        ctx.setFillColor(NSColor(srgbRed: 0.09, green: 0.08, blue: 0.11, alpha: 0.5).cgColor); ctx.fill(rect)
        ctx.resetClip()
        ctx.addPath(path); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(1); ctx.strokePath()

        // Bubbles drop in from above, one every 0.2 s, overshooting a little.
        for (i, b) in bubbles.enumerated() {
            let p = clamp((t - 1.05 - Double(i) * 0.2) / 0.38)
            guard p > 0 else { continue }
            let e = easeOutBack(p)
            let area = b.thumb.union(b.icon)
            let scale = 0.75 + 0.25 * e
            let w = area.width * scale, h = area.height * scale
            let target = CGRect(x: area.midX - w / 2 + dx, y: area.midY - h / 2 - 110 * (1 - e), width: w, height: h)
            ctx.saveGState()
            ctx.setAlpha(clamp(p * 3))
            // Clip to the bubble's own shapes (thumbnail and app icon), not the box around them.
            let sx = w / area.width, sy = h / area.height
            func local(_ r: CGRect) -> CGRect {
                map(CGRect(x: target.minX + (r.minX - area.minX) * sx, y: target.minY + (r.minY - area.minY) * sy,
                           width: r.width * sx, height: r.height * sy))
            }
            let clip = CGMutablePath()
            clip.addRoundedRect(in: local(b.thumb.insetBy(dx: 1, dy: 1)), cornerWidth: 13 * s, cornerHeight: 13 * s)
            clip.addRoundedRect(in: local(b.icon), cornerWidth: 12 * s, cornerHeight: 12 * s)
            ctx.addPath(clip); ctx.clip()
            ctx.draw(bubbleCGs[i], in: map(target))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // The windows appear around the bubbles: fade into the take's first frame.
    let fade = clamp((t - 2.15) / 0.4)
    if fade > 0 {
        ctx.saveGState(); ctx.setAlpha(fade * fade * (3 - 2 * fade))
        ctx.draw(refCG, in: map(CGRect(x: 0, y: 0, width: 3840, height: 2160)))
        ctx.restoreGState()
    }

    let url = out.appendingPathComponent(String(format: "f%03d.png", frame))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}
print("wrote \(Int(duration * fps)) frames to \(out.path)")
