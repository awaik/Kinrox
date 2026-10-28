#!/usr/bin/env swift
import AppKit
import Foundation

// Layout mirrors the editable master on Figma page 23:304. Core Text via AppKit
// shapes Arabic, Hebrew, Indic and CJK text using native font fallback.
struct Copy: Decodable {
    let screenshots: [[String]]
    let requirement: String
}
struct Manifest: Decodable { let locales: [String: String] }
struct Metric: Codable {
    let locale: String
    let screenshot: Int
    let kind: String
    let fontSize: Double
    let height: Double
}
let args = CommandLine.arguments
if args.count < 4 {
    fatalError(
        "Usage: swift Scripts/render-app-store.swift <raw-directory> <output-directory> <project-root> [locale]"
    )
}
let raw = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let root = URL(fileURLWithPath: args[3])
let fm = FileManager.default
try fm.createDirectory(at: output, withIntermediateDirectories: false)
let decoder = JSONDecoder()
let manifest = try decoder.decode(
    Manifest.self, from: Data(contentsOf: root.appendingPathComponent("AppStore/manifest.json")))
let prepared = try decoder.decode(
    [String: Copy].self,
    from: Data(contentsOf: root.appendingPathComponent("AppStore/localized-copy.json")))
var locales = manifest.locales
locales["fa"] = "fa"
if args.count > 4 { locales = locales.filter { $0.key == args[4] } }
let bg = NSColor(srgbRed: 14 / 255, green: 12 / 255, blue: 11 / 255, alpha: 1)
let primary = NSColor(srgbRed: 247 / 255, green: 239 / 255, blue: 228 / 255, alpha: 1)
let secondary = NSColor(srgbRed: 163 / 255, green: 157 / 255, blue: 150 / 255, alpha: 1)
let ember = NSColor(srgbRed: 1, green: 90 / 255, blue: 31 / 255, alpha: 1)
var metrics: [Metric] = []
@MainActor
func text(
    _ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight,
    color: NSColor, rtl: Bool = false, expanded: Bool = false, locale: String,
    shot: Int, kind: String
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = rtl ? .right : .left
    paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
    paragraph.lineBreakMode = .byWordWrapping
    var current = size
    var bounds = NSRect.zero
    var attributed = NSAttributedString()
    while current >= 22 {
        var font = NSFont.systemFont(ofSize: current, weight: weight)
        if expanded {
            let descriptor = font.fontDescriptor.addingAttributes([
                .traits: [NSFontDescriptor.TraitKey.width: 0.3]
            ])
            font = NSFont(descriptor: descriptor, size: current) ?? font
        }
        paragraph.lineSpacing = current * 0.02
        attributed = NSAttributedString(
            string: value,
            attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ])
        bounds = attributed.boundingRect(
            with: NSSize(width: rect.width, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        if ceil(bounds.height) <= rect.height { break }
        current -= 2
    }
    precondition(bounds.height <= rect.height, "Text overflow: \(locale) \(shot) \(kind)")
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    metrics.append(
        Metric(
            locale: locale, screenshot: shot, kind: kind,
            fontSize: Double(current), height: Double(bounds.height)))
}
for (locale, lang) in locales.sorted(by: { $0.key < $1.key }) {
    guard let copy = prepared[locale] else {
        fatalError("Missing prepared copy for \(locale); run Scripts/prepare-app-store.py")
    }
    let rtl = ["ar", "he", "fa", "ur"].contains(lang)
    for (width, height) in [(1320, 2868), (1206, 2622)] {
        let target = output.appendingPathComponent("\(locale)/\(width)x\(height)")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for index in 0..<5 {
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(
                cgContext: context.cgContext, flipped: true)
            let cg = context.cgContext
            cg.translateBy(x: 0, y: CGFloat(height))
            cg.scaleBy(x: CGFloat(width) / 1320, y: -CGFloat(height) / 2868)
            context.imageInterpolation = .high
            bg.setFill()
            NSRect(x: 0, y: 0, width: 1320, height: 2868).fill()
            // A soft amber halo links the store artwork to the app's EmberBackdrop.
            cg.saveGState()
            let glow = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    ember.withAlphaComponent(0.25).cgColor, ember.withAlphaComponent(0).cgColor,
                ] as CFArray,
                locations: [0, 1])!
            cg.drawRadialGradient(
                glow, startCenter: CGPoint(x: 660, y: 1590), startRadius: 0,
                endCenter: CGPoint(x: 660, y: 1590), endRadius: 880, options: [])
            cg.restoreGState()
            text(
                "KINROX  /  REMOTE", in: NSRect(x: 96, y: 104, width: 920, height: 54), size: 34,
                weight: .semibold,
                color: primary, locale: locale, shot: index + 1, kind: "brand")
            text(
                String(format: "%02d / 05", index + 1),
                in: NSRect(x: 1070, y: 104, width: 170, height: 54), size: 30, weight: .medium,
                color: ember, locale: locale, shot: index + 1, kind: "index")
            text(
                copy.screenshots[index][0], in: NSRect(x: 96, y: 245, width: 1128, height: 300),
                size: 112, weight: .bold,
                color: primary, rtl: rtl, expanded: !rtl, locale: locale, shot: index + 1,
                kind: "headline")
            text(
                copy.screenshots[index][1], in: NSRect(x: 100, y: 584, width: 1120, height: 190),
                size: 48, weight: .regular,
                color: secondary, rtl: rtl, locale: locale, shot: index + 1, kind: "description")
            let screen = index == 3 ? "recents" : index == 4 ? "pairing" : "remote"
            let path = raw.appendingPathComponent("\(lang)/\(screen).png")
            guard let img = NSImage(contentsOf: path) else {
                fatalError("Missing screenshot \(path.path)")
            }
            let rect = NSRect(x: 240, y: 870, width: 840, height: 1825.09)
            let clip = NSBezierPath(roundedRect: rect, xRadius: 72, yRadius: 72)
            cg.saveGState()
            clip.addClip()
            img.draw(
                in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                hints: nil)
            cg.restoreGState()
            NSColor(srgbRed: 0.45, green: 0.4, blue: 0.37, alpha: 1).setStroke()
            clip.lineWidth = 3
            clip.stroke()
            text(
                copy.requirement, in: NSRect(x: 96, y: 2774, width: 1128, height: 75), size: 29,
                weight: .medium,
                color: secondary, rtl: rtl, locale: locale, shot: index + 1, kind: "requirement")
            NSGraphicsContext.restoreGraphicsState()
            let opaque = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            opaque.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
            let data = NSBitmapImageRep(cgImage: opaque.makeImage()!).representation(
                using: .png, properties: [:])!
            try data.write(
                to: target.appendingPathComponent(String(format: "%02d-%@.png", index + 1, screen)),
                options: .withoutOverwriting)
        }
    }
    print("Rendered \(locale) from \(lang) UI")
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(metrics).write(to: output.appendingPathComponent("layout-metrics.json"))
