#!/usr/bin/env swift
//
// Erzeugt das App-Symbol in allen macOS-Größen.
//
//     swift Tools/GenerateAppIcon.swift
//
// Motiv: ein PortaPack von vorn – Display mit Spektrum und Wasserfall, darüber
// die Antenne, unten rechts ein grünes Abzeichen mit Download-Pfeil für das
// Firmware-Update. Gezeichnet wird auf 1024×1024 nach Apples macOS-Raster
// (Grundfläche 824×824 mit 100 px Rand, Eckradius 185); die kleinen Größen
// entstehen durch Herunterrechnen. macOS legt seit Version 26 eine eigene
// Maske über das Symbol – nichts darf über die Grundfläche hinausragen. macOS-Symbole tragen bewusst einen
// Alphakanal – der transparente Rand gehört zum Raster.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Farbskala des Wasserfalls (wie in der App): schwarz → blau → cyan → gelb → rot.
func waterfallColor(_ t: CGFloat) -> CGColor {
    let stops: [(CGFloat, CGFloat, CGFloat)] = [(0.02, 0.03, 0.10), (0, 0, 0.6), (0, 0.7, 0.9), (0.95, 0.9, 0.1), (0.95, 0.15, 0.1)]
    let s = max(0, min(0.999, t)) * CGFloat(stops.count - 1)
    let i = Int(s), f = s - CGFloat(i)
    let a = stops[i], b = stops[i + 1]
    return rgb(a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
}

/// Pegel eines Kanals: Grundrauschen plus drei Signale (deterministisch).
func level(_ x: CGFloat, _ row: Int) -> CGFloat {
    func peak(_ center: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGFloat {
        height * exp(-pow((x - center) / width, 2))
    }
    let noise = 0.12 + 0.06 * sin(x * 91 + CGFloat(row) * 1.7) * cos(x * 37 - CGFloat(row) * 0.9)
    let burst: CGFloat = (row / 6) % 2 == 0 ? 1 : 0.35
    return noise + peak(0.30, 0.025, 0.75) + peak(0.62, 0.05, 0.5 * burst) + peak(0.80, 0.012, 0.6)
}

func drawMaster() -> CGImage {
    let ctx = makeContext(Int(side))
    // CoreGraphics zählt y von unten; wir zeichnen in Bildkoordinaten.
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)

    // Grundfläche
    let base = CGRect(x: 100, y: 100, width: 824, height: 824)
    let basePath = CGPath(roundedRect: base, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(basePath)
    ctx.setFillColor(rgb(0.10, 0.11, 0.14))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(basePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.20, 0.22, 0.27), rgb(0.07, 0.08, 0.10)], [0, 1]),
                           start: CGPoint(x: 0, y: base.minY), end: CGPoint(x: 0, y: base.maxY), options: [])
    ctx.restoreGState()

    // Antenne (oben rechts), hinter dem Gehäuse
    let antennaX: CGFloat = 690
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(0.70, 0.73, 0.78))
    ctx.setLineWidth(26)
    ctx.move(to: CGPoint(x: antennaX, y: 270))
    ctx.addLine(to: CGPoint(x: antennaX + 50, y: 200))
    ctx.strokePath()
    ctx.setFillColor(rgb(0.80, 0.82, 0.86))
    ctx.fillEllipse(in: CGRect(x: antennaX + 30, y: 178, width: 44, height: 44))
    // Funkwellen
    ctx.setStrokeColor(rgb(0.35, 0.85, 0.95, 0.9))
    ctx.setLineWidth(14)
    // Innerhalb der Grundfläche bleiben: macOS maskiert das Symbol selbst.
    for (i, r) in [CGFloat(48), 80].enumerated() {
        ctx.addArc(center: CGPoint(x: antennaX + 52, y: 200), radius: r, startAngle: -.pi * 0.95, endAngle: -.pi * 0.55, clockwise: false)
        ctx.setAlpha(i == 0 ? 0.95 : 0.6)
        ctx.strokePath()
    }
    ctx.setAlpha(1)

    // Gehäuse des PortaPack
    let body = CGRect(x: 250, y: 250, width: 524, height: 600)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 56, cornerHeight: 56, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0, 0, 0, 0.5))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0.16, 0.17, 0.20))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.30, 0.32, 0.37), rgb(0.15, 0.16, 0.19)], [0, 1]),
                           start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    ctx.restoreGState()
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.12))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Display
    let screen = CGRect(x: 292, y: 292, width: 440, height: 420)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    ctx.setFillColor(rgb(0.02, 0.03, 0.06))
    ctx.fill(screen)

    // Wasserfall (untere 55 %)
    let wfTop = screen.minY + screen.height * 0.45
    let rows = 22
    let columns = 44
    let cellW = screen.width / CGFloat(columns)
    let cellH = (screen.maxY - wfTop) / CGFloat(rows)
    for row in 0..<rows {
        for column in 0..<columns {
            let x = (CGFloat(column) + 0.5) / CGFloat(columns)
            ctx.setFillColor(waterfallColor(level(x, row)))
            ctx.fill(CGRect(x: screen.minX + CGFloat(column) * cellW, y: wfTop + CGFloat(row) * cellH,
                            width: cellW + 0.5, height: cellH + 0.5))
        }
    }

    // Spektrum (obere 45 %)
    let specBottom = wfTop - 10
    let specHeight = specBottom - screen.minY - 24
    ctx.setStrokeColor(rgb(1, 1, 1, 0.08))
    ctx.setLineWidth(2)
    for i in 1...3 {
        let y = screen.minY + 24 + specHeight * CGFloat(i) / 4
        ctx.move(to: CGPoint(x: screen.minX, y: y))
        ctx.addLine(to: CGPoint(x: screen.maxX, y: y))
    }
    ctx.strokePath()
    let line = CGMutablePath()
    let steps = 160
    for i in 0...steps {
        let x = CGFloat(i) / CGFloat(steps)
        let y = specBottom - min(1, level(x, 0)) * specHeight
        let point = CGPoint(x: screen.minX + x * screen.width, y: y)
        i == 0 ? line.move(to: point) : line.addLine(to: point)
    }
    let fill = line.mutableCopy()!
    fill.addLine(to: CGPoint(x: screen.maxX, y: specBottom))
    fill.addLine(to: CGPoint(x: screen.minX, y: specBottom))
    fill.closeSubpath()
    ctx.saveGState()
    ctx.addPath(fill)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.2, 0.85, 1, 0.45), rgb(0.2, 0.85, 1, 0.02)], [0, 1]),
                           start: CGPoint(x: 0, y: screen.minY + 24), end: CGPoint(x: 0, y: specBottom), options: [])
    ctx.restoreGState()
    ctx.addPath(line)
    ctx.setStrokeColor(rgb(0.35, 0.92, 1))
    ctx.setLineWidth(7)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(screenPath)
    ctx.setStrokeColor(rgb(0, 0, 0, 0.6))
    ctx.setLineWidth(6)
    ctx.strokePath()

    // Drehgeber und Tasten
    let knob = CGPoint(x: 512, y: 782)
    ctx.setFillColor(rgb(0.09, 0.10, 0.12))
    ctx.fillEllipse(in: CGRect(x: knob.x - 46, y: knob.y - 46, width: 92, height: 92))
    ctx.setStrokeColor(rgb(0.55, 0.58, 0.64))
    ctx.setLineWidth(8)
    ctx.strokeEllipse(in: CGRect(x: knob.x - 46, y: knob.y - 46, width: 92, height: 92))
    ctx.setFillColor(rgb(0.55, 0.58, 0.64))
    for dx in [CGFloat(-150), 150] {
        ctx.fillEllipse(in: CGRect(x: knob.x + dx - 20, y: knob.y - 20, width: 40, height: 40))
    }

    // Update-Abzeichen
    let badgeCenter = CGPoint(x: 744, y: 740)
    let badgeRadius: CGFloat = 132
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0, 0, 0, 0.45))
    ctx.setFillColor(rgb(0.10, 0.11, 0.14))
    ctx.fillEllipse(in: CGRect(x: badgeCenter.x - badgeRadius - 14, y: badgeCenter.y - badgeRadius - 14,
                               width: (badgeRadius + 14) * 2, height: (badgeRadius + 14) * 2))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius, width: badgeRadius * 2, height: badgeRadius * 2))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.35, 0.88, 0.50), rgb(0.12, 0.62, 0.32)], [0, 1]),
                           start: CGPoint(x: 0, y: badgeCenter.y - badgeRadius), end: CGPoint(x: 0, y: badgeCenter.y + badgeRadius), options: [])
    ctx.restoreGState()
    // Pfeil nach unten mit Ablage
    ctx.setStrokeColor(rgb(1, 1, 1))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(30)
    ctx.move(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y - 72))
    ctx.addLine(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y + 30))
    ctx.move(to: CGPoint(x: badgeCenter.x - 50, y: badgeCenter.y - 18))
    ctx.addLine(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y + 32))
    ctx.addLine(to: CGPoint(x: badgeCenter.x + 50, y: badgeCenter.y - 18))
    ctx.move(to: CGPoint(x: badgeCenter.x - 62, y: badgeCenter.y + 76))
    ctx.addLine(to: CGPoint(x: badgeCenter.x + 62, y: badgeCenter.y + 76))
    ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, size: Int, to url: URL) {
    let ctx = makeContext(size)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("PortaPackManager/Resources/Assets.xcassets/AppIcon.appiconset")
let master = drawMaster()

var images: [String] = []
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        write(master, size: point * scale, to: iconset.appendingPathComponent(name))
        images.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(point)x\(point)" }
        """)
    }
}
let contents = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! contents.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Symbol geschrieben nach \(iconset.path)")
