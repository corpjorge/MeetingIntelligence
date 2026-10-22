// Renders the DMG window background (drag-to-Applications layout) at 1x and 2x.
// Usage: swift scripts/make-dmg-background.swift <out-1x.png> <out-2x.png>
// Layout must match package-release.sh: window 660×480 pt, icon centers at (170,150) and (490,150),
// Léeme folder at (330,392).
import AppKit

let width: CGFloat = 660, height: CGFloat = 480
let args = CommandLine.arguments

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // Coordinates below are top-left based, like Finder icon positions; `top(_:)` converts them.
    func top(_ y: CGFloat, _ h: CGFloat = 0) -> CGFloat { height - y - h }

    // Light, slightly cool background.
    NSGradient(starting: color(0xE9ECF6), ending: color(0xF7F8FC))!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    func text(_ string: String, _ font: NSFont, _ hex: UInt32, centerX: CGFloat, y: CGFloat, maxWidth: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color(hex),
                                                                       .paragraphStyle: style])
        let box = attributed.boundingRect(with: NSSize(width: maxWidth, height: 200), options: [.usesLineFragmentOrigin])
        attributed.draw(with: NSRect(x: centerX - maxWidth / 2, y: top(y, ceil(box.height)), width: maxWidth,
                                     height: ceil(box.height)), options: [.usesLineFragmentOrigin])
    }

    text("Instalar Meeting Intelligence", .systemFont(ofSize: 20, weight: .semibold), 0x1F2340, centerX: width / 2, y: 26, maxWidth: 560)
    text("Arrastra la app a la carpeta Aplicaciones", .systemFont(ofSize: 13), 0x5A5F78, centerX: width / 2, y: 56, maxWidth: 560)

    // Arrow between the two icons.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: top(150)))
    arrow.line(to: NSPoint(x: 386, y: top(150)))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    color(0x4F6BF2).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 376, y: top(136)))
    head.line(to: NSPoint(x: 398, y: top(150)))
    head.line(to: NSPoint(x: 376, y: top(164)))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // First-launch note (the app is not notarized).
    let cardTop: CGFloat = 245
    let card = NSRect(x: 60, y: top(cardTop, 66), width: width - 120, height: 66)
    color(0xFFFFFF, 0.85).setFill()
    NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
    color(0xD5DAEA).setStroke()
    NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).stroke()
    text("Primera vez: si macOS dice que no pudo verificarla, pulsa Listo y ve a",
         .systemFont(ofSize: 12), 0x3A3F5C, centerX: width / 2, y: cardTop + 13, maxWidth: card.width - 24)
    text("Ajustes del Sistema › Privacidad y seguridad › Abrir de todos modos",
         .systemFont(ofSize: 12, weight: .semibold), 0x1F2340, centerX: width / 2, y: cardTop + 33, maxWidth: card.width - 24)


    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: args[1])
render(scale: 2, to: args[2])
