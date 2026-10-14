// Draws the app icon: a window split into three panes (navigation | files | details) on a
// blue rounded square, following the macOS icon grid (824 pt plate on a 1024 pt canvas).
//
//   swift scripts/make-icon.swift <out.icns>        the icon, every size, via iconutil
//   swift scripts/make-icon.swift <out.png> [size]  one PNG (default 1024), for a preview
import AppKit

/// Coordinates are in a 1024-pt canvas, top-left origin.
func drawIcon(in context: CGContext, size: CGFloat) {
    context.saveGState()
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: size / 1024, y: -size / 1024)

    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    func fill(_ rect: CGRect, _ radius: CGFloat, _ fillColor: CGColor) {
        context.addPath(rounded(rect, radius))
        context.setFillColor(fillColor)
        context.fillPath()
    }
    func verticalGradient(_ path: CGPath, top: CGColor, bottom: CGColor) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        let box = path.boundingBox
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.minY),
                                   end: CGPoint(x: box.midX, y: box.maxY), options: [])
        context.restoreGState()
    }

    // Plate, with the soft shadow macOS icons sit on.
    let plate = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.3))
    context.addPath(plate)
    context.setFillColor(color(0x1A73D9))
    context.fillPath()
    context.restoreGState()
    verticalGradient(plate, top: color(0x3D9BF0), bottom: color(0x0B5CC0))

    // The window.
    let window = CGRect(x: 172, y: 236, width: 680, height: 560)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x062F66, 0.45))
    fill(window, 44, color(0xFFFFFF))
    context.restoreGState()
    context.saveGState()
    context.addPath(rounded(window, 44))
    context.clip()

    // Title strip: window buttons and one selected tab.
    let strip: CGFloat = 88
    context.setFillColor(color(0xDCE7F5))
    context.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: strip))
    for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        context.setFillColor(color(hex))
        context.fillEllipse(in: CGRect(x: window.minX + 30 + CGFloat(index) * 34, y: window.minY + 31, width: 24, height: 24))
    }
    fill(CGRect(x: window.minX + 150, y: window.minY + 26, width: 220, height: strip), 18, color(0xF1F5FA))
    fill(CGRect(x: window.minX + 176, y: window.minY + 50, width: 26, height: 22), 5, color(0x3D8FE8))
    fill(CGRect(x: window.minX + 216, y: window.minY + 54, width: 110, height: 14), 7, color(0xA9B8CC))

    // Body: three panes on a light grey ground.
    let body = CGRect(x: window.minX, y: window.minY + strip, width: window.width, height: window.height - strip)
    context.setFillColor(color(0xF1F5FA))
    context.fill(body)
    let top = body.minY + 20, height = body.height - 40
    let nav = CGRect(x: window.minX + 20, y: top, width: 150, height: height)
    let files = CGRect(x: nav.maxX + 14, y: top, width: 300, height: height)
    let details = CGRect(x: files.maxX + 14, y: top, width: window.maxX - 20 - files.maxX - 14, height: height)
    for pane in [nav, files, details] { fill(pane, 18, color(0xFFFFFF)) }

    // Navigation pane: icon + label rows, one selected.
    for row in 0..<6 {
        let y = nav.minY + 26 + CGFloat(row) * 62
        if row == 1 { fill(CGRect(x: nav.minX + 10, y: y - 12, width: nav.width - 20, height: 46), 10, color(0xCCE4FA)) }
        fill(CGRect(x: nav.minX + 22, y: y, width: 22, height: 22), 5, color(row == 1 ? 0x1A73D9 : 0x8FB4E0))
        fill(CGRect(x: nav.minX + 54, y: y + 4, width: row % 2 == 0 ? 70 : 56, height: 14), 7, color(0xC3CEDC))
    }

    // Files: folder rows, one selected.
    for row in 0..<6 {
        let y = files.minY + 26 + CGFloat(row) * 62
        if row == 2 { fill(CGRect(x: files.minX + 10, y: y - 12, width: files.width - 20, height: 46), 10, color(0xCCE4FA)) }
        // A folder: tab and body.
        fill(CGRect(x: files.minX + 24, y: y - 2, width: 16, height: 10), 3, color(0x2F86E3))
        fill(CGRect(x: files.minX + 24, y: y + 3, width: 34, height: 22), 5, color(0x4C9EEC))
        fill(CGRect(x: files.minX + 72, y: y + 6, width: [140, 112, 128, 96, 136, 106][row], height: 14), 7,
             color(0xC3CEDC))
        fill(CGRect(x: files.maxX - 64, y: y + 6, width: 40, height: 14), 7, color(0xDFE5EE))
    }

    // Details: a picture preview and a few lines.
    let preview = CGRect(x: details.minX + 18, y: details.minY + 20, width: details.width - 36, height: 150)
    let previewPath = rounded(preview, 12)
    verticalGradient(previewPath, top: color(0x7CC4FA), bottom: color(0x2E8BE6))
    context.saveGState()
    context.addPath(previewPath)
    context.clip()
    let hills = CGMutablePath()
    hills.move(to: CGPoint(x: preview.minX, y: preview.maxY))
    hills.addLine(to: CGPoint(x: preview.minX + 46, y: preview.maxY - 66))
    hills.addLine(to: CGPoint(x: preview.minX + 80, y: preview.maxY - 34))
    hills.addLine(to: CGPoint(x: preview.minX + 104, y: preview.maxY - 56))
    hills.addLine(to: CGPoint(x: preview.maxX, y: preview.maxY))
    hills.closeSubpath()
    context.addPath(hills)
    context.setFillColor(color(0x0B5CC0))
    context.fillPath()
    context.setFillColor(color(0xFFFFFF, 0.9))
    context.fillEllipse(in: CGRect(x: preview.maxX - 46, y: preview.minY + 20, width: 26, height: 26))
    context.restoreGState()
    for (index, width) in [CGFloat(100), 80, 110, 64].enumerated() {
        fill(CGRect(x: details.minX + 18, y: preview.maxY + 30 + CGFloat(index) * 40, width: width, height: 14), 7,
             color(index == 0 ? 0xA9B8CC : 0xDFE5EE))
    }

    context.restoreGState() // window clip
    context.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    drawIcon(in: graphics.cgContext, size: CGFloat(size))
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.icns | out.png [size]>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

if output.pathExtension == "png" {
    try png(size: arguments.count > 2 ? Int(arguments[2])! : 1024).write(to: output)
    exit(0)
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
