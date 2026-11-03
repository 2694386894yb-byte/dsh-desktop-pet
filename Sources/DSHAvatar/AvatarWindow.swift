// 挂在菜单栏上的那扇窗，以及它的气泡窗。
//
// 几个关键点（都踩过/验过）：
//   1. 层级必须高于 kCGMainMenuWindowLevel(24)：用 .screenSaver(1000)。
//      实测：这个层级能盖住 macOS 26 的菜单栏（探针脚本 scripts/probe-menubar.swift）。
//   2. 用 NSPanel + .nonactivatingPanel：点形象不会把 DSH/前台的 App 顶掉焦点。
//   3. 默认「可点」但也随时能切成点击穿透（不挡菜单栏）。
//   4. 拖动时禁止压刘海——刘海是物理挖空，画上去也看不见。
import AppKit
import SceneKit

// MARK: - 形象窗

final class AvatarSceneView: SCNView {
    var onTap: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?

    var isPositioning = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    /// 未激活的窗口也要收到第一次点击，否则点一下只是「激活」而没有反应。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isPositioning else { return }
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPositioning, let win = window else { return }
        var frame = win.frame
        frame.origin.x += event.deltaX
        win.setFrameOrigin(frame.origin)
        onDragEnded?(frame.origin.x)   // 拖动中实时上报，让上层夹住刘海（视觉立刻回弹）
    }

    override func mouseUp(with event: NSEvent) {
        if isPositioning {
            NSCursor.pop()
            onDragEnded?(window?.frame.origin.x ?? 0)
        } else {
            onTap?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override func resetCursorRects() {
        if isPositioning { addCursorRect(bounds, cursor: .openHand) }
    }
}

/// 定位模式下罩在形象上的一层虚线框（不参与命中测试）。
final class PositioningOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor(srgbRed: 0.35, green: 0.85, blue: 1, alpha: 0.95).setStroke()
        path.stroke()
    }
}

final class AvatarWindow: NSPanel {
    private var baseFrame: NSRect = .zero
    private var celebrationTimer: Timer?

    init(frame: NSRect) {
        baseFrame = frame
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        // 层级：盖住菜单栏（菜单栏 24、状态项 25）。
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        // 允许出现在截图/录屏里，但不该出现在窗口切换器里。
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 结果庆祝（以及被点一下）时短暂放大窗口，让「捧腹大笑」看得更清楚。
    ///
    /// 为什么放大窗口就能放大形象：相机的垂直视角固定、距离固定，
    /// 形象在窗口里占的高度比例不变，所以窗口高一倍、画出来的形象也大一倍。
    func animateCelebrationScale(scale: CGFloat = 1.28, hold: TimeInterval = 1.3) {
        celebrationTimer?.invalidate()
        baseFrame = frame
        let target = max(1.0, min(1.35, scale))
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(baseFrame) }) ?? NSScreen.main
        let screenFrame = screen?.frame ?? baseFrame
        let duration: TimeInterval = hold + 2.2
        let started = CACurrentMediaTime()
        celebrationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - started
            let shrink = elapsed <= hold ? 0 : min(1, (elapsed - hold) / (duration - hold))
            let current = 1 + (target - 1) * (1 - shrink)
            let w = self.baseFrame.width * current
            let h = self.baseFrame.height * current
            // 以形象中心为基准放大，但左边缘不越过原位——右边就是刘海，压上去会被物理挖空。
            var x = self.baseFrame.midX - w / 2
            var y = self.baseFrame.maxY - h
            x = max(x, self.baseFrame.minX)
            x = min(max(x, screenFrame.minX), screenFrame.maxX - w)
            y = max(screenFrame.minY, y)
            self.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: false)
            if shrink >= 1 {
                timer.invalidate()
                self.setFrame(self.baseFrame, display: true, animate: false)
                self.celebrationTimer = nil
            }
        }
    }
}

// MARK: - 气泡窗

final class BubbleView: NSView {
    var title: String = "" { didSet { needsDisplay = true } }
    var body: String? { didSet { needsDisplay = true } }

    private let padding: CGFloat = 10
    private let tailHeight: CGFloat = 6
    private let maxTitleWidth: CGFloat = 230
    private let maxBodyWidth: CGFloat = 230
    private let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private let bodyFont = NSFont.systemFont(ofSize: 11, weight: .regular)

