// Renders the app icon (1024×1024 PNG) with Core Graphics.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824×824 body centered, continuous-corner rounded rect.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = 186
let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x000000, 0.35))
ctx.addPath(path)
ctx.setFillColor(rgb(0x2A2F8F))
ctx.fillPath()
ctx.restoreGState()

// Background gradient (deep indigo → iris).
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let gradient = CGGradient(colorsSpace: colorSpace, colors: [rgb(0x262B7A), rgb(0x4F6BF2), rgb(0x7A8CFF)] as CFArray,
                          locations: [0, 0.62, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
// Subtle top highlight.
let highlight = CGGradient(colorsSpace: colorSpace, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(highlight, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
ctx.restoreGState()

// Speech bubble: solid tail, translucent body, white outline.
let bubble = CGRect(x: 250, y: 330, width: 524, height: 400)
let tail = CGMutablePath()
tail.move(to: CGPoint(x: 318, y: 352))
tail.addLine(to: CGPoint(x: 282, y: 236))
tail.addLine(to: CGPoint(x: 432, y: 342))
tail.closeSubpath()
ctx.addPath(tail)
ctx.setFillColor(rgb(0xFFFFFF, 0.92))
ctx.fillPath()
let bubblePath = CGPath(roundedRect: bubble, cornerWidth: 120, cornerHeight: 120, transform: nil)
ctx.addPath(bubblePath)
ctx.setFillColor(rgb(0x3E4FD0))
ctx.fillPath()
ctx.addPath(bubblePath)
ctx.setFillColor(rgb(0xFFFFFF, 0.14))
ctx.fillPath()
ctx.addPath(bubblePath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.92))
ctx.setLineWidth(22)
ctx.strokePath()

// Waveform bars inside the bubble.
let bars: [CGFloat] = [0.32, 0.58, 0.9, 0.66, 1.0, 0.72, 0.46, 0.28]
let barWidth: CGFloat = 30, gap: CGFloat = 22
let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
var x = bubble.midX - totalWidth / 2
for h in bars {
    let height = 230 * h
    let rect = CGRect(x: x, y: bubble.midY - height / 2, width: barWidth, height: height)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    x += barWidth + gap
}

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output))
print("icon → \(output)")
