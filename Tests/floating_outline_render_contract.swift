import AppKit
import SwiftUI

@main
struct FloatingOutlineRenderContract {
    @MainActor static func main() {
        func render(width: CGFloat) -> (dark: Int, light: Int, clearCorner: Bool) {
            let view = OutlinedLyricTextView()
            view.update(text: "Aa あが", font: .systemFont(ofSize: 40, weight: .bold), fill: .white, outline: .black, width: width, drawOutline: true)
            let size = view.intrinsicContentSize
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            view.draw(CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            var dark = 0, light = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if color.alphaComponent > 0.8 {
                        if color.redComponent < 0.2 { dark += 1 }
                        if color.redComponent > 0.8 { light += 1 }
                    }
                }
            }
            return (dark, light, bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0)
        }
        let plain = render(width: 0)
        let outlined = render(width: 1.25)
        precondition(plain.dark == 0 && plain.light > 50, "Unoutlined glyph fixture must render its fill")
        precondition(outlined.dark > 30 && outlined.light > 50, "Real outlined glyphs must retain fill and produce an opaque stroke")
        precondition(outlined.clearCorner, "Outlined text must retain a transparent background")
        print("floating glyph outline raster contract passed")
    }
}
