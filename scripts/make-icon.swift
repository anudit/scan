// Resizes a transparent, already-shaped square icon source without adding a
// second squircle, drop shadow, or background around the artwork.
// Usage: swift scripts/make-icon.swift App/AppIcon.png
import AppKit

let args = CommandLine.arguments
guard args.count == 2, let source = NSImage(contentsOfFile: args[1]),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("usage: swift scripts/make-icon.swift <square-image>") }

func render(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(sourceCG, in: CGRect(x:0,y:0,width:size,height:size))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let appIconSet = "App/Assets.xcassets/AppIcon.appiconset"
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let data = render(size: base * scale)
        try data.write(to: URL(fileURLWithPath: "\(appIconSet)/icon_\(base)x\(base)_\(scale)x.png"))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try data.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    }
}

// Assemble the PNG-backed ICNS records directly. iconutil on macOS 27 currently
// rejects otherwise valid freshly rendered iconsets.
var chunks = Data()
let records: [(String, String)] = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]
for (kind, name) in records {
    let png = try Data(contentsOf: URL(fileURLWithPath: "\(iconset)/\(name)"))
    chunks.append(contentsOf: kind.utf8)
    var length = UInt32(png.count + 8).bigEndian
    withUnsafeBytes(of: &length) { chunks.append(contentsOf: $0) }
    chunks.append(png)
}
var icns = Data("icns".utf8)
var totalLength = UInt32(chunks.count + 8).bigEndian
withUnsafeBytes(of: &totalLength) { icns.append(contentsOf: $0) }
icns.append(chunks)
try icns.write(to: URL(fileURLWithPath: "App/AppIcon.icns"))
print("Wrote \(appIconSet) and App/AppIcon.icns")
