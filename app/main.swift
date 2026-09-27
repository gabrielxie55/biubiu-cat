import AppKit
import AVFoundation
import ImageIO

// biubiu 小猫桌宠
// 小猫头顶有一排按钮，每个按钮对应一个动作：跳舞、音乐、召唤同伴、满屏乱转、散步
// 拖动小猫可以挪位置，右键调大小或退出

let fps = 30.0
let debug = CommandLine.arguments.contains("--debug")

// MARK: - 素材

/// 一只猫的逐帧动画：透明 PNG 序列 + 低清 alpha 遮罩（判断鼠标是不是点在猫身上）
final class Sprite {
    let frameURLs: [URL]
    let pixelSize: CGSize
    private let mask: [UInt8]
    private let maskW: Int, maskH: Int
    var count: Int { frameURLs.count }

    init(dir: URL) {
        frameURLs = (try! FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("frames"), includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let data = [UInt8](try! Data(contentsOf: dir.appendingPathComponent("mask.bin")))
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }
        maskW = u32(0); maskH = u32(4)
        mask = Array(data[12...])
        let src = CGImageSourceCreateWithURL(frameURLs[0] as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        pixelSize = CGSize(width: props[kCGImagePropertyPixelWidth] as! Int, height: props[kCGImagePropertyPixelHeight] as! Int)
    }

    func image(_ i: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(frameURLs[i % count] as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// u、v 是 0~1 的归一化坐标，v 从顶部算起
    func alpha(frame: Int, u: CGFloat, v: CGFloat) -> UInt8 {
        guard u >= 0, u < 1, v >= 0, v < 1 else { return 0 }
        return mask[(frame % count) * maskW * maskH + Int(v * CGFloat(maskH)) * maskW + Int(u * CGFloat(maskW))]
    }
}

// MARK: - 按钮

enum Action: Int, CaseIterable {
    case dance, music, friends, bounceTogether, bounceApart, portrait, walk

    var label: String { ["跳舞", "音乐", "同伴", "一起撞", "分开撞", "竖屏", "散步"][rawValue] }
    var symbol: String { ["figure.dance", "music.note", "cat.fill", "tornado", "burst.fill", "rectangle.portrait", "figure.walk"][rawValue] }
    var color: NSColor { [NSColor.systemPink, .systemPurple, .systemOrange, .systemGreen, .systemYellow, .systemTeal, .systemBlue][rawValue] }
    var iconColor: NSColor { self == .bounceApart ? NSColor(white: 0.15, alpha: 1) : .white }   // 黄底配深色图标才看得清
}

/// 小猫头顶的一排按钮：彩色圆点 + 图标 + 小字，打开状态的按钮外面有一圈白边
final class ButtonBar: NSView {
    static let circle: CGFloat = 20, cell: CGFloat = 31, pad: CGFloat = 5, labelH: CGFloat = 11
    static let size = NSSize(width: cell * CGFloat(Action.allCases.count) + pad * 2, height: pad + circle + 2 + labelH + pad - 1)

    var isActive: (Action) -> Bool = { _ in false }
    var onPress: (Action) -> Void = { _ in }
    private var pressed: Action?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func circleRect(_ a: Action) -> NSRect {
        let s = ButtonBar.self
        return NSRect(x: s.pad + CGFloat(a.rawValue) * s.cell + (s.cell - s.circle) / 2, y: bounds.height - s.pad - s.circle, width: s.circle, height: s.circle)
    }

    func action(at p: NSPoint) -> Action? {
        Action.allCases.first { NSRect(x: ButtonBar.pad + CGFloat($0.rawValue) * ButtonBar.cell, y: 0, width: ButtonBar.cell, height: bounds.height).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        for a in Action.allCases {
            let r = circleRect(a)
            let on = isActive(a)
            (pressed == a ? a.color.shadow(withLevel: 0.3)! : a.color).setFill()
            NSBezierPath(ovalIn: r).fill()
            if on {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -1.5, dy: -1.5))
                ring.lineWidth = 1.8
                ring.stroke()
            }
            let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .bold).applying(.init(paletteColors: [a.iconColor]))
            if let icon = NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.label)?.withSymbolConfiguration(config) {
                let s = icon.size
                icon.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
            let text = NSAttributedString(string: a.label, attributes: [
                .font: labelFont,
                .foregroundColor: NSColor.white.withAlphaComponent(on ? 1 : 0.8),
            ])
            let ts = text.size()
            text.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.minY - 2 - ts.height))
        }
    }

    override func mouseDown(with e: NSEvent) {
        pressed = action(at: convert(e.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        let a = action(at: convert(e.locationInWindow, from: nil))
        if let a, a == pressed { onPress(a) }
        pressed = nil
        needsDisplay = true
    }
}

/// 录屏背景：一整块纯色盖住桌面，右键可以呼出桌宠菜单把它关掉
final class BackdropView: NSView {
    weak var pet: Pet?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with e: NSEvent) { pet?.showMenu(e, in: self) }
}

