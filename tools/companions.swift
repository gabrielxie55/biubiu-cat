import AVFoundation
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// 用系统主体抠图（Vision）从三猫视频里逐帧抠出左右两只同伴
// 用法: companions <source2.mp4> <输出目录>
// 输出: <输出目录>/left、right 各含 frames/%03d.png + mask.bin；并打印中间那只猫的高度，用来和 biubiu 小猫对齐大小

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let frameCount = 236   // 第 236 帧起是片尾卡
let pad = 8
let maskScale = 4
let fm = FileManager.default

struct Box { var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    mutating func add(_ x: Int, _ y: Int) { minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) }
    mutating func add(_ b: Box) { add(b.minX, b.minY); add(b.maxX, b.maxY) }
    var height: Int { maxY - minY + 1 }
}

// 每帧三只猫按从左到右排序，返回 [左, 中, 右] 的全分辨率软遮罩（Float32, 0~1）
// 个别帧中间猫和旁边一只贴在一起会被认成一个实例，这时被粘住的那只返回 nil，由调用方沿用上一帧
func masks(for pb: CVPixelBuffer) throws -> [CVPixelBuffer?] {
    let req = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cvPixelBuffer: pb)
    try handler.perform([req])
    guard let obs = req.results?.first, obs.allInstances.count >= 2 else { throw NSError(domain: "vision", code: 1) }
    let lm = obs.instanceMask
    CVPixelBufferLockBaseAddress(lm, .readOnly)
    let mw = CVPixelBufferGetWidth(lm), mh = CVPixelBufferGetHeight(lm), mbpr = CVPixelBufferGetBytesPerRow(lm)
    let mp = CVPixelBufferGetBaseAddress(lm)!.assumingMemoryBound(to: UInt8.self)
    var sums: [Int: (Int, Int)] = [:]
    for y in 0..<mh { for x in 0..<mw { let i = Int(mp[y * mbpr + x]); if i > 0 { let s = sums[i] ?? (0, 0); sums[i] = (s.0 + x, s.1 + 1) } } }
    CVPixelBufferUnlockBaseAddress(lm, .readOnly)
    let mask = { (i: Int) in try obs.generateScaledMaskForImage(forInstances: IndexSet(integer: i), from: handler) }
    let centroid = { (i: Int) in Double(sums[i]!.0) / Double(sums[i]!.1) }
    if sums.count >= 3 {
        // 只取像素最多的三个实例，再按水平重心排序
        let top3 = sums.sorted { $0.value.1 > $1.value.1 }.prefix(3).map { $0.key }
        return try top3.sorted { centroid($0) < centroid($1) }.map { try mask($0) }
    }
    // 只有两个实例：像素多的是粘在一起的两只猫
    let byPx = sums.sorted { $0.value.1 > $1.value.1 }.map { $0.key }
    let merged = byPx[0], single = byPx[1]
    return centroid(single) < centroid(merged) ? [try mask(single), nil, nil] : [nil, nil, try mask(single)]
}

func alphaBox(_ mask: CVPixelBuffer) -> Box {
    CVPixelBufferLockBaseAddress(mask, .readOnly); defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
    let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), bpr = CVPixelBufferGetBytesPerRow(mask)
    let base = CVPixelBufferGetBaseAddress(mask)!
    var b = Box()
    for y in 0..<h { let row = (base + y * bpr).assumingMemoryBound(to: Float32.self); for x in 0..<w where row[x] > 0.05 { b.add(x, y) } }
    return b
}

func frames(_ asset: AVURLAsset, _ body: (Int, CVPixelBuffer) throws -> Void) async throws {
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out); reader.startReading()
    var idx = 0
    while idx < frameCount, let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
        try body(idx, pb); idx += 1
    }
    reader.cancelReading()
}

