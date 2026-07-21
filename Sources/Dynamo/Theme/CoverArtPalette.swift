import AppKit
import SwiftUI

/// Dominant / accent colors sampled from album artwork for the aurora EQ.
struct CoverArtPalette: Equatable {
    var primary: RGB
    var secondary: RGB
    var accent: RGB
    var deep: RGB
    var highlight: RGB

    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double

        var color: Color {
            Color(red: r, green: g, blue: b)
        }

        var nsColor: NSColor {
            NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
        }

        /// Relative luminance 0…1
        var luminance: Double {
            0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        /// Saturation approximation 0…1
        var saturation: Double {
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            guard maxC > 0.001 else { return 0 }
            return (maxC - minC) / maxC
        }

        func mixed(with other: RGB, t: Double) -> RGB {
            let u = min(1, max(0, t))
            return RGB(
                r: r + (other.r - r) * u,
                g: g + (other.g - g) * u,
                b: b + (other.b - b) * u
            )
        }

        func scaled(brightness: Double) -> RGB {
            RGB(
                r: min(1, max(0, r * brightness)),
                g: min(1, max(0, g * brightness)),
                b: min(1, max(0, b * brightness))
            )
        }

        func boosted(saturation factor: Double = 1.35) -> RGB {
            let lum = luminance
            return RGB(
                r: min(1, max(0, lum + (r - lum) * factor)),
                g: min(1, max(0, lum + (g - lum) * factor)),
                b: min(1, max(0, lum + (b - lum) * factor))
            )
        }
    }

    /// Fallback aurora when no art is available.
    static let auroraFallback = CoverArtPalette(
        primary: RGB(r: 0.20, g: 0.92, b: 0.72),
        secondary: RGB(r: 0.35, g: 0.55, b: 0.98),
        accent: RGB(r: 0.75, g: 0.45, b: 1.00),
        deep: RGB(r: 0.08, g: 0.04, b: 0.22),
        highlight: RGB(r: 0.55, g: 0.95, b: 0.85)
    )

    static func extract(from data: Data?) -> CoverArtPalette {
        guard let data, let image = NSImage(data: data) else {
            return .auroraFallback
        }
        return extract(from: image)
    }

    static func extract(from image: NSImage) -> CoverArtPalette {
        let size = NSSize(width: 32, height: 32)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return .auroraFallback }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        var samples: [RGB] = []
        samples.reserveCapacity(32 * 32)
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                guard a > 0.5 else { continue }
                samples.append(RGB(r: Double(r), g: Double(g), b: Double(b)))
            }
        }
        guard !samples.isEmpty else { return .auroraFallback }

        // Average (primary mass)
        let avg = average(samples)
        // Most saturated vibrant color → accent
        let vibrant = samples.max(by: { $0.saturation * (0.4 + $0.luminance * 0.6) < $1.saturation * (0.4 + $1.luminance * 0.6) })
            ?? avg
        // Darkest for deep wash
        let dark = samples.min(by: { $0.luminance < $1.luminance }) ?? avg
        // Brightest highlight
        let bright = samples.max(by: { $0.luminance < $1.luminance }) ?? avg
        // Secondary: mid-saturation hue offset from avg by picking farthest chromatic sample
        let secondary = samples.max(by: {
            chromaticDistance($0, avg) < chromaticDistance($1, avg)
        }) ?? avg

        return CoverArtPalette(
            primary: vibrant.boosted(saturation: 1.4),
            secondary: secondary.boosted(saturation: 1.25),
            accent: avg.mixed(with: vibrant, t: 0.55).boosted(saturation: 1.3),
            deep: dark.mixed(with: RGB(r: 0.05, g: 0.03, b: 0.12), t: 0.45).scaled(brightness: 0.85),
            highlight: bright.mixed(with: vibrant, t: 0.35).boosted(saturation: 1.1)
        )
    }

    private static func average(_ samples: [RGB]) -> RGB {
        let n = Double(samples.count)
        let r = samples.reduce(0.0) { $0 + $1.r } / n
        let g = samples.reduce(0.0) { $0 + $1.g } / n
        let b = samples.reduce(0.0) { $0 + $1.b } / n
        return RGB(r: r, g: g, b: b)
    }

    private static func chromaticDistance(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return dr * dr + dg * dg + db * db
    }
}