final class PetView: NSView {
    weak var pet: Pet?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { pet?.mouseDown() }
    override func mouseDragged(with e: NSEvent) { pet?.mouseDragged() }
    override func mouseUp(with e: NSEvent) { pet?.mouseUp() }
    override func rightMouseDown(with e: NSEvent) { pet?.showMenu(e, in: self) }
}

// MARK: - 桌宠

final class Pet: NSObject {
    let main: Sprite, left: Sprite, right: Sprite
    let player: AVAudioPlayer
    let window: NSPanel
    let view = PetView()
    let bar = ButtonBar()
    let mainLayer = CALayer(), leftLayer = CALayer(), rightLayer = CALayer()

    // biubiubiu 字幕：放音乐或满屏乱撞时，一个个蹦出来
    var captionOn: Bool
    let captionLayer = CALayer()
    var captionImages: [CGImage] = []
    var captionStep = -1
    var flyerCaption: CALayer?     // 乱撞时跟着 biubiu 小猫一起飞的字幕

    // 各个动作的开关
    var dancing = false
    var friendsOut = false
    var walkEnabled: Bool
    var musicWanted = false
    var chaosOverlay: NSPanel?
    var chaosLayers: [ObjectIdentifier: CALayer] = [:]   // 家里的猫图层 → 满屏乱飞的替身图层
    var chaos: Bool { chaosOverlay != nil }

    // 散步：休息一会儿、走一会儿，交替进行
    var walking = false
    var walkDir: CGFloat = 0
    var walkPhaseEnd = CACurrentMediaTime() + 3
    var walkPos: NSPoint?       // 走路时的精确位置：窗口坐标会被取整，每步都从窗口读的话会越走越偏

    var scale: CGFloat          // 每个素材像素显示成多少 pt
    var volume: Float = 0.8
    var danceTime = 0.0         // biubiu 小猫跳到第几秒
    var friendsTime = 0.0       // 同伴跳到第几秒
    var lastTick = CACurrentMediaTime()
    var shown = (main: -1, left: -1, right: -1)
    var dragStart: NSPoint?, windowStart = NSPoint.zero, dragged = false

    static let sizes: [(String, CGFloat)] = [("小", 0.26), ("中", 0.36), ("大", 0.5)]

    // 布局，单位是 biubiu 小猫的素材像素：同伴放大到和小猫差不多高，站在两侧稍微往里靠
    let companionScale: CGFloat = 1.2
    let leftOverlap: CGFloat = 70, rightOverlap: CGFloat = 50
    let barGap: CGFloat = 6
    var leftSize: CGSize { CGSize(width: left.pixelSize.width * companionScale, height: left.pixelSize.height * companionScale) }
    var rightSize: CGSize { CGSize(width: right.pixelSize.width * companionScale, height: right.pixelSize.height * companionScale) }
    var mainX: CGFloat { leftSize.width - leftOverlap }
    var rightX: CGFloat { mainX + main.pixelSize.width - rightOverlap }
    var canvas: CGSize { CGSize(width: rightX + rightSize.width, height: max(main.pixelSize.height, leftSize.height, rightSize.height)) }
    func rect(_ x: CGFloat, _ size: CGSize) -> CGRect { CGRect(x: x * scale, y: captionStrip, width: size.width * scale, height: size.height * scale) }
    var mainRect: CGRect { rect(mainX, main.pixelSize) }
    var leftRect: CGRect { rect(0, leftSize) }
    var rightRect: CGRect { rect(rightX, rightSize) }
    var barRect: CGRect {
        let w = max(canvas.width * scale, ButtonBar.size.width)
        let x = min(max(0, mainRect.midX - ButtonBar.size.width / 2), w - ButtonBar.size.width)
        return CGRect(x: x, y: captionStrip + canvas.height * scale + barGap, width: ButtonBar.size.width, height: ButtonBar.size.height)
    }
    /// 脚下留给字幕的高度（字幕图上方自带的留白可以和脚底重叠）
    var captionStrip: CGFloat { captionLayer.bounds.height - captionPad }
    var captionPad: CGFloat = 0
    /// 字幕在窗口里的位置：紧贴在 biubiu 小猫脚下
    var captionRect: CGRect {
        let size = captionLayer.bounds.size
        return CGRect(x: mainRect.midX - size.width / 2, y: mainRect.minY - captionStrip, width: size.width, height: size.height)
    }

