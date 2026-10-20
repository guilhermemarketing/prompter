// Gera o iconset do Prompter: squircle escuro, linhas de texto e ponto de gravação.
// Uso: swift Scripts/make-icon.swift <pasta.iconset>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let variants: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(calibratedWhite: 0.22, alpha: 1),
               ending: NSColor(calibratedWhite: 0.05, alpha: 1))!.draw(in: squircle, angle: -90)

    // Linhas do roteiro: a do meio é a linha de leitura.
    let lineH = body.height * 0.075
    let left = body.minX + body.width * 0.2
    var top = body.maxY - body.height * 0.25
    for (width, alpha) in [(0.58, 0.32), (0.5, 1.0), (0.6, 0.55)] as [(CGFloat, CGFloat)] {
        let rect = NSRect(x: left, y: top - lineH, width: body.width * width, height: lineH)
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: lineH / 2, yRadius: lineH / 2).fill()
        top -= lineH * 2
    }

    let d = body.width * 0.2
    let dot = NSRect(x: body.maxX - body.width * 0.18 - d, y: body.minY + body.height * 0.15, width: d, height: d)
    NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (px, name) in variants {
    try! render(px).write(to: outDir.appendingPathComponent("icon_\(name).png"))
}
