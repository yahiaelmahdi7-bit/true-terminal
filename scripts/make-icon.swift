// Renders True's app icon: a white cursive "T" on a transparent background -> Assets/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [font-postscript-name]   (default SnellRoundhand-Black)
// Re-run only to change the icon; package.sh just copies the committed .icns.
import AppKit

let fontName = CommandLine.arguments.dropFirst().first ?? "SnellRoundhand-Black"
guard let font = NSFont(name: fontName, size: 1000) else { fatalError("font not found: \(fontName)") }

// The glyph's outline, so centering uses the real ink bounds rather than line metrics.
var glyph = CGGlyph(0)
var chars = Array("T".utf16)
CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyph, 1)
guard let outline = CTFontCreatePathForGlyph(font as CTFont, glyph, nil) else { fatalError("no outline") }
let ink = outline.boundingBoxOfPath

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let side = CGFloat(px)
    let scale = side * 0.80 / max(ink.width, ink.height)   // the T fills ~80% of the tile
    // Soft shadow so the white T still reads on a light wallpaper behind the Dock.
    ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03,
                  color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.translateBy(x: (side - ink.width * scale) / 2, y: (side - ink.height * scale) / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -ink.minX, y: -ink.minY)
    ctx.addPath(outline)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! render(pt).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! render(pt * 2).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let out = root.appendingPathComponent("Assets/AppIcon.icns")
try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(out.path) (\(fontName))")