    init(assets: URL) {
        main = Sprite(dir: assets.appendingPathComponent("main"))
        left = Sprite(dir: assets.appendingPathComponent("left"))
        right = Sprite(dir: assets.appendingPathComponent("right"))
        player = try! AVAudioPlayer(contentsOf: assets.appendingPathComponent("music.wav"))
        player.numberOfLoops = -1
        player.prepareToPlay()
        let d = UserDefaults.standard
        scale = d.double(forKey: "scale") > 0 ? CGFloat(d.double(forKey: "scale")) : Pet.sizes[1].1
        walkEnabled = d.object(forKey: "walk") as? Bool ?? true
        captionOn = d.object(forKey: "caption") as? Bool ?? true
        portraitOnly = d.object(forKey: "portrait") as? Bool ?? false

        // 不抢焦点的浮动面板：点小猫或按钮时，你正在用的 app 不会失去焦点
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
        view.pet = self
        view.wantsLayer = true
        for layer in [leftLayer, rightLayer, mainLayer] {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0)   // 以脚底为锚点，同伴从地上「弹」出来，散步时左右摇摆
            layer.contentsGravity = .resize
            view.layer!.addSublayer(layer)
        }
        leftLayer.isHidden = true
        captionLayer.contentsGravity = .resize
        captionLayer.isHidden = true
        view.layer!.addSublayer(captionLayer)
        rightLayer.isHidden = true
        bar.isActive = { [unowned self] in self.isActive($0) }
        bar.onPress = { [unowned self] in self.trigger($0) }
        view.addSubview(bar)

