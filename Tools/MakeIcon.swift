import AppKit
import Foundation

/// Renders the app icon into an .iconset directory. Run by build.sh, which
/// then hands the folder to `iconutil`. Keeping the icon as code means there
/// is no binary asset to lose.
@main
struct MakeIcon {

    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            FileHandle.standardError.write("usage: makeicon <output.iconset>\n".data(using: .utf8)!)
            exit(1)
        }
        let outDir = args[1]

        // The sizes iconutil expects, as (pixels, filename).
        let variants: [(Int, String)] = [
            (16, "icon_16x16.png"),    (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),    (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
        ]

        for (pixels, filename) in variants {
            guard let data = render(pixels: pixels) else { continue }
            let path = outDir + "/" + filename
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func render(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels,
                                         pixelsHigh: pixels,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(side: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// A rounded square in the app's blue, with three stacked bars — the
    /// meter motif the app itself uses. Legible down to 16 pixels.
    private static func draw(side: CGFloat) {
        let inset = side * 0.055
        let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let radius = rect.width * 0.223   // macOS "squircle" proportion

        let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.53, blue: 0.90, alpha: 1),
                                  ending: NSColor(srgbRed: 0.11, green: 0.31, blue: 0.65, alpha: 1))
        gradient?.draw(in: background, angle: -90)

        // Three bars of decreasing width, centred as a group.
        let barHeight = rect.height * 0.108
        let spacing = rect.height * 0.088
        let widths: [CGFloat] = [0.60, 0.44, 0.30]
        let totalHeight = barHeight * 3 + spacing * 2
        let left = rect.minX + rect.width * 0.20
        var y = rect.midY + totalHeight / 2 - barHeight

        NSColor.white.setFill()
        for factor in widths {
            let bar = NSRect(x: left, y: y, width: rect.width * factor, height: barHeight)
            NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            y -= barHeight + spacing
        }

        // A dot on the longest bar reads as a live readout rather than a list.
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55).setFill()
        let dotSize = barHeight * 0.86
        let dot = NSRect(x: left + rect.width * 0.68,
                         y: rect.midY + totalHeight / 2 - barHeight + (barHeight - dotSize) / 2,
                         width: dotSize, height: dotSize)
        NSBezierPath(ovalIn: dot).fill()
    }
}