    private var titleAttrs: [NSAttributedString.Key: Any] {
        [.font: titleFont, .foregroundColor: NSColor(white: 0.97, alpha: 1)]
    }
    private var bodyAttrs: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor(white: 0.82, alpha: 1)]
    }

    private func textSize(_ text: String, _ attrs: [NSAttributedString.Key: Any], maxWidth: CGFloat) -> NSSize {
        let rect = (text as NSString).boundingRect(with: NSSize(width: maxWidth, height: 400),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: attrs)
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// 按文字算窗口该多大。标题也要限宽换行——会话标题可能很长，
    /// 不限的话气泡会横穿整个屏幕（实测没限之前到过 280pt 宽）。
    func measure() -> NSSize {
        let titleSize = textSize(title, titleAttrs, maxWidth: maxTitleWidth)
        var bodySize = NSSize.zero
        if let body, !body.isEmpty {
            bodySize = textSize(body, bodyAttrs, maxWidth: maxBodyWidth)
        }
        let contentWidth = max(titleSize.width, bodySize.width)
        let width = ceil(contentWidth + padding * 2)
        var height = ceil(titleSize.height + padding * 2 + tailHeight)
        if bodySize.height > 0 { height += ceil(bodySize.height + 3) }
        return NSSize(width: max(width, 92), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let contentRect = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - tailHeight)
        let radius: CGFloat = 9

        // 小尖角朝上，指向形象
        let tail = NSBezierPath()
        let tailX = max(radius + 12, contentRect.maxX - 24)
        tail.move(to: NSPoint(x: tailX - 7, y: contentRect.maxY - 1))
        tail.line(to: NSPoint(x: tailX, y: bounds.maxY))
        tail.line(to: NSPoint(x: tailX + 7, y: contentRect.maxY - 1))
        tail.close()

        let box = NSBezierPath(roundedRect: contentRect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        box.append(tail)

        NSColor(srgbRed: 0.07, green: 0.09, blue: 0.14, alpha: 0.93).setFill()
        box.fill()
        NSColor(srgbRed: 0.42, green: 0.78, blue: 1.0, alpha: 0.55).setStroke()
        box.lineWidth = 1
        box.stroke()

        let textRect = NSRect(x: padding,
                              y: padding,
                              width: contentRect.width - padding * 2,
                              height: contentRect.height - padding * 2)
        let titleBounds = textSize(title, titleAttrs, maxWidth: textRect.width)
        let titleRect = NSRect(x: textRect.minX,
                               y: textRect.maxY - titleBounds.height,
                               width: textRect.width,
                               height: titleBounds.height)
        (title as NSString).draw(with: titleRect,
                                 options: [.usesLineFragmentOrigin, .usesFontLeading],
                                 attributes: titleAttrs)
        if let body, !body.isEmpty {
            let bodyBounds = textSize(body, bodyAttrs, maxWidth: textRect.width)
            let bodyRect = NSRect(x: textRect.minX,
                                  y: titleRect.minY - 3 - bodyBounds.height,
                                  width: textRect.width,
                                  height: bodyBounds.height)
            (body as NSString).draw(with: bodyRect,
                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                    attributes: bodyAttrs)
        }
    }
}

final class BubbleWindow: NSPanel {
    private let bubbleView = BubbleView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        contentView = bubbleView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 在形象窗下方弹一条气泡，右边缘尽量和形象对齐。
    func present(title: String, body: String?, below avatarFrame: NSRect, screen: NSRect, seconds: Double) {
        bubbleView.title = title
        bubbleView.body = body
        let size = bubbleView.measure()
        var x = avatarFrame.midX - size.width + 18
        x = min(max(x, screen.minX + 6), screen.maxX - size.width - 6)
        // 尖角在气泡右上角，指向形象；气泡整体压在菜单栏下面一点。
        let y = avatarFrame.minY - size.height - 4
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        bubbleView.frame = NSRect(origin: .zero, size: size)
        bubbleView.needsDisplay = true

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        perform(#selector(fadeOut), with: nil, afterDelay: seconds)
    }

    @objc private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    func hideNow() {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        orderOut(nil)
    }
}
