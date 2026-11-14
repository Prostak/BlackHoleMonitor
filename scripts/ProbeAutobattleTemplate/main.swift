import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Tight gold-letter template match on the bottom search strip (Two_Helmets-style).
/// Template is cropped closer to text than OCR needs — no button chrome required.

let roiX0 = 0.40, roiX1 = 0.60, roiY0 = 0.84, roiYEnd = 0.93
let confidence = 0.85

struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8] // row-major luminance
}

func loadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func toGray(_ image: CGImage) -> GrayImage? {
    let w = image.width
    let h = image.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &rgba,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var gray = [UInt8](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        let o = i * 4
        let r = Int(rgba[o]), g = Int(rgba[o + 1]), b = Int(rgba[o + 2])
        gray[i] = UInt8((r * 30 + g * 59 + b * 11) / 100)
    }
    return GrayImage(width: w, height: h, pixels: gray)
}

func crop(_ img: GrayImage, x: Int, y: Int, w: Int, h: Int) -> GrayImage {
    let x0 = max(0, x), y0 = max(0, y)
    let x1 = min(img.width, x0 + w), y1 = min(img.height, y0 + h)
    let cw = max(1, x1 - x0), ch = max(1, y1 - y0)
    var out = [UInt8](repeating: 0, count: cw * ch)
    for row in 0..<ch {
        let src = (y0 + row) * img.width + x0
        out.replaceSubrange(row * cw..<(row * cw + cw), with: img.pixels[src..<(src + cw)])
    }
    return GrayImage(width: cw, height: ch, pixels: out)
}

func stripAndOffset(_ img: GrayImage) -> (GrayImage, Int, Int) {
    let x0 = Int(Double(img.width) * roiX0)
    let x1 = Int(Double(img.width) * roiX1)
    let y0 = Int(Double(img.height) * roiY0)
    let y1 = Int(Double(img.height) * roiYEnd)
    return (crop(img, x: x0, y: y0, w: x1 - x0, h: y1 - y0), x0, y0)
}

