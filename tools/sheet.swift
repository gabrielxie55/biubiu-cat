import AppKit
// 检查抠图质量：把若干帧（路径列表）并排贴在深色和浅色背景上
let out = CommandLine.arguments[1]
let imgs = CommandLine.arguments.dropFirst(2).map { NSImage(contentsOfFile: $0)! }
let W = imgs.reduce(0) { $0 + $1.size.width }, H = imgs.map { $0.size.height }.max()!
let sheet = NSImage(size: NSSize(width: W, height: H * 2)); sheet.lockFocus()
for (row, color) in [NSColor(white: 0.15, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.93, blue: 0.9, alpha: 1)].enumerated() {
    color.setFill(); NSRect(x: 0, y: CGFloat(row) * H, width: W, height: H).fill()
    var x: CGFloat = 0
    for img in imgs { img.draw(in: NSRect(x: x, y: CGFloat(row) * H, width: img.size.width, height: img.size.height)); x += img.size.width }
}
sheet.unlockFocus()
try! NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