        // 恢复上次的位置（以小猫的脚底中点为准），不在任何屏幕上就放到右下角
        var anchor = NSPoint(x: d.double(forKey: "anchorX"), y: d.double(forKey: "anchorY"))
        if d.object(forKey: "anchorX") == nil || !NSScreen.screens.contains(where: { $0.frame.contains(anchor) }) {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            anchor = NSPoint(x: vf.maxX - 160, y: vf.minY)
        }
        layout(anchor: anchor)
        showFrames()
        window.orderFrontRegardless()

        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
    }

    var anchor: NSPoint { NSPoint(x: window.frame.minX + mainRect.midX, y: window.frame.minY + captionStrip) }

    func layout(anchor: NSPoint) {
        makeCaptionImages()
        let size = NSSize(width: max(canvas.width * scale, ButtonBar.size.width), height: barRect.maxY)
        window.setFrame(NSRect(x: anchor.x - mainRect.midX, y: anchor.y - captionStrip, width: size.width, height: size.height), display: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, r) in [(mainLayer, mainRect), (leftLayer, leftRect), (rightLayer, rightRect)] {
            layer.bounds = CGRect(origin: .zero, size: r.size)
            layer.position = CGPoint(x: r.midX, y: r.minY)
        }
        CATransaction.commit()
        bar.frame = barRect
    }

    func move(anchor a: NSPoint) {
        window.setFrameOrigin(NSPoint(x: a.x - mainRect.midX, y: a.y - captionStrip))
    }

    func savePosition() {
        UserDefaults.standard.set(Double(anchor.x), forKey: "anchorX")
        UserDefaults.standard.set(Double(anchor.y), forKey: "anchorY")
    }

    // MARK: 按钮对应的动作

    func isActive(_ a: Action) -> Bool {
        switch a {
        case .dance: return dancing
        case .music: return musicWanted
        case .friends: return friendsOut
        case .bounceTogether: return chaos && chaosTogether
        case .bounceApart: return chaos && !chaosTogether
        case .portrait: return portraitOnly
        case .walk: return walkEnabled
        }
    }

    /// 音乐和同伴都是跳舞的「加料」：打开它们会顺带让小猫跳起来，关掉跳舞则全部停下
    func trigger(_ a: Action) {
        switch a {
        case .dance:
            if dancing {
                dancing = false
                setMusic(false)
                if friendsOut { hideFriends() }
                danceTime = 0
                restWalk()
            } else {
                dancing = true
            }
        case .music:
            if musicWanted { setMusic(false) } else { dancing = true; setMusic(true) }
        case .friends:
            if friendsOut { hideFriends() } else { dancing = true; showFriends() }
        case .bounceTogether, .bounceApart:
            // 撞的过程中再按任意一个「撞」按钮：提前收回
            if chaos { beginReturn() } else { startChaos(together: a == .bounceTogether) }
        case .portrait:
            portraitOnly.toggle()
            UserDefaults.standard.set(portraitOnly, forKey: "portrait")
            if portraitOnly { moveIntoPlayArea() }
        case .walk:
            walkEnabled.toggle()
            UserDefaults.standard.set(walkEnabled, forKey: "walk")
            restWalk()
        }
        bar.needsDisplay = true
        showFrames()
        if debug { log("按下「\(a.label)」") }
    }

    func log(_ what: String) {
        print(what, "→ 跳舞:\(dancing) 音乐:\(player.isPlaying) 同伴:\(friendsOut) 乱转:\(chaos) 散步开关:\(walkEnabled) 正在走:\(walking) 位置:(\(Int(anchor.x)),\(Int(anchor.y)))")
        fflush(stdout)
    }

    func setMusic(_ on: Bool) {
        musicWanted = on
        if on {
            player.currentTime = danceTime.truncatingRemainder(dividingBy: player.duration)
            player.volume = 0
            player.play()
            player.setVolume(volume, fadeDuration: 0.2)
        } else if player.isPlaying {
            player.setVolume(0, fadeDuration: 0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.musicWanted == false { self?.player.stop() }
            }
        }
    }

    // MARK: 每帧更新

    @objc func tick() {
        let now = CACurrentMediaTime(), dt = min(now - lastTick, 0.1)
        lastTick = now
        updateWalk(now: now, dt: dt)
        updateChaos(now: now, dt: dt)
        updateCaption(now: now)

        if musicWanted && player.isPlaying {
            // 有音乐时跟着音乐的播放进度走，保证舞步和节拍对得上
            danceTime = player.currentTime
        } else if dancing || friendsOut || chaos || walking {
            danceTime += dt
        } else {
            danceTime = 0
        }
        if friendsOut { friendsTime += dt }

        // 散步时以脚底为轴左右摇摆，像在一扭一扭地走
        let tilt = walking ? sin(now * .pi * 3.2) * 0.07 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mainLayer.setAffineTransform(CGAffineTransform(rotationAngle: tilt))
        CATransaction.commit()

        showFrames()
        updateClickThrough()
    }

    func showFrames() {
        let m = Int(danceTime * fps) % main.count
        let l = Int(friendsTime * fps) % left.count, r = Int(friendsTime * fps) % right.count
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        func set(_ layer: CALayer, _ img: CGImage?) {
            layer.contents = img
            chaosLayers[ObjectIdentifier(layer)]?.contents = img
        }
        if m != shown.main { set(mainLayer, main.image(m)); shown.main = m }
        if friendsOut {
            if l != shown.left { set(leftLayer, left.image(l)); shown.left = l }
            if r != shown.right { set(rightLayer, right.image(r)); shown.right = r }
        }
        CATransaction.commit()
    }

    /// 鼠标在透明区域时让点击穿透到下面的窗口，只有在猫身上或按钮条上才归桌宠
    func updateClickThrough() {
        guard dragStart == nil else { return }
        let p = NSEvent.mouseLocation, f = window.frame
        let interactive = isInteractive(CGPoint(x: p.x - f.minX, y: p.y - f.minY))
        if window.ignoresMouseEvents == interactive {
            window.ignoresMouseEvents = !interactive
        }
    }

    /// local 是窗口内坐标（左下角为原点）
    func isInteractive(_ local: CGPoint) -> Bool {
        if barRect.contains(local) { return true }
        if chaos { return false }   // 乱转时猫都飞走了，原地只剩按钮
        func hit(_ s: Sprite, _ r: CGRect, _ i: Int) -> Bool {
            s.alpha(frame: i, u: (local.x - r.minX) / r.width, v: (r.maxY - local.y) / r.height) > 60
        }
        return hit(main, mainRect, max(shown.main, 0))
            || (friendsOut && (hit(left, leftRect, max(shown.left, 0)) || hit(right, rightRect, max(shown.right, 0))))
    }

    // MARK: 散步

    func restWalk() {
        walking = false
        walkDir = 0
        walkPos = nil
        walkPhaseEnd = CACurrentMediaTime() + 3
    }

    func updateWalk(now: Double, dt: Double) {
        guard walkEnabled, !dancing, !friendsOut, !chaos, dragStart == nil else {
            if walking { restWalk() }
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let area = playArea(on: screen)
        let minX = max(vf.minX, area.minX), maxX = min(vf.maxX, area.maxX)
        let edge = min(200, (maxX - minX) / 4)
        var a = walkPos ?? anchor
        if now >= walkPhaseEnd {
            if walkDir == 0 {
                // 休息完了开始走：靠近屏幕边缘就往回走，否则随机选方向
                walkDir = a.x < minX + edge ? 1 : a.x > maxX - edge ? -1 : (Bool.random() ? 1 : -1)
                walkPhaseEnd = now + Double.random(in: 4...8)
            } else {
                walkDir = 0
                walkPhaseEnd = now + Double.random(in: 2...5)
                savePosition()
            }
        }
        walking = walkDir != 0
        guard walking else { return }
        if a.y > vf.minY + 0.5 {
            a.y = max(vf.minY, a.y - 500 * dt)   // 被拖到半空的话，先落回屏幕底部再走
        } else {
            a.y = vf.minY
            a.x += walkDir * 110 * scale * dt
            let half = mainRect.width / 2
            if a.x < minX + half { a.x = minX + half; walkDir = 1 }
            if a.x > maxX - half { a.x = maxX - half; walkDir = -1 }
        }
        walkPos = a
        move(anchor: a)
    }

    // MARK: 竖屏区域

    var portraitOnly: Bool

    /// 猫能活动的范围：平时是整块屏幕，打开「竖屏」后只在屏幕最右边一块 9:16 的竖条里
    func playArea(on screen: NSScreen) -> CGRect {
        let f = screen.frame
        guard portraitOnly else { return f }
        let w = min(f.width, f.height * 9 / 16)
        return CGRect(x: f.maxX - w, y: f.minY, width: w, height: f.height)
    }

    /// 打开竖屏时，把小猫挪到竖条正中间
    func moveIntoPlayArea() {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let area = playArea(on: screen)
        let target = NSPoint(x: area.midX, y: anchor.y)
        restWalk()
        let origin = NSPoint(x: target.x - mainRect.midX, y: target.y - captionStrip)
        window.setFrame(NSRect(origin: origin, size: window.frame.size), display: true, animate: true)
        savePosition()
    }

    // MARK: 召唤同伴

    func showFriends() {
        friendsOut = true
        friendsTime = 0
        shown.left = -1; shown.right = -1
        showFrames()
        for (layer, delay) in [(leftLayer, 0.0), (rightLayer, 0.15)] {
            layer.removeAllAnimations()
            layer.isHidden = false
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.01
            pop.toValue = 1
            pop.damping = 8
            pop.stiffness = 220
            pop.duration = pop.settlingDuration
            pop.beginTime = CACurrentMediaTime() + delay
            pop.fillMode = .backwards
            layer.add(pop, forKey: "pop")
        }
    }

    func hideFriends() {
        friendsOut = false
        for layer in [leftLayer, rightLayer] {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard self?.friendsOut == false else { return }
                layer.isHidden = true
                layer.removeAllAnimations()
            }
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.01
            shrink.duration = 0.22
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "pop")
            CATransaction.commit()
        }
    }

    // MARK: 满屏乱转（台球）

    /// 一颗正在满屏乱撞的「台球」：可能是一只猫，也可能是站成一排的三只猫
    struct Flyer {
        let layer: CALayer
        let homePos: CGPoint
        let size: CGSize
        var p: CGPoint
        var v: CGVector
        var returnFrom = CGPoint.zero
        var radius: CGFloat { min(size.width, size.height) * 0.42 }   // 猫和猫相撞时按圆来算
    }
    var flyers: [Flyer] = []
    var chaosStart = 0.0
    var chaosReturnStart: Double?
    var lastPop = 0.0
    let chaosDuration = 7.0, returnDuration = 0.6
    var chaosTogether = true    // true：三只猫保持队形一起撞；false：各撞各的
    var chaosBounds = CGRect.zero   // 乱撞的范围（覆盖窗口里的坐标）

    /// 在整块屏幕上盖一层透明、不挡鼠标的窗口，让猫的替身像台球一样在上面乱撞，结束时飞回原位
    func startChaos(together: Bool) {
        chaosTogether = together
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let overlay = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.hidesOnDeactivate = false
        overlay.level = .statusBar   // 连菜单栏和 Dock 上面都能撞过去
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        overlay.contentView = root
        overlay.setFrame(screen.frame, display: false)
        chaosOverlay = overlay
        chaosBounds = playArea(on: screen).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)

        var cats = [(mainLayer, mainRect)]
        if friendsOut { cats += [(leftLayer, leftRect), (rightLayer, rightRect)] }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let groups = chaosTogether ? [cats] : cats.map { [$0] }
        flyers = groups.map { group in
            // 一组猫放进同一个容器图层，保持它们在家里的相对位置
            let hasMain = group.contains { $0.0 === mainLayer }
            var union = group.dropFirst().reduce(group[0].1) { $0.union($1.1) }
            if hasMain && captionOn { union = union.union(captionRect) }
            let start = CGPoint(x: window.frame.minX + union.midX - screen.frame.minX, y: window.frame.minY + union.midY - screen.frame.minY)
            let flyer = CALayer()
            flyer.bounds = CGRect(origin: .zero, size: union.size)
            flyer.position = start
            for (home, r) in group {
                let cat = CALayer()
                cat.contentsGravity = .resize
                cat.contents = home.contents
                cat.frame = r.offsetBy(dx: -union.minX, dy: -union.minY)
                flyer.addSublayer(cat)
                chaosLayers[ObjectIdentifier(home)] = cat
                home.opacity = 0
            }
            if hasMain {
                let caption = CALayer()
                caption.contentsGravity = .resize
                caption.bounds = captionLayer.bounds
                caption.position = captionCenter(in: union)
                caption.contents = captionLayer.contents
                flyer.addSublayer(caption)
                flyerCaption = caption
            }
            root.layer!.addSublayer(flyer)
            // 开球：朝随机方向高速飞出去（往上半边飞，免得一出门就撞地板）
            let angle = Double.random(in: 0.15...(Double.pi - 0.15))
            let speed = Double.random(in: 1150...1450)
            return Flyer(layer: flyer, homePos: start, size: union.size, p: start,
                         v: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed))
        }
        CATransaction.commit()
        chaosStart = CACurrentMediaTime()
        chaosReturnStart = nil
        overlay.orderFrontRegardless()
        pop()
    }

    func beginReturn() {
        guard chaosReturnStart == nil else { return }
        chaosReturnStart = CACurrentMediaTime()
        for i in flyers.indices { flyers[i].returnFrom = flyers[i].p }
    }

    func updateChaos(now: Double, dt: Double) {
        guard chaosOverlay != nil else { return }
        let bounds = chaosBounds
        if now - chaosStart > chaosDuration { beginReturn() }

        if let rs = chaosReturnStart {
            // 收场：从当前位置平滑飞回家
            let t = min(1, (now - rs) / returnDuration), e = t * t * (3 - 2 * t)
            for i in flyers.indices {
                let f = flyers[i]
                flyers[i].p = CGPoint(x: f.returnFrom.x + (f.homePos.x - f.returnFrom.x) * e, y: f.returnFrom.y + (f.homePos.y - f.returnFrom.y) * e)
            }
            placeFlyers()
            if t >= 1 { finishChaos() }
            return
        }

        // 像台球一样有摩擦，越撞越慢
        let friction = exp(-0.25 * dt)
        for i in flyers.indices {
            var f = flyers[i]
            f.v.dx *= friction; f.v.dy *= friction
            f.p.x += f.v.dx * dt; f.p.y += f.v.dy * dt
            let hw = f.size.width / 2, hh = f.size.height / 2
            if f.p.x - hw < bounds.minX { f.p.x = bounds.minX + hw; f.v.dx = abs(f.v.dx); bump(f.layer, horizontal: true) }
            if f.p.x + hw > bounds.maxX { f.p.x = bounds.maxX - hw; f.v.dx = -abs(f.v.dx); bump(f.layer, horizontal: true) }
            if f.p.y - hh < bounds.minY { f.p.y = bounds.minY + hh; f.v.dy = abs(f.v.dy); bump(f.layer, horizontal: false) }
            if f.p.y + hh > bounds.maxY { f.p.y = bounds.maxY - hh; f.v.dy = -abs(f.v.dy); bump(f.layer, horizontal: false) }
            flyers[i] = f
        }
        // 猫和猫相撞：一样重的两个球弹性碰撞，沿连线方向交换速度
        for i in flyers.indices {
            for j in flyers.indices where j > i {
                let dx = flyers[j].p.x - flyers[i].p.x, dy = flyers[j].p.y - flyers[i].p.y
                let dist = max(hypot(dx, dy), 0.001), minDist = flyers[i].radius + flyers[j].radius
                guard dist < minDist else { continue }
                let nx = dx / dist, ny = dy / dist, push = (minDist - dist) / 2
                flyers[i].p.x -= nx * push; flyers[i].p.y -= ny * push
                flyers[j].p.x += nx * push; flyers[j].p.y += ny * push
                let rv = (flyers[i].v.dx - flyers[j].v.dx) * nx + (flyers[i].v.dy - flyers[j].v.dy) * ny
                guard rv > 0 else { continue }
                flyers[i].v.dx -= rv * nx; flyers[i].v.dy -= rv * ny
                flyers[j].v.dx += rv * nx; flyers[j].v.dy += rv * ny
                bump(flyers[i].layer, horizontal: abs(nx) > abs(ny))
                bump(flyers[j].layer, horizontal: abs(nx) > abs(ny))
            }
        }
        placeFlyers()
    }

    func placeFlyers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for f in flyers { f.layer.position = f.p }
        CATransaction.commit()
    }

    /// 撞到东西：身体被压扁一下再弹回来，配一声「砰」
    func bump(_ layer: CALayer, horizontal: Bool) {
        let squash = CAKeyframeAnimation(keyPath: "transform")
        let (sx, sy): (CGFloat, CGFloat) = horizontal ? (0.7, 1.2) : (1.25, 0.72)
        squash.values = [CATransform3DIdentity, CATransform3DMakeScale(sx, sy, 1), CATransform3DMakeScale(2 - sx * 0.95, 2 - sy * 0.95, 1), CATransform3DIdentity]
        squash.keyTimes = [0, 0.3, 0.65, 1]
        squash.duration = 0.2
        layer.add(squash, forKey: "bump")
        pop()
    }

    func pop() {
        let now = CACurrentMediaTime()
        guard volume > 0, now - lastPop > 0.06 else { return }
        lastPop = now
        if let sound = NSSound(named: "Pop")?.copy() as? NSSound {
            sound.volume = 0.5
            sound.play()
        }
    }

    func finishChaos() {
        guard let overlay = chaosOverlay else { return }
        chaosOverlay = nil
        chaosReturnStart = nil
        flyers.removeAll()
        flyerCaption = nil
        chaosLayers.removeAll()
        overlay.orderOut(nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [mainLayer, leftLayer, rightLayer] { layer.opacity = 1 }
        CATransaction.commit()
        restWalk()
        bar.needsDisplay = true
        if debug { log("乱转结束") }
    }

    // MARK: 字幕

    /// 字幕中心点，container 是字幕所在图层在窗口里的位置
    func captionCenter(in container: CGRect) -> CGPoint {
        CGPoint(x: captionRect.midX - container.minX, y: captionRect.midY - container.minY)
    }

    /// 预先画好三张字幕图：biu、biubiu、biubiubiu~，白色粗圆体 + 黑色描边
    func makeCaptionImages() {
        let fontSize = max(13, 60 * scale)
        let base = NSFont.systemFont(ofSize: fontSize, weight: .black)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
        let full = NSAttributedString(string: "biubiubiu~", attributes: [.font: font]).size()
        let pad = fontSize * 0.3
        let size = NSSize(width: ceil(full.width + pad * 2), height: ceil(full.height + pad * 2))
        captionImages = ["biu", "biubiu", "biubiubiu~"].map { text in
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // 左对齐画在整句的宽度里，这样字是从左往右一个个长出来的
            let origin = NSPoint(x: pad, y: pad)
            NSAttributedString(string: text, attributes: [.font: font, .strokeColor: NSColor(white: 0.1, alpha: 1), .strokeWidth: 24]).draw(at: origin)
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]).draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage!
        }
        captionLayer.bounds = CGRect(origin: .zero, size: size)
        captionPad = pad
        captionStep = -1
    }

    func updateCaption(now: Double) {
        let show = captionOn && (musicWanted || chaos)
        // 每 0.25 秒蹦一个 biu，蹦满三个后停一会儿再从头开始；有音乐时跟着音乐的进度走
        let t = musicWanted && player.isPlaying ? player.currentTime : now
        let step = show ? min(Int(t / 0.25) % 6, 2) : -1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        captionLayer.isHidden = !show || chaos
        // 窗口底部超出屏幕（比如 Dock 设成自动隐藏）时，把字幕往上挪，保证能看见
        let screenBottom = (window.screen ?? NSScreen.main)?.frame.minY ?? 0
        let hidden = screenBottom - (window.frame.minY + captionRect.minY)
        captionLayer.position = CGPoint(x: captionRect.midX, y: captionRect.midY + max(0, hidden))
        if step != captionStep {
            captionStep = step
            if step >= 0 {
                let img = captionImages[step]
                captionLayer.contents = img
                flyerCaption?.contents = img
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [1.25, 0.95, 1]
                pop.duration = 0.18
                (chaos ? flyerCaption : captionLayer)?.add(pop, forKey: "pop")
            }
        }
        CATransaction.commit()
    }

    // MARK: 鼠标

    func mouseDown() {
        dragStart = NSEvent.mouseLocation
        windowStart = window.frame.origin
        dragged = false
    }

    func mouseDragged() {
        guard let s = dragStart else { return }
        let p = NSEvent.mouseLocation
        if !dragged && hypot(p.x - s.x, p.y - s.y) < 4 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: windowStart.x + p.x - s.x, y: windowStart.y + p.y - s.y))
    }

    func mouseUp() {
        if dragged { savePosition() }
        dragStart = nil
        restWalk()
    }

    // MARK: 录屏背景

    static let backdrops = ["关闭", "干净桌面（只留壁纸，遮住窗口和图标）", "绿幕（方便后期抠图）"]
    var backdrop: NSPanel?
    var backdropIndex = 0

    /// 在所有普通窗口上面、桌宠下面铺一层背景：当前桌面壁纸（看起来就是一个干净的桌面）或者绿幕
    @objc func setBackdrop(_ item: NSMenuItem) {
        backdropIndex = item.tag
        backdrop?.orderOut(nil)
        backdrop = nil
        guard item.tag > 0 else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = item.tag == 2 ? NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) : .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let v = BackdropView()
        v.pet = self
        if item.tag == 1, let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let wallpaper = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // 和系统铺壁纸的方式一样：等比例铺满屏幕，多出来的裁掉
            v.wantsLayer = true
            v.layer!.contents = wallpaper
            v.layer!.contentsGravity = .resizeAspectFill
            v.layer!.masksToBounds = true
        }
        panel.contentView = v
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        backdrop = panel
    }

    func showMenu(_ e: NSEvent, in v: NSView) {
        let menu = NSMenu()
        let backdropMenu = NSMenu()
        for (i, title) in Pet.backdrops.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setBackdrop(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == backdropIndex ? .on : .off
            backdropMenu.addItem(item)
        }
        let backdropItem = NSMenuItem(title: "录屏背景", action: nil, keyEquivalent: "")
        backdropItem.submenu = backdropMenu
        menu.addItem(backdropItem)
        menu.addItem(.separator())
        for (title, s) in Pet.sizes {
            let item = NSMenuItem(title: "\(title)号", action: #selector(setSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s
            item.state = abs(s - scale) < 0.001 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let captionItem = NSMenuItem(title: "显示 biubiubiu 字幕", action: #selector(toggleCaption), keyEquivalent: "")
        captionItem.target = self
        captionItem.state = captionOn ? .on : .off
        menu.addItem(captionItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 biubiu 小猫", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: e, for: v)
    }

    @objc func toggleCaption() {
        captionOn.toggle()
        UserDefaults.standard.set(captionOn, forKey: "caption")
    }

    @objc func setSize(_ item: NSMenuItem) {
        let a = anchor
        scale = item.representedObject as! CGFloat
        UserDefaults.standard.set(Double(scale), forKey: "scale")
        layout(anchor: a)
    }
}

// MARK: - 启动

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let pet = Pet(assets: Bundle.main.resourceURL!.appendingPathComponent("assets"))
let args = CommandLine.arguments
if args.contains("--mute") { pet.volume = 0 }

// 调试用：--backdrop 1 直接打开第几种录屏背景
if let i = args.firstIndex(of: "--backdrop"), i + 1 < args.count, let n = Int(args[i + 1]) {
    let item = NSMenuItem()
    item.tag = n
    pet.setBackdrop(item)
}
// 调试用：--press 同伴 --press 乱转，启动后每隔 1 秒依次按下这些按钮
for (i, j) in args.indices.filter({ args[$0] == "--press" && $0 + 1 < args.count }).enumerated() {
    if let a = Action.allCases.first(where: { $0.label == args[j + 1] }) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i + 1)) { pet.trigger(a) }
    }
}

