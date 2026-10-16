import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func icon(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let rect = NSRect(x: 42, y: 42, width: 940, height: 940)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 214, yRadius: 214)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2); shadow.shadowBlurRadius = 25; shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.17, alpha: 1).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.24, alpha: 1), NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)])!.draw(in: shape, angle: -70)
    NSColor.white.withAlphaComponent(0.12).setStroke(); shape.lineWidth = 2; shape.stroke()
    let heights: [CGFloat] = [200, 374, 510, 296]
    let left: CGFloat = 270
    for (index, height) in heights.enumerated() {
        let bar = NSBezierPath(roundedRect: NSRect(x: left + CGFloat(index) * 126, y: (1024 - height) / 2, width: 84, height: height), xRadius: 42, yRadius: 42)
        NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.71, blue: 0.44, alpha: 1), NSColor(calibratedRed: 0.98, green: 0.34, blue: 0.24, alpha: 1)])!.draw(in: bar, angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try icon(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
