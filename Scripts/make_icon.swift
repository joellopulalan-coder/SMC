// Draws the app icon (1024×1024 PNG): swift make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: centered 824×824 tile with a ~185 px corner radius
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.62, alpha: 1),
    ])!.draw(in: path, angle: 90)

    let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    if let fan = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = fan.size
        fan.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }
    return true
}

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
