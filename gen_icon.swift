import Foundation
import AppKit
import CoreGraphics

/// Render one frame of the Wand icon at the given pixel size.
/// Design: silver squircle with a dark Siri Remote silhouette — a tall rounded body, the
/// trackpad punched out as a circle near the top, and two small button dots below (even-odd
/// fill, so the cutouts show the silver background through them).
func renderIcon(size: CGFloat) -> Data? {
    let w = Int(size), h = Int(size)
    let space = CGColorSpaceCreateDeviceRGB()
    let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: space, bitmapInfo: bitmap.rawValue
    ) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225  // macOS Big Sur+ squircle ratio

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    ctx.clip()

    // Silver-grey background (echoes the aluminium Siri Remote).
    ctx.setFillColor(CGColor(red: 0.80, green: 0.80, blue: 0.84, alpha: 1))
    ctx.fill(rect)

    // Dark Siri Remote silhouette. Body + trackpad/button cutouts as one even-odd path, so the
    // holes reveal the silver behind them (trackpad and buttons read as light on dark).
    let dark = CGColor(red: 0x2b/255, green: 0x2b/255, blue: 0x30/255, alpha: 1)
    let body = CGRect(x: 0.37 * size, y: 0.13 * size, width: 0.26 * size, height: 0.74 * size)
    let padR: CGFloat = 0.095 * size
    let trackpad = CGRect(x: 0.5 * size - padR, y: 0.66 * size - padR, width: 2 * padR, height: 2 * padR)
    let btnR: CGFloat = 0.028 * size
    let btnTop = CGRect(x: 0.5 * size - btnR, y: 0.40 * size - btnR, width: 2 * btnR, height: 2 * btnR)
    let btnBot = CGRect(x: 0.5 * size - btnR, y: 0.29 * size - btnR, width: 2 * btnR, height: 2 * btnR)

    let remote = CGMutablePath()
    remote.addPath(CGPath(roundedRect: body, cornerWidth: 0.11 * size, cornerHeight: 0.11 * size, transform: nil))
    remote.addEllipse(in: trackpad)
    remote.addEllipse(in: btnTop)
    remote.addEllipse(in: btnBot)

    ctx.setFillColor(dark)
    ctx.addPath(remote)
    ctx.fillPath(using: .evenOdd)

    ctx.restoreGState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

// Standard macOS iconset sizes
let frames: [(name: String, px: Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png",1024),
]

let outDir = URL(fileURLWithPath: "Wand.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for frame in frames {
    guard let data = renderIcon(size: CGFloat(frame.px)) else {
        print("Failed to render \(frame.name)")
        continue
    }
    try data.write(to: outDir.appendingPathComponent(frame.name))
}
print("Wrote \(frames.count) frames to Wand.iconset/")
