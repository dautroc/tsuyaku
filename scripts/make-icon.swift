#!/usr/bin/env swift
//
// Generate the app icon and the menu bar template icon from code.
//
// Why code and not a design file: the repo builds with Command Line Tools
// only -- no Xcode, so no asset catalog, no `actool`. A .icns has to be
// assembled by hand from an .iconset anyway (`iconutil`), so the art may as
// well be reproducible rather than a binary someone has to open Sketch to
// change. Re-run with `make icon` after editing the constants below.
//
// Output:
//   Resources/AppIcon.icns                 -- Finder / Dock / System Settings
//   Resources/MenuBarIconTemplate.pdf      -- the status item, vector so it
//                                             tracks any menu bar height, and
//                                             `Template` in the name makes
//                                             AppKit tint it for light/dark.
//
import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette
//
// Indigo-to-violet: dark enough that the white bubble carries the shape at
// 16px, saturated enough not to read as "system utility grey". The bar colours
// are the two subtitle lines -- vermilion for the Japanese the app hears,
// slate for the English it writes.

let topColor    = CGColor(red: 0.42, green: 0.36, blue: 0.97, alpha: 1)
let bottomColor = CGColor(red: 0.15, green: 0.12, blue: 0.56, alpha: 1)
let bubbleColor = CGColor(red: 0.98, green: 0.98, blue: 1.00, alpha: 1)
let sourceBar   = CGColor(red: 1.00, green: 0.42, blue: 0.35, alpha: 1)   // ja
let targetBar   = CGColor(red: 0.24, green: 0.23, blue: 0.44, alpha: 1)   // en

// MARK: - Geometry helpers

/// A superellipse, i.e. the continuous-curvature corner macOS uses. A plain
/// `CGPath(roundedRect:)` is circular-cornered and reads as visibly "wrong"
/// next to every other icon in the Dock.
func squircle(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let a = rect.width / 2, b = rect.height / 2
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = rect.midY + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - App icon

/// Draws the icon into a context whose user space is `side` x `side` points.
/// All literals are in the 1024 grid and scaled, so one set of numbers drives
/// every size.
func drawAppIcon(into ctx: CGContext, side: CGFloat) {
    let u = side / 1024
    func s(_ v: CGFloat) -> CGFloat { v * u }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: s(x), y: s(y), width: s(w), height: s(h))
    }

    // Three tiers, because a linear scale of one drawing does not survive the
    // trip down to 16px: the tail becomes three grey pixels and the two bars
    // merge into one smudge. `tiny` and `small` trade the tail away and spend
    // the pixels on bar thickness and on the gap between the bars, which is
    // the feature that says "subtitles" rather than "a blob".
    let tiny  = side <= 16
    let small = side <= 32

    // Rounded-square plate on the 824/1024 macOS grid.
    let plate = r(100, 100, 824, 824)
    let shape = squircle(in: plate)

    ctx.saveGState()
    // A sub-pixel shadow at 16px only muddies the silhouette, so the small
    // variants go without one.
    if !small {
        ctx.setShadow(offset: CGSize(width: 0, height: s(-10)), blur: s(24),
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    }
    ctx.addPath(shape)
    ctx.setFillColor(bottomColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [topColor, bottomColor] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: plate.midX, y: plate.maxY),
                               end: CGPoint(x: plate.midX, y: plate.minY),
                               options: [])
    }
    // Sheen along the top edge; keeps the plate from looking like flat vinyl.
    if let sheen = CGGradient(colorsSpace: space,
                              colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
                                       CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                              locations: [0, 1]) {
        ctx.drawLinearGradient(sheen,
                               start: CGPoint(x: plate.midX, y: plate.maxY),
                               end: CGPoint(x: plate.midX, y: plate.midY + s(60)),
                               options: [])
    }
    ctx.restoreGState()

    // Speech bubble: body plus tail, unioned so the seam never shows through
    // the shadow or an antialiased edge.
    let body: CGRect
    let radius: CGFloat
    let bars: [(CGPath, CGColor)]
    if tiny {
        body = r(210, 290, 604, 444)
        radius = s(104)
        bars = [(rounded(r(280, 556, 460, 104), s(52)), sourceBar),
                (rounded(r(280, 372, 300, 104), s(52)), targetBar)]
    } else if small {
        body = r(230, 320, 564, 396)
        radius = s(100)
        bars = [(rounded(r(296, 560, 432, 76), s(38)), sourceBar),
                (rounded(r(296, 404, 288, 76), s(38)), targetBar)]
    } else {
        body = r(214, 300, 596, 400)
        radius = s(96)
        bars = [(rounded(r(282, 530, 460, 64), s(32)), sourceBar),
                (rounded(r(282, 406, 316, 64), s(32)), targetBar)]
    }

    var bubble = rounded(body, radius)
    if !small {
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: s(306), y: s(340)))
        tail.addLine(to: CGPoint(x: s(276), y: s(220)))
        tail.addLine(to: CGPoint(x: s(452), y: s(340)))
        tail.closeSubpath()
        bubble = bubble.union(tail)
    }

    ctx.saveGState()
    if !small {
        ctx.setShadow(offset: CGSize(width: 0, height: s(-8)), blur: s(20),
                      color: CGColor(red: 0.05, green: 0.02, blue: 0.20, alpha: 0.35))
    }
    ctx.addPath(bubble)
    ctx.setFillColor(bubbleColor)
    ctx.fillPath()
    ctx.restoreGState()

    for (bar, color) in bars {
        ctx.addPath(bar)
        ctx.setFillColor(color)
        ctx.fillPath()
    }
}

