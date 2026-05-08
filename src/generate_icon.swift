import AppKit
import Foundation

// MARK: - Drawing

func pt(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> NSPoint { NSPoint(x: x*s, y: y*s) }

func drawIcon(size: Int) -> NSImage {
    let sz = CGFloat(size)
    let s  = sz / 512          // all design coords are in 512-pt space, y-up

    let image = NSImage(size: NSSize(width: sz, height: sz))
    image.lockFocus()

    // ── Background ────────────────────────────────────────────────────────────
    // Apple-style squircle: corner ≈ 22% of width
    let bg = NSRect(x: 0, y: 0, width: sz, height: sz)
    NSBezierPath(roundedRect: bg, xRadius: 112*s, yRadius: 112*s).addClip()

    // Two-stop gradient, top-left → bottom-right
    let hi  = NSColor(srgbRed: 0.196, green: 0.588, blue: 1.000, alpha: 1)  // #3296FF
    let lo  = NSColor(srgbRed: 0.000, green: 0.329, blue: 0.800, alpha: 1)  // #0054CC
    NSGradient(starting: hi, ending: lo)!.draw(in: bg, angle: -65)

    // ── Speaker body (white) ──────────────────────────────────────────────────
    // Design in 512-pt space, centred at (256, 256), y-up:
    //   Box  : x 106–169, y 218–294   (63 × 76 pt)
    //   Cone : expands from box mouth to x 252, y 172–340  (mouth height 168)
    NSColor.white.setFill()
    NSColor.white.setStroke()

    let body = NSBezierPath()
    body.move(to:  pt(106, 294, s))  // box top-left
    body.line(to:  pt(169, 294, s))  // box top-right
    body.line(to:  pt(252, 340, s))  // cone top-right (mouth)
    body.line(to:  pt(252, 172, s))  // cone bottom-right (mouth)
    body.line(to:  pt(169, 218, s))  // box bottom-right
    body.line(to:  pt(106, 218, s))  // box bottom-left
    body.close()
    body.fill()

    // ── Sound waves ───────────────────────────────────────────────────────────
    // Arcs centred at the cone mouth (252, 256), curving to the right.
    // In y-up coords: startAngle -span → endAngle +span CCW = right-side arc (")").
    let wc = pt(252, 256, s)

    struct Wave { let radius, width, span: CGFloat }
    for w in [Wave(radius: 62, width: 22, span: 37),
              Wave(radius: 98, width: 17, span: 43),
              Wave(radius:134, width: 13, span: 48)] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: wc, radius: w.radius * s,
                      startAngle: -w.span, endAngle: w.span, clockwise: false)
        arc.lineWidth    = w.width * s
        arc.lineCapStyle = .round
        arc.stroke()
    }

    image.unlockFocus()
    return image
}

// MARK: - Export

func savePNG(_ image: NSImage, to path: String) {
    var rect = NSRect(origin: .zero, size: image.size)
    guard let cg   = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
          let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    else { fputs("error: cannot write \(path)\n", stderr); return }
    try! data.write(to: URL(fileURLWithPath: path))
}

// MARK: - Main

let out      = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_gen"
let iconset  = "\(out)/AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (name, size): (String, Int) in [
    ("icon_16x16.png",        16), ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",        32), ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",     128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",     256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",     512), ("icon_512x512@2x.png",1024),
] {
    savePNG(drawIcon(size: size), to: "\(iconset)/\(name)")
    print("  \(name)")
}
print("✓ \(iconset)")
