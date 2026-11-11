import AppKit

// Finder icon coordinates and this artwork share a 640 × 360 point canvas.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift render-background.swift OUTPUT.png")
}
let width = 640
let height = 360
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
bitmap.size = NSSize(width: width, height: height)
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let appearance = NSAppearance(named: .aqua)!
appearance.performAsCurrentDrawingAppearance {
    // Match NoteTonePalette's light gray surface, with alpha in the PNG.
    let gray = NSColor.textBackgroundColor.blended(withFraction: 0.18, of: .systemGray)!
    gray.withAlphaComponent(0.92).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
}

func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (value as NSString).draw(in: NSRect(x: 24, y: y, width: 592, height: 32), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1),
        .paragraphStyle: style,
    ])
}
text("Install RAMnotes", y: 286, size: 23, weight: .semibold)
text("Drag RAMnotes to Applications", y: 55, size: 17, weight: .regular)

NSColor(calibratedWhite: 0.40, alpha: 1).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 282, y: 190))
arrow.line(to: NSPoint(x: 358, y: 190))
arrow.move(to: NSPoint(x: 345, y: 203))
arrow.line(to: NSPoint(x: 358, y: 190))
arrow.line(to: NSPoint(x: 345, y: 177))
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()

let data = bitmap.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
