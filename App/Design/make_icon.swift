// Renders the sssh app icon into the asset catalog. The PNGs are generated
// rather than drawn in a design tool for the same reason project.yml is
// committed instead of the pbxproj: this file is the reviewable source of
// truth, and the artwork can be regenerated from it at any time:
//
//     swift App/Design/make_icon.swift
//
// Two shapes come out of the same drawing:
// - iOS: one full-bleed 1024px square; the system applies its own mask (and,
//   on iOS 26+, the Liquid Glass treatment) and scales the rest.
// - macOS: the classic style with the 824/1024 rounded plate and drop shadow
//   baked in, rendered natively at every catalog size instead of downscaled,
//   so strokes stay crisp at 16px.
import AppKit

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let appDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconset = appDir
    .appendingPathComponent("Sources/ssshApp/Resources/Assets.xcassets/AppIcon.appiconset")

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: a)
}

func render(canvas: CGFloat, macStyle: Bool, out: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let content: NSRect
    let shape: NSBezierPath
    if macStyle {
        let side = canvas * 824.0 / 1024.0
        content = NSRect(x: (canvas - side) / 2, y: (canvas - side) / 2, width: side, height: side)
        let radius = side * 185.0 / 824.0
        shape = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.30)
        sh.shadowBlurRadius = canvas * 0.022
        sh.shadowOffset = NSSize(width: 0, height: -canvas * 0.010)
        sh.set()
        hex(0x0A121E).setFill()
        shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    } else {
        content = NSRect(x: 0, y: 0, width: canvas, height: canvas)
        shape = NSBezierPath(rect: content)
    }

    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()

    let s = content.width

    // Deep blue-slate gradient, darker at the bottom, with a faint green glow
    // behind the text so the type does not sit on dead black.
    NSGradient(starting: hex(0x0A111C), ending: hex(0x152C44))!
        .draw(in: content, angle: 90)
    NSGradient(colors: [hex(0x2BD87E, 0.16), hex(0x2BD87E, 0.0)])!
        .draw(fromCenter: NSPoint(x: content.midX, y: content.midY), radius: 0,
              toCenter: NSPoint(x: content.midX, y: content.midY), radius: s * 0.55,
              options: [])

    // Terminal traffic lights, top-left.
    let dotR = s * 0.026
    let dotY = content.maxY - s * 0.115
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        hex(UInt32(c), 0.92).setFill()
        let x = content.minX + s * 0.115 + CGFloat(i) * dotR * 3.2
        NSBezierPath(ovalIn: NSRect(x: x - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2)).fill()
    }

    // The name typed at a prompt: "sssh" in mono green plus a block cursor.
    let fontSize = s * 0.215
    let font = NSFont(name: "Menlo-Bold", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let green = hex(0x53E08F)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: green]
    let text = "sssh" as NSString
    let tSize = text.size(withAttributes: attrs)
    let gap = fontSize * 0.12
    let cursorW = fontSize * 0.54
    let total = tSize.width + gap + cursorW
    let x0 = content.midX - total / 2

    // Optically centered: most of the glyph mass sits in the x-height band,
    // so weight the centering toward that rather than the full ascender.
    let bandH = font.ascender * 0.92
    let baseline = content.midY - font.xHeight * 0.72
    text.draw(at: NSPoint(x: x0, y: baseline + font.descender), withAttributes: attrs)

    green.withAlphaComponent(0.88).setFill()
    let cursorRect = NSRect(x: x0 + tSize.width + gap, y: baseline - fontSize * 0.02,
                            width: cursorW, height: bandH + fontSize * 0.02)
    NSBezierPath(roundedRect: cursorRect, xRadius: s * 0.008, yRadius: s * 0.008).fill()

    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    let url = iconset.appendingPathComponent(out)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

render(canvas: 1024, macStyle: false, out: "AppIcon-iOS-1024.png")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    render(canvas: CGFloat(size), macStyle: true, out: "AppIcon-macOS-\(size).png")
}