// 自检：验证点击判定，然后按顺序模拟按下各个按钮，最后退出
if args.contains("--selftest") {
    let m = pet.mainRect, b = pet.barRect
    for (name, p) in [
        ("小猫肚子", CGPoint(x: m.midX, y: m.maxY - m.height * 0.55)),
        ("按钮条中间", CGPoint(x: b.midX, y: b.midY)),
        ("窗口左下角", CGPoint(x: 2, y: 2)),
        ("按钮条左边的空白", CGPoint(x: max(0, b.minX - 4), y: b.midY)),
    ] {
        print("点击判定 \(name): \(pet.isInteractive(p) ? "归桌宠" : "穿透")")
    }
    for (i, a) in Action.allCases.enumerated() {
        let r = pet.bar.circleRect(a)
        print("按钮 \(i + 1) 位置 → \(pet.bar.action(at: NSPoint(x: r.midX, y: r.midY))?.label ?? "无")")
    }
    pet.log("启动")
    let steps: [(Double, () -> Void)] = [
        (7, { pet.log("散步中") }),
        (8, { pet.trigger(.dance) }),
        (10, { pet.trigger(.music) }),
        (12, { pet.trigger(.friends) }),
        (15, { pet.trigger(.bounceTogether) }),
        (24, { pet.trigger(.friends) }),
        (26, { pet.trigger(.dance) }),
        (27, { pet.trigger(.walk) }),
        (27.5, { pet.trigger(.walk) }),
        (28, { NSApp.terminate(nil) }),
    ]
    for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
}
app.run()
