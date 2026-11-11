import ramnotesDomain
import AppKit

@MainActor
enum NoteTonePalette {
    /// Resolve translucent system colors against the actual surface, then retain their hue
    /// where possible. Every small text/icon role uses the same 4.5:1 minimum.
    static func readable(_ foreground: NSColor, on background: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                guard let bg = background.usingColorSpace(.sRGB),
                      let fg = foreground.usingColorSpace(.sRGB) else { return }
                let alpha = fg.alphaComponent
                let base = NSColor(srgbRed: fg.redComponent * alpha + bg.redComponent * (1 - alpha),
                                   green: fg.greenComponent * alpha + bg.greenComponent * (1 - alpha),
                                   blue: fg.blueComponent * alpha + bg.blueComponent * (1 - alpha), alpha: 1)
                func luminance(_ color: NSColor) -> CGFloat {
                    func linear(_ value: CGFloat) -> CGFloat {
                        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                    }
                    return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
                }
                let backgroundLight = luminance(bg)
                func ratio(_ color: NSColor) -> CGFloat {
                    let light = luminance(color)
                    return (max(light, backgroundLight) + 0.05) / (min(light, backgroundLight) + 0.05)
                }
                let target = backgroundLight > 0.179 ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                result = base
                for step in 0...100 {
                    let candidate = base.blended(withFraction: CGFloat(step) / 100, of: target)!.usingColorSpace(.sRGB)!
                    if ratio(candidate) >= 4.5 { result = candidate; break }
                }
            }
            return result
        }
    }

    static func swatch(_ tone: NoteBackgroundTone) -> NSColor {
        switch tone {
        case .gray: return .systemGray
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .red: return NSColor(srgbRed: 1, green: 36.0 / 255, blue: 0, alpha: 1)
        case .purple: return .systemPurple
        }
    }
    static func surface(_ tone: NoteBackgroundTone?) -> NSColor {
        guard let tone else { return .textBackgroundColor }
        return NSColor(name: nil) { appearance in
            var result = NSColor.textBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let fraction: CGFloat
                switch tone {
                case .gray: fraction = dark ? 0.30 : 0.18
                case .blue, .green: fraction = dark ? 0.12 : 0.06
                case .red: fraction = dark ? 0.16 : 0.10
                case .purple: fraction = dark ? 0.12 : 0.10
                case .yellow: fraction = dark ? 0.26 : 0.10
                }
                let tint = tone == .yellow && dark
                    ? NSColor(srgbRed: 1, green: 230.0 / 255, blue: 128.0 / 255, alpha: 1)
                    : swatch(tone)
                result = NSColor.textBackgroundColor.blended(withFraction: fraction,
                                                            of: tint) ?? .textBackgroundColor
            }
            return result
        }
    }
    static func image(_ tone: NoteBackgroundTone?) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            if let tone { swatch(tone).setFill(); circle.fill() }
            else {
                NSColor.secondaryLabelColor.setStroke()
                circle.lineWidth = 1
                circle.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3, y: 3))
                slash.line(to: NSPoint(x: 13, y: 13))
                slash.stroke()
            }
            return true
        }
    }
}