/// Tight crop around bright (gold) letters inside a button ROI — closer than OCR padding.
func tightTextTemplate(fromRGBA image: CGImage) -> (GrayImage, CGRect)? {
    let w = image.width, h = image.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    var minX = w, minY = h, maxX = 0, maxY = 0, count = 0
    for y in 0..<h {
        for x in 0..<w {
            let o = (y * w + x) * 4
            let r = Int(rgba[o]), g = Int(rgba[o + 1]), b = Int(rgba[o + 2])
            let gold = r > 160 && g > 120 && b < 110 && (r - b) > 70
            if gold {
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }

    let rect: CGRect
    if count >= 20 {
        let padX = 2, padY = 1
        rect = CGRect(
            x: max(0, minX - padX),
            y: max(0, minY - padY),
            width: min(w, maxX + padX + 1) - max(0, minX - padX),
            height: min(h, maxY + padY + 1) - max(0, minY - padY)
        )
    } else {
        rect = CGRect(x: Int(Double(w) * 0.08), y: Int(Double(h) * 0.20),
                      width: Int(Double(w) * 0.84), height: Int(Double(h) * 0.60))
    }

    guard let gray = toGray(image) else { return nil }
    let tmpl = crop(gray, x: Int(rect.minX), y: Int(rect.minY), w: Int(rect.width), h: Int(rect.height))
    return (tmpl, rect)
}

/// TM_CCOEFF_NORMED equivalent.
func matchTemplate(hay: GrayImage, tmpl: GrayImage) -> (score: Double, x: Int, y: Int, ms: Double) {
    let tw = tmpl.width, th = tmpl.height
    let hw = hay.width, hh = hay.height
    precondition(tw <= hw && th <= hh)

    var tMean = 0.0
    for p in tmpl.pixels { tMean += Double(p) }
    tMean /= Double(tw * th)
    var tVar = 0.0
    var tCentered = [Double](repeating: 0, count: tw * th)
    for i in 0..<(tw * th) {
        let v = Double(tmpl.pixels[i]) - tMean
        tCentered[i] = v
        tVar += v * v
    }
    if tVar < 1e-6 { return (0, 0, 0, 0) }

    var best = -1.0
    var bestX = 0, bestY = 0
    let t0 = CFAbsoluteTimeGetCurrent()

    let maxY = hh - th
    let maxX = hw - tw
    for y in 0...maxY {
        for x in 0...maxX {
            var sum = 0.0, sumSq = 0.0, cross = 0.0
            for ty in 0..<th {
                let hayRow = (y + ty) * hw + x
                let tRow = ty * tw
                for tx in 0..<tw {
                    let hv = Double(hay.pixels[hayRow + tx])
                    sum += hv
                    sumSq += hv * hv
                    cross += hv * tCentered[tRow + tx]
                }
            }
            let n = Double(tw * th)
            let hVar = sumSq - (sum * sum) / n
            if hVar < 1e-6 { continue }
            let score = cross / sqrt(hVar * tVar)
            if score > best {
                best = score
                bestX = x
                bestY = y
            }
        }
    }
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    return (best, bestX, bestY, ms)
}

func saveGray(_ img: GrayImage, to url: URL) {
    guard let provider = CGDataProvider(data: Data(img.pixels) as CFData),
          let cg = CGImage(
            width: img.width, height: img.height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: img.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
          ),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        fputs("Failed to write \(url.path)\n", stderr)
        return
    }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - main

let debug = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/BlackHoleMonitor-Debug")
let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("scripts/cv_probe_out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let roiURL = debug.appendingPathComponent("last-trigger-roi.png")
let fullURLCandidates = [
    debug.appendingPathComponent("last-trigger-marked.png"),
    debug.appendingPathComponent("debug-full.png"),
]

guard let roiCG = loadCGImage(roiURL) else {
    fputs("Missing \(roiURL.path)\n", stderr)
    exit(1)
}

guard let (tmpl, tmplRect) = tightTextTemplate(fromRGBA: roiCG) else {
    fputs("Could not build tight template\n", stderr)
    exit(1)
}

print(String(format: "ROI: %dx%d", roiCG.width, roiCG.height))
print(String(format: "Tight text template: %dx%d (from ROI rect %.0f,%.0f %.0f×%.0f)",
             tmpl.width, tmpl.height, tmplRect.origin.x, tmplRect.origin.y, tmplRect.width, tmplRect.height))
saveGray(tmpl, to: outDir.appendingPathComponent("template_tight.png"))

if let roiGray = toGray(roiCG) {
    let selfMatch = matchTemplate(hay: roiGray, tmpl: tmpl)
    print(String(format: "Self-match on ROI: score=%.3f loc=(%d,%d) time=%.2fms",
                 selfMatch.score, selfMatch.x, selfMatch.y, selfMatch.ms))
}

var fullCG: CGImage?
var fullName = ""
for url in fullURLCandidates {
    guard let img = loadCGImage(url), img.width >= 200, img.height >= 200 else {
        if FileManager.default.fileExists(atPath: url.path) {
            print("Skip \(url.lastPathComponent): too small / locked crop")
        }
        continue
    }
    fullCG = img
    fullName = url.lastPathComponent
    break
}

guard let full = fullCG, let fullGray = toGray(full) else {
    print("No full-window haystack — capture Debug while Autobattle is visible.")
    exit(0)
}

let (strip, ox, oy) = stripAndOffset(fullGray)
saveGray(strip, to: outDir.appendingPathComponent("search_strip.png"))
print(String(format: "Haystack: %@ %dx%d", fullName, full.width, full.height))
print(String(format: "Search strip: %dx%d offset (%d,%d)", strip.width, strip.height, ox, oy))

// Warm-up
_ = matchTemplate(hay: strip, tmpl: tmpl)

var times: [Double] = []
var last = (score: 0.0, x: 0, y: 0, ms: 0.0)
for _ in 0..<10 {
    last = matchTemplate(hay: strip, tmpl: tmpl)
    times.append(last.ms)
}
let avg = times.reduce(0, +) / Double(times.count)
print(String(format: "Strip match x10: score=%.3f loc=(%d,%d) avg=%.2fms min=%.2f max=%.2f",
             last.score, last.x, last.y, avg, times.min() ?? 0, times.max() ?? 0))

let hit = last.score >= confidence
print(String(format: "Verdict @ %.2f: %@ (tight text template)", confidence, hit ? "HIT" : "MISS"))
print("Wrote \(outDir.path)/template_tight.png, search_strip.png")
