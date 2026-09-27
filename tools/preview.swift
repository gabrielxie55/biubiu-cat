import AppKit
// 生成 README 顶部的预览图：三只猫站成一排 + biubiubiu~ 字幕
let out = CommandLine.arguments[1]
let W: CGFloat = 1600, H: CGFloat = 900
func img(_ p: String) -> NSImage { NSImage(contentsOfFile: p)! }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(starting: NSColor(srgbRed: 1, green: 0.9, blue: 0.93, alpha: 1), ending: NSColor(srgbRed: 1, green: 0.96, blue: 0.9, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// 队形和桌宠里一样：同伴放大 1.2 倍站两边，往中间靠一点
let s: CGFloat = 1.05, floorY: CGFloat = 190
let left = img("assets/left/frames/150.png"), main = img("assets/main/frames/088.png"), right = img("assets/right/frames/000.png")
let mw = 388 * s, lw = 225 * 1.2 * s, rw = 210 * 1.2 * s
let mainX = W / 2 - mw / 2
let shadow = NSColor(srgbRed: 0.67, green: 0.35, blue: 0.43, alpha: 0.13)
for (im, x, w, h) in [(left, mainX + 70 * s - lw, lw, 360 * 1.2 * s), (right, mainX + mw - 50 * s, rw, 387 * 1.2 * s)] {
    shadow.setFill(); NSBezierPath(ovalIn: NSRect(x: x + w * 0.2, y: floorY + 30, width: w * 0.6, height: 26)).fill()
    im.draw(in: NSRect(x: x, y: floorY, width: w, height: h))
}
shadow.setFill(); NSBezierPath(ovalIn: NSRect(x: mainX + mw * 0.2, y: floorY + 30, width: mw * 0.6, height: 26)).fill()
main.draw(in: NSRect(x: mainX, y: floorY, width: mw, height: 540 * s))

// 字幕
let size: CGFloat = 76
let font = NSFont.systemFont(ofSize: size, weight: .black).fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.boldSystemFont(ofSize: size)
let text = "biubiubiu~"
let tw = NSAttributedString(string: text, attributes: [.font: font]).size().width
let at = NSPoint(x: W / 2 - tw / 2, y: floorY - 70)
NSAttributedString(string: text, attributes: [.font: font, .strokeColor: NSColor(white: 0.1, alpha: 1), .strokeWidth: 24]).draw(at: at)
NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]).draw(at: at)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
