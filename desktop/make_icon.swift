import AppKit

// Renders the 林序下载器 app icon as a 1024×1024 PNG: a teal→sky tile with a
// white download glyph. build.sh shrinks it into an .icns.
let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

let tile = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
                        xRadius: side * 0.225, yRadius: side * 0.225)
// Apple 风格：同一蓝色相的微妙纵向渐变（上亮下深），不用彩色渐变
NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.56, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.00, green: 0.42, blue: 0.90, alpha: 1),
])!.draw(in: tile, angle: -90)

let white = NSColor.white
white.setFill()

// Arrow shaft.
NSBezierPath(roundedRect: NSRect(x: 512 - 58, y: 470, width: 116, height: 250),
             xRadius: 44, yRadius: 44).fill()
// Arrow head.
let head = NSBezierPath()
head.move(to: NSPoint(x: 512 - 208, y: 540))
head.line(to: NSPoint(x: 512 + 208, y: 540))
head.line(to: NSPoint(x: 512, y: 312))
head.close()
head.fill()
// Tray.
NSBezierPath(roundedRect: NSRect(x: 512 - 262, y: 168, width: 524, height: 88),
             xRadius: 44, yRadius: 44).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("图标渲染失败")
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try png.write(to: URL(fileURLWithPath: out))
print("已生成 \(out)")