func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) {
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let asset = AVURLAsset(url: source)
        // 第一遍：算每只猫在所有帧里的包围盒并集，以及中间猫的高度
        var unions = [Box(), Box(), Box()]
        var middleHeights: [Int] = []
        try await frames(asset) { _, pb in
            let ms = try masks(for: pb)
            for i in 0..<3 { guard let m = ms[i] else { continue }; let b = alphaBox(m); unions[i].add(b); if i == 1 { middleHeights.append(b.height) } }
        }
        middleHeights.sort()
        print("middle cat median height:", middleHeights[middleHeights.count / 2])

        // 第二遍：按并集裁切，写出左右两只同伴的透明帧和点击遮罩
        let names = [0: "left", 2: "right"]
        var crops: [Int: CGRect] = [:]
        var maskData: [Int: Data] = [:]
        for (i, name) in names {
            let u = unions[i]
            crops[i] = CGRect(x: max(0, u.minX - pad), y: max(0, u.minY - pad), width: u.maxX - u.minX + 1 + 2 * pad, height: u.maxY - u.minY + 1 + 2 * pad)
            let dir = outDir.appendingPathComponent("\(name)/frames")
            try? fm.removeItem(at: dir.deletingLastPathComponent())
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            maskData[i] = Data()
        }
        try await frames(asset) { idx, pb in
            let ms = try masks(for: pb)
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let bpr = CVPixelBufferGetBytesPerRow(pb), fw = CVPixelBufferGetWidth(pb), fh = CVPixelBufferGetHeight(pb)
            let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            for (i, name) in names {
                let c = crops[i]!, cw = Int(c.width), ch = Int(c.height), cx = Int(c.minX), cy = Int(c.minY)
                let mw = cw / maskScale, mh = ch / maskScale
                guard let m = ms[i] else {
                    // 这一帧没分出来，沿用上一帧
                    let prev = outDir.appendingPathComponent(String(format: "%@/frames/%03d.png", name, idx - 1))
                    try fm.copyItem(at: prev, to: outDir.appendingPathComponent(String(format: "%@/frames/%03d.png", name, idx)))
                    let last = Data(maskData[i]!.suffix(mw * mh)); maskData[i]!.append(last)
                    print("frame \(idx) \(name): 沿用上一帧")
                    continue
                }
                CVPixelBufferLockBaseAddress(m, .readOnly)
                let mbpr = CVPixelBufferGetBytesPerRow(m), mbase = CVPixelBufferGetBaseAddress(m)!
                var raw = [Float](repeating: 0, count: cw * ch)
                for y in 0..<ch where y + cy < fh {
                    let mrow = (mbase + (y + cy) * mbpr).assumingMemoryBound(to: Float32.self)
                    for x in 0..<cw where x + cx < fw { raw[y * cw + x] = min(1, max(0, mrow[x + cx])) }
                }
                // 原视频里同伴是贴纸风合成的，自带一圈浅色描边：往里收 2 像素去掉
                let alpha = boxBlur(minFilter(raw, cw, ch, 2), cw, ch, 1)
                var rgba = [UInt8](repeating: 0, count: cw * ch * 4)
                var hit = [UInt8](repeating: 0, count: mw * mh)
                for y in 0..<ch where y + cy < fh {
                    for x in 0..<cw where x + cx < fw {
                        let a = UInt8((alpha[y * cw + x] * 255).rounded())
                        guard a > 0 else { continue }
                        let o = (y + cy) * bpr + (x + cx) * 4, d = (y * cw + x) * 4
                        rgba[d] = p[o + 2]; rgba[d + 1] = p[o + 1]; rgba[d + 2] = p[o]; rgba[d + 3] = a
                        let mi = min(y / maskScale, mh - 1) * mw + min(x / maskScale, mw - 1)
                        hit[mi] = max(hit[mi], a)
                    }
                }
                CVPixelBufferUnlockBaseAddress(m, .readOnly)
                writePNG(rgba, width: cw, height: ch, to: outDir.appendingPathComponent(String(format: "%@/frames/%03d.png", name, idx)))
                maskData[i]!.append(contentsOf: hit)
            }
        }
        for (i, name) in names {
            let c = crops[i]!
            var header = Data()
            for v in [UInt32(Int(c.width) / maskScale), UInt32(Int(c.height) / maskScale), UInt32(frameCount)] { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
            try (header + maskData[i]!).write(to: outDir.appendingPathComponent("\(name)/mask.bin"))
            print("\(name): crop \(c)")
        }
    } catch { print("error:", error) }
    sem.signal()
}
sem.wait()
