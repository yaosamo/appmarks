// Frames a raw screenshot for the Mac App Store: a 2880×1800 canvas (16:10, the largest size Apple
// takes), a caption in SF Pro Rounded on top, and the screenshot below with rounded corners and a shadow.
//
//   swift AppStore/screenshots/frame.swift raw.png "Every window, one click away" out.png [dark]
//
// Best input: a full-screen capture on a Retina display (⇧⌘3), any 16:10 or 16:9 size.
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let raw = NSImage(contentsOfFile: args[1]),
      let shot = raw.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("usage: frame.swift input.png \"Caption\" output.png [dark]\n".data(using: .utf8)!)
    exit(1)
}
let caption = args[2], output = args[3], dark = args.count > 4 && args[4] == "dark"

let canvas = CGSize(width: 2880, height: 1800)
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
// The site's palette: ground and ink, with the bubble-gum pink from the icon as a soft wash.
let (ground, wash, ink) = dark ? (color(0x14171D), color(0xF2409D, 0.22), NSColor(cgColor: color(0xECEEF2))!)
                               : (color(0xFFFFFF), color(0xF2409D, 0.16), NSColor(cgColor: color(0x191C22))!)

let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(ground)
ctx.fill(CGRect(origin: .zero, size: canvas))
let gradient = CGGradient(colorsSpace: nil, colors: [wash, wash.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: canvas.width / 2, y: 0), startRadius: 0,
                       endCenter: CGPoint(x: canvas.width / 2, y: 0), endRadius: canvas.width * 0.7, options: [])

// Caption: centred in the top band.
let band: CGFloat = 400
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let base = NSFont.systemFont(ofSize: 112, weight: .semibold)
let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 112) } ?? base
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let text = NSAttributedString(string: caption, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph, .kern: -1.5])
let textHeight = text.boundingRect(with: CGSize(width: canvas.width - 320, height: band), options: .usesLineFragmentOrigin).height
text.draw(with: CGRect(x: 160, y: canvas.height - band / 2 - textHeight / 2 - 20, width: canvas.width - 320, height: textHeight),
          options: .usesLineFragmentOrigin)

// Screenshot: as large as fits below the caption, bottom edge bleeding off the canvas like a laptop lid.
let room = CGSize(width: canvas.width - 320, height: canvas.height - band + 120)
let scale = min(room.width / CGFloat(shot.width), room.height / CGFloat(shot.height))
let size = CGSize(width: CGFloat(shot.width) * scale, height: CGFloat(shot.height) * scale)
let rect = CGRect(x: (canvas.width - size.width) / 2, y: canvas.height - band - size.height, width: size.width, height: size.height)
let rounded = CGPath(roundedRect: rect, cornerWidth: 36, cornerHeight: 36, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 90, color: color(0x000000, dark ? 0.6 : 0.22))
ctx.addPath(rounded)
ctx.setFillColor(ground)
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(shot, in: rect)
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output) (2880×1800)")
