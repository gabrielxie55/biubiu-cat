import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 把绿幕视频的跳舞段抠成透明 PNG 序列 + 点击检测用的低清遮罩 + 可无缝循环的 WAV 音乐
// 用法: export <source.mp4> <输出目录>

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let frameCount = 334          // 第 334 帧起是小红书片尾卡
let fps = 30.0
let crop = CGRect(x: 166, y: 184, width: 388, height: 540)  // 所有帧里小猫包围盒的并集 + 8px 余量
let maskScale = 4             // 点击检测遮罩的缩小倍数

// 绿度 = G - max(R, B)，背景约 100，小猫约 0
let keyLow: Float = 30, keyHigh: Float = 75
let bgR: Float = 128, bgG: Float = 228, bgB: Float = 5   // 绿幕平均色

let fm = FileManager.default
let framesDir = outDir.appendingPathComponent("main/frames")
try? fm.removeItem(at: framesDir.deletingLastPathComponent())
try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)

func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) {
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

func exportFrames(_ asset: AVURLAsset) async throws {
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out)
    reader.startReading()

    let cw = Int(crop.width), ch = Int(crop.height), cx = Int(crop.minX), cy = Int(crop.minY)
    let mw = cw / maskScale, mh = ch / maskScale
    var masks = Data()
    var idx = 0
    while idx < frameCount, let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let n = cw * ch
        var raw = [Float](repeating: 0, count: n)
        var cr = [Float](repeating: 0, count: n), cg = cr, cb = cr
        for y in 0..<ch {
            for x in 0..<cw {
                let o = (y + cy) * bpr + (x + cx) * 4, i = y * cw + x
                let b = Float(p[o]), g = Float(p[o + 1]), r = Float(p[o + 2])
                let a = min(1, max(0, (keyHigh - (g - max(r, b))) / (keyHigh - keyLow)))
                raw[i] = a
                // 半透明边缘是「小猫颜色 × a + 绿幕 × (1-a)」，把绿幕成分减掉还原小猫本色
                if a > 0.01 {
                    cr[i] = min(255, max(0, (r - (1 - a) * bgR) / a))
                    cg[i] = min(255, max(0, (g - (1 - a) * bgG) / a))
                    cb[i] = min(255, max(0, (b - (1 - a) * bgB) / a))
                    cg[i] = min(cg[i], max(cr[i], cb[i]))   // 去掉残留的绿色反光
                }
            }
        }
        // 视频压缩会让绿色往猫身上渗 1~2 像素：轮廓往里收 2 像素，贴边一圈去色
        let alpha = boxBlur(minFilter(raw, cw, ch, 2), cw, ch, 1)
        let sat = boxBlur(minFilter(raw, cw, ch, 3), cw, ch, 2)
        var rgba = [UInt8](repeating: 0, count: n * 4)
        var mask = [UInt8](repeating: 0, count: mw * mh)
        for y in 0..<ch {
            for x in 0..<cw {
                let i = y * cw + x, d = i * 4
                let luma = 0.3 * cr[i] + 0.59 * cg[i] + 0.11 * cb[i]
                rgba[d] = UInt8(luma + (cr[i] - luma) * sat[i])
                rgba[d + 1] = UInt8(luma + (cg[i] - luma) * sat[i])
                rgba[d + 2] = UInt8(luma + (cb[i] - luma) * sat[i])
                rgba[d + 3] = UInt8((alpha[i] * 255).rounded())
                let mi = min(y / maskScale, mh - 1) * mw + min(x / maskScale, mw - 1)
                mask[mi] = max(mask[mi], rgba[d + 3])
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        writePNG(rgba, width: cw, height: ch, to: framesDir.appendingPathComponent(String(format: "%03d.png", idx)))
        masks.append(contentsOf: mask)
        idx += 1
    }
    reader.cancelReading()
    // 遮罩文件头: 宽、高、帧数 (UInt32 小端)
    var header = Data()
    for v in [UInt32(mw), UInt32(mh), UInt32(idx)] { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
    try (header + masks).write(to: outDir.appendingPathComponent("main/mask.bin"))
    print("frames: \(idx)  size: \(cw)x\(ch)  mask: \(mw)x\(mh)")
}

func exportAudio(_ asset: AVURLAsset) async throws {
    let track = try await asset.loadTracks(withMediaType: .audio)[0]
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps)))
    let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                              AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                              AVLinearPCMIsNonInterleaved: false]
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
    reader.add(out)
    let url = outDir.appendingPathComponent("music.wav")
    try? fm.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
    writer.add(input)
    reader.startReading()
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    var rms: [Double] = []
    while let sb = out.copyNextSampleBuffer() {
        if let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            ptr!.withMemoryRebound(to: Int16.self, capacity: len / 2) { s in
                var sum = 0.0
                for i in 0..<(len / 2) { let v = Double(s[i]) / 32768; sum += v * v }
                rms.append(sqrt(sum / Double(max(1, len / 2))))
            }
        }
        while !input.isReadyForMoreMediaData { usleep(1000) }
        input.append(sb)
    }
    input.markAsFinished()
    await writer.finishWriting()
    print("audio: \(writer.status == .completed ? "ok" : "failed \(String(describing: writer.error))")")
    print("rms per buffer:", rms.map { String(format: "%.2f", $0) }.joined(separator: " "))
}

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let asset = AVURLAsset(url: source)
        try await exportFrames(asset)
        try await exportAudio(asset)
    } catch { print("error:", error) }
    sem.signal()
}
sem.wait()
