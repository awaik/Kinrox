// Splits one exported Figma row (8 × 1320 × 2868, from Scripts/app-store/figma-localize-screenshots.js)
// into App Store upload PNGs: opaque RGB at 1320 × 2868 and 1206 × 2622, plus a small
// contact sheet for review.
// Usage: swift Scripts/app-store/split-screenshots.swift <row.png> <export-dir> <locale>
import AppKit
import Foundation

let names = [
    "lock-screen", "video-remote", "music", "similar", "queue", "mac-player", "pairing", "matrix",
]
let sizes = [(1320, 2868), (1206, 2622)]
let args = CommandLine.arguments
guard args.count == 4 else {
    fatalError("Usage: split-screenshots.swift <row.png> <export-dir> <locale>")
}
let row = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
guard let row, row.width == 1320 * names.count, row.height == 2868 else {
    fatalError("Expected a \(1320 * names.count) × 2868 PNG: \(args[1])")
}
let export = URL(fileURLWithPath: args[2]).appendingPathComponent(args[3])
let fm = FileManager.default

func opaque(_ image: CGImage, width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try data.write(to: url, options: .withoutOverwriting)
}

for (width, height) in sizes {
    try fm.createDirectory(
        at: export.appendingPathComponent("\(width)x\(height)"), withIntermediateDirectories: true)
}
for (index, name) in names.enumerated() {
    let frame = row.cropping(to: CGRect(x: index * 1320, y: 0, width: 1320, height: 2868))!
    for (width, height) in sizes {
        let file = String(format: "%02d-%@.png", index + 1, name)
        try write(
            opaque(frame, width: width, height: height),
            to: export.appendingPathComponent("\(width)x\(height)/\(file)"))
    }
}
// Review sheet: the whole row at 1/5 scale.
try write(
    opaque(row, width: row.width / 5, height: row.height / 5),
    to: export.appendingPathComponent("contact-sheet.png"))
print("Split \(args[3]) into \(names.count * sizes.count) PNGs")