func writePNG(side: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw Failure("could not create a \(side)px bitmap context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawAppIcon(into: ctx, side: CGFloat(side))

    guard let image = ctx.makeImage() else { throw Failure("makeImage failed at \(side)px") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: side, height: side)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw Failure("PNG encode failed at \(side)px")
    }
    try data.write(to: url)
}

// MARK: - Menu bar template

/// The status item mark: a filled bubble with the two subtitle lines knocked
/// out of it. Template images carry alpha only -- AppKit paints them black on
/// a light menu bar and white on a dark one -- so the holes are punched with
/// an even-odd fill rather than drawn in a second colour.
func writeMenuBarPDF(to url: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 18, height: 18)
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
        throw Failure("could not open a PDF context at \(url.path)")
    }
    ctx.beginPDFPage(nil)

    let body = CGRect(x: 1.1, y: 4.9, width: 15.8, height: 10.4)
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 5.2, y: 6.2))
    tail.addLine(to: CGPoint(x: 4.3, y: 1.9))
    tail.addLine(to: CGPoint(x: 9.2, y: 6.2))
    tail.closeSubpath()

    let mark = CGMutablePath()
    mark.addPath(rounded(body, 3.1).union(tail))
    mark.addPath(rounded(CGRect(x: 4.0, y: 11.0, width: 10.0, height: 1.7), 0.85))
    mark.addPath(rounded(CGRect(x: 4.0, y: 7.5, width: 6.6, height: 1.7), 0.85))

    ctx.addPath(mark)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fillPath(using: .evenOdd)

    ctx.endPDFPage()
    ctx.closePDF()
}

// MARK: - Driver

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
               ? CommandLine.arguments[1]
               : FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// The ten entries `iconutil` expects. Anything missing and Finder silently
// falls back to the generic document icon at that size.
let variants: [(name: String, side: Int)] = [
    ("icon_16x16.png", 16),     ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),     ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),  ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),  ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),  ("icon_512x512@2x.png", 1024),
]

do {
    for v in variants {
        try writePNG(side: v.side, to: iconset.appendingPathComponent(v.name))
    }

    let icns = resources.appendingPathComponent("AppIcon.icns")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { throw Failure("iconutil exited \(proc.terminationStatus)") }

    try writeMenuBarPDF(to: resources.appendingPathComponent("MenuBarIconTemplate.pdf"))

    // The .iconset is an intermediate; the .icns is what ships.
    try? fm.removeItem(at: iconset)

    print("==> Resources/AppIcon.icns")
    print("==> Resources/MenuBarIconTemplate.pdf")
} catch {
    FileHandle.standardError.write("make-icon failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
