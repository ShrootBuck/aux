import AppKit

// Match dmg-settings.py's 640 x 320 Finder content area and icon centers.
// Store both resolutions so the fine arrow stays crisp on Retina displays.
let size = NSSize(width: 640, height: 320)
let representations = [1, 2].map { scale -> NSBitmapImageRep in
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 640 * scale, pixelsHigh: 320 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 640 * scale * 4, bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(scale))
    transform.concat()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()

    // Finder's y axis starts at the top; AppKit's starts at the bottom.
    let centerY = size.height - 150
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 296, y: centerY))
    arrow.line(to: NSPoint(x: 344, y: centerY))
    arrow.move(to: NSPoint(x: 334, y: centerY + 10))
    arrow.line(to: NSPoint(x: 344, y: centerY))
    arrow.line(to: NSPoint(x: 334, y: centerY - 10))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(calibratedWhite: 0.65, alpha: 1).setStroke()
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = size
    return bitmap
}
let image = NSImage(size: size)
representations.forEach { image.addRepresentation($0) }
let data = image.tiffRepresentation!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
