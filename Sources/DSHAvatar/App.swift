// DeepSeek 桌宠：菜单栏 3D 形象与 DSH 会话联动。
//
//   Sources/DSHAvatar/App.swift        — 控制器：窗口、状态栏菜单与截图入口
//   Sources/DSHAvatar/main.swift       — 进程入口与命令行参数
//   Sources/DSHAvatar/AvatarRig.swift  — SceneKit 形象与逐帧动画
//   Sources/DSHAvatar/AvatarWindow.swift — 菜单栏上的透明窗 + 气泡窗
//   Sources/DSHAvatar/Signal.swift     — 旧版纯逻辑模块（不接入运行时）
//   Sources/DSHAvatar/Layout.swift     — 菜单栏几何与摆放规则
//   Sources/DSHAvatar/Prefs.swift      — 偏好落盘
import AppKit
import SceneKit

/// 命令行参数（也用于自动化验证：--diag / --render / --demo）。
struct Arguments {
    var diag = false
    var render: String?
    var mood: String?
    var demo = false
    var positioning = false
    var stateDir: String?
    var sessionsDir: String?
    var exitAfter: Double?
    var size: AvatarSize?

    init(_ argv: [String]) {
        var i = 1
        func next() -> String? {
            i += 1
            return i < argv.count ? argv[i] : nil
        }
        while i < argv.count {
            switch argv[i] {
            case "--diag": diag = true
            case "--demo": demo = true
            case "--position": positioning = true
            case "--render": render = next()
            case "--mood": mood = next()
            case "--state-dir": stateDir = next()
            case "--sessions-dir": sessionsDir = next()
            case "--exit-after": exitAfter = next().flatMap(Double.init)
            case "--size": size = next().flatMap(AvatarSize.init(rawValue:))
            default: break
            }
            i += 1
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    let args: Arguments
    private let prefs = Prefs.shared
    private let geometry: BarGeometry
    private let rig = AvatarRig()

    private var avatarWindow: AvatarWindow!
    private var sceneView: AvatarSceneView!
    private var overlay: PositioningOverlay?
    private var bubble = BubbleWindow()
    private var statusItem: NSStatusItem?

    private var stateTimer: Timer?
    private lazy var sessionWatcher: SessionWatcher = {
        let root = args.sessionsDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? SessionStore.defaultRoot()
        return SessionWatcher(root: root)
    }()
    private var signalTracker = SignalTracker()

    private var lastActivity = Date()
    private var statusLine = "DeepSeek 已就绪"
    private var listeningPaused = false
    private var hasActiveDSHSession = false
    private(set) var positioning = false
    private var bootedAt = Date()

    init(args: Arguments) {
        self.args = args
        let screen = NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0]
        self.geometry = BarGeometry(screen: screen)
        super.init()
        if let s = args.size { prefs.mutate { $0.size = s } }
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildAvatarWindow()
        if !args.diag { buildStatusItem() }
        // --mood 是「静态摆拍」模式：不接外部信号，
        // 渲染出来的就不是想验证的那个状态了。
        startStateTimer()
        if args.mood == nil && !args.diag && args.render == nil {
            startSessionWatcher()
        }

        if args.demo { runDemo() }
        if args.positioning { setPositioning(true) }
        if let exitAfter = args.exitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + exitAfter) { NSApp.terminate(nil) }
        }
        if let moodName = args.mood, let m = AvatarRig.Mood(rawValue: moodName) {
            rig.setMood(m)
            if m == .celebrate {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.rig.celebrate()
                    self?.avatarWindow.animateCelebrationScale()
                }
            }
        }
        if args.diag || args.render != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.finishVerificationRun()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateTimer?.invalidate()
        sessionWatcher.stop()
    }

    // MARK: - 窗口

    private func buildAvatarWindow() {
        let frame = geometry.windowFrame(anchorX: prefs.values.anchorX, size: prefs.values.size)
        avatarWindow = AvatarWindow(frame: frame)
        sceneView = AvatarSceneView(frame: NSRect(origin: .zero, size: frame.size))
        rig.configure(sceneView, frame: NSRect(origin: .zero, size: frame.size))
        sceneView.autoresizingMask = [.width, .height]
        sceneView.onTap = { [weak self] in
            guard let self else { return }
            self.rig.laughBriefly()
            self.avatarWindow.animateCelebrationScale(scale: 1.16, hold: 1.0)
            self.showBubble(title: "哈哈哈哈哈！", body: nil, seconds: 1.8)
        }
        sceneView.onRightClick = { [weak self] event in self?.popUpMenu(with: event) }
        sceneView.onDragEnded = { [weak self] x in self?.dragged(to: x) }
        avatarWindow.contentView = sceneView
        avatarWindow.ignoresMouseEvents = prefs.values.clickThrough
        avatarWindow.orderFrontRegardless()
    }

    private func applyPrefs() {
        bubble.hideNow()
        if let win = avatarWindow {
            win.setFrame(geometry.windowFrame(anchorX: prefs.values.anchorX, size: prefs.values.size), display: true)
            rig.fitCamera(viewSize: win.frame.size)
            win.ignoresMouseEvents = prefs.values.clickThrough && !positioning
        }
    }

    private func setPositioning(_ on: Bool) {
        guard avatarWindow != nil else { return }
        positioning = on
        sceneView.isPositioning = on
        avatarWindow.ignoresMouseEvents = on ? false : prefs.values.clickThrough
        if on {
            if overlay == nil {
                let o = PositioningOverlay(frame: NSRect(origin: .zero, size: avatarWindow.frame.size))
                o.autoresizingMask = [.width, .height]
                sceneView.addSubview(o)
                overlay = o
            }
            statusLine = "拖动中：把形象拖到任意留白处，松手即记住"
        } else {
            overlay?.removeFromSuperview()
            overlay = nil
        }
    }

    private func dragged(to x: CGFloat) {
        let width = avatarWindow.frame.width
        let clamped = geometry.clampX(x, windowWidth: width)
        var frame = avatarWindow.frame
        frame.origin.x = clamped
        avatarWindow.setFrameOrigin(frame.origin)
        prefs.mutate { $0.anchorX = clamped }
    }

    // MARK: - 状态栏菜单

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "DeepSeek 桌宠")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "DeepSeek 桌宠")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "DeepSeek 桌宠"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    private func popUpMenu(with event: NSEvent) {
        guard let menu = statusItem?.menu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y - 6),
                   in: sceneView)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = hasActiveDSHSession ? "DeepSeek 正在工作" : "DeepSeek 桌宠"
        for line in ["\(header) · \(statusLine)"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, "试一下动画（跳一下）", #selector(demoAnimation))
        add(menu, listeningPaused ? "继续监听 DSH" : "暂停监听 DSH", #selector(toggleListening))
        add(menu, avatarWindow?.isVisible == true ? "隐藏形象" : "显示形象", #selector(toggleVisible))
        menu.addItem(.separator())

        let sizeItem = NSMenuItem(title: "形象大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for s in AvatarSize.allCases {
            let i = NSMenuItem(title: s.title, action: #selector(setSize(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = s.rawValue
            i.state = prefs.values.size == s ? .on : .off
            sizeMenu.addItem(i)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let posItem = NSMenuItem(title: "位置", action: nil, keyEquivalent: "")
        let posMenu = NSMenu()
        let drag = NSMenuItem(title: positioning ? "结束拖动调整" : "拖动调整位置…",
                              action: #selector(togglePositioning), keyEquivalent: "")
        drag.target = self
        drag.state = positioning ? .on : .off
        posMenu.addItem(drag)
        let reset = NSMenuItem(title: "回到默认位置（刘海右侧）", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        posMenu.addItem(reset)
        posItem.submenu = posMenu
        menu.addItem(posItem)
        menu.addItem(.separator())

        addToggle(menu, "点击穿透（不挡菜单栏）", prefs.values.clickThrough, #selector(toggleClickThrough))
        addToggle(menu, "显示互动气泡", prefs.values.showBubble, #selector(toggleBubble))
        addToggle(menu, "开机自动启动", prefs.values.launchAtLogin, #selector(toggleLogin))
        menu.addItem(.separator())
        add(menu, "打开使用说明", #selector(openReadme))
        add(menu, "打开数据目录", #selector(openDataDir))
        add(menu, "复制诊断信息", #selector(copyDiag))
        menu.addItem(.separator())
        add(menu, "退出", #selector(quit))
    }

    private func add(_ menu: NSMenu, _ title: String, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func addToggle(_ menu: NSMenu, _ title: String, _ on: Bool, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    // MARK: - 菜单动作

    @objc private func demoAnimation() {
        runDemo()
    }

    @objc private func toggleListening() {
        listeningPaused.toggle()
        if listeningPaused {
            statusLine = "已暂停 DSH 监听"
            rig.setMood(.paused)
        } else {
            statusLine = "正在监听 DSH 会话"
            lastActivity = Date()
            rig.setMood(hasActiveDSHSession ? .working : .idle)
        }
    }

    @objc private func toggleVisible() {
        guard let win = avatarWindow else { return }
        if win.isVisible {
            win.orderOut(nil)
            bubble.hideNow()
        } else {
            win.orderFrontRegardless()
        }
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = AvatarSize(rawValue: raw) else { return }
        prefs.mutate { $0.size = s }
        applyPrefs()
    }

    @objc private func togglePositioning() {
        setPositioning(!positioning)
    }

    @objc private func resetPosition() {
        prefs.mutate { $0.anchorX = nil }
        applyPrefs()
    }

    @objc private func toggleClickThrough() {
        prefs.mutate { $0.clickThrough.toggle() }
        avatarWindow.ignoresMouseEvents = prefs.values.clickThrough && !positioning
    }

    @objc private func toggleBubble() {
        prefs.mutate { $0.showBubble.toggle() }
        if !prefs.values.showBubble { bubble.hideNow() }
    }


    @objc private func toggleLogin() {
        let target = !prefs.values.launchAtLogin
        let error = LoginItem.apply(enabled: target)
        if error == nil {
            prefs.mutate { $0.launchAtLogin = target }
        } else {
            statusLine = "开机自启设置失败：\(error ?? "")"
        }
    }

    @objc private func openReadme() {
        if let url = Bundle.main.url(forResource: "README", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
    }

    @objc private func openDataDir() {
        try? FileManager.default.createDirectory(at: prefs.home, withIntermediateDirectories: true)
        NSWorkspace.shared.open(prefs.home)
    }

    @objc private func copyDiag() {
        let json = diagnostics().json
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        statusLine = "诊断信息已复制到剪贴板"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Pet idle state

    private func startStateTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tickState() }
        RunLoop.main.add(timer, forMode: .common)
        stateTimer = timer
    }

    private func startSessionWatcher() {
        sessionWatcher.onChange = { [weak self] scan in self?.handleSessionScan(scan) }
        sessionWatcher.start()
        statusLine = "监听 DSH 会话中（\(sessionWatcher.directory.path)）"
    }

    private func handleSessionScan(_ scan: SessionWatcher.Scan) {
        if let newest = scan.newest {
            statusLine = newest.working
                ? "正在处理：\(newest.displayName)"
                : "已连接：\(newest.displayName)"
        }
        guard !listeningPaused else { return }
        if let newest = scan.newest {
            hasActiveDSHSession = newest.working
            if newest.working && !listeningPaused {
                lastActivity = Date()
                rig.setMood(.working)
            } else if !newest.working && rig.mood == .working {
                rig.setMood(.idle)
            }
        }
        for snap in scan.changed {
            let events = signalTracker.ingest([snap])
            for event in events {
                lastActivity = Date()
                switch event {
                case .started(let session):
                    hasActiveDSHSession = true
                    statusLine = "正在处理：\(session.displayName)"
                    rig.setMood(.working)
                case .result(let session, let turn):
                    hasActiveDSHSession = false
                    statusLine = "新结果：\(session.displayName)"
                    rig.celebrate()
                    avatarWindow.animateCelebrationScale()
                    let snippet = prefs.values.bubbleShowsSnippet ? Snippet.oneLine(turn.response) : nil
                    showBubble(title: "✓ 新结果 · \(session.displayName)", body: snippet, seconds: prefs.values.bubbleSeconds)
                case .stopped(let session):
                    hasActiveDSHSession = false
                    statusLine = "已停止：\(session.displayName)"
                    rig.setMood(.idle)
                }
            }
        }
    }

    private func tickState() {
        guard avatarWindow != nil else { return }
        if listeningPaused { return }
        if !listeningPaused && hasActiveDSHSession {
            if rig.mood != .working { rig.setMood(.working) }
            return
        }
        let idleFor = Date().timeIntervalSince(lastActivity)
        if idleFor > prefs.values.sleepAfter {
            if rig.mood != .sleep { rig.setMood(.sleep) }
        } else if idleFor > prefs.values.workingTimeout {
            if rig.mood == .working { rig.setMood(.idle) }
        }
    }

    private func showBubble(title: String, body: String?, seconds: Double) {
        guard prefs.values.showBubble, avatarWindow.isVisible else { return }
        bubble.present(title: title, body: body,
                       below: avatarWindow.frame,
                       screen: geometry.screen,
                       seconds: seconds)
    }

    private func runDemo() {
        statusLine = "演示中"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.rig.setMood(.working)
            self.showBubble(title: "⏳ 演示：正在干活", body: "眨眼、轻扑翅，头顶金光闪一下", seconds: 3.0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self else { return }
            self.rig.celebrate()
            self.avatarWindow.animateCelebrationScale()
            self.showBubble(title: "✓ 演示：出了新结果", body: "放大、弯腰抱肚，捧腹笑几秒", seconds: 4.8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.4) { [weak self] in
            self?.rig.setMood(.idle)
        }
    }

    // MARK: - 自检（--diag / --render）

    /// 形象在画面上**真实渲染出来**的矩形（pt，视图坐标）。
    ///
    /// 为什么不投影包围盒：包围盒会把不可见装饰（轨道环、光柱）和粒子的空间都算进去，
    /// 与用户真正看到的形状对不上。直接量像素才是「所见即所得」的证据。
    private func renderedCharacterRect(from image: NSImage) -> NSRect? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / max(sceneView.bounds.width, 1)
        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.06 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // 位图 y 轴朝下 → 翻回视图坐标（原点左下）。
        let viewH = sceneView.bounds.height
        return NSRect(x: CGFloat(minX) / scale,
                      y: viewH - CGFloat(maxY + 1) / scale,
                      width: CGFloat(maxX - minX + 1) / scale,
                      height: CGFloat(maxY - minY + 1) / scale)
    }

    /// 快照里「有东西」的像素比例：0 = 空白，1 = 糊满。
    private func coverage(of image: NSImage) -> Double {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return -1 }
        var total = 0
        var painted = 0
        let step = 2
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                total += 1
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.06 { painted += 1 }
                x += step
            }
            y += step
        }
        return total == 0 ? -1 : Double(painted) / Double(total)
    }

    /// 自检报告用的极简 JSON 树。
    ///
    /// 为什么不用 JSONSerialization：Swift 的值类型（CGFloat / 嵌套字典）装进 Any 会变成
    /// __SwiftValue，JSONSerialization 直接抛 NSInvalidArgumentException 把 App 打死
    /// （实测两次）。自己渲染一层反而更短、更可预测，键顺序也由我们说了算。
    indirect enum JSON {
        case str(String), num(Double), int(Int), bool(Bool), arr([JSON]), obj([(String, JSON)]), nul

        var text: String { JSON.render(self, 0) }

        static func render(_ node: JSON, _ indent: Int) -> String {
            let pad = String(repeating: " ", count: indent)
            let inner = String(repeating: " ", count: indent + 2)
            switch node {
            case .str(let s): return "\"\(escape(s))\""
            case .num(let d): return String(format: "%.4f", d)
            case .int(let i): return String(i)
            case .bool(let b): return b ? "true" : "false"
            case .nul: return "null"
            case .arr(let items):
                if items.isEmpty { return "[]" }
                return "[\n" + items.map { inner + render($0, indent + 2) }.joined(separator: ",\n") + "\n" + pad + "]"
            case .obj(let pairs):
                if pairs.isEmpty { return "{}" }
                return "{\n" + pairs.map { inner + "\"\(escape($0.0))\": " + render($0.1, indent + 2) }
                    .joined(separator: ",\n") + "\n" + pad + "}"
            }
        }

        private static func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
    }

    private func rectJSON(_ r: NSRect) -> JSON {
        .obj([("x", .num(Double(r.origin.x))), ("y", .num(Double(r.origin.y))),
              ("w", .num(Double(r.width))), ("h", .num(Double(r.height)))])
    }

    /// 汇总一份可机器校验的自检报告。
    func diagnostics() -> (json: String, ok: Bool) {
        let win = avatarWindow.frame
        let screen = geometry.screen
        let notch = geometry.notch
        let viewSize = sceneView.bounds.size
        let snapshot = sceneView.snapshot()
        let cover = coverage(of: snapshot)
        let charRect = renderedCharacterRect(from: snapshot) ?? .zero

        let insideScreen = screen.contains(win)
        let topAligned = abs(win.maxY - screen.maxY) <= 1.0
        let aboveMenuBar = avatarWindow.level.rawValue > Int(CGWindowLevelForKey(.statusWindow))
        let avoidsNotch = notch == nil || !win.intersects(notch!)
        let charFitsHorizontally = charRect.minX >= 0.25 && charRect.maxX <= viewSize.width - 0.25
        let charFitsVertically = charRect.minY >= 0.25 && charRect.maxY <= viewSize.height - 0.25
        let fill = charRect.height / max(viewSize.height, 1)
        let fillOk = fill >= 0.50 && fill <= 0.98
        let coverOk = cover > 0.03 && cover < 0.60
        let ok = insideScreen && topAligned && aboveMenuBar && avoidsNotch
            && charFitsHorizontally && charFitsVertically && fillOk && coverOk

        let tree = JSON.obj([
            ("ok", .bool(ok)),
            ("screen", .obj([
                ("frame", rectJSON(screen)),
                ("visibleFrame", rectJSON(geometry.visible)),
                ("menuBarHeight", .num(Double(geometry.barHeight))),
                ("safeAreaTop", .num(Double(geometry.safeTop))),
                ("hasNotch", .bool(geometry.hasNotch)),
                ("notch", notch.map(rectJSON) ?? .nul),
            ])),
            ("window", .obj([
                ("frame", rectJSON(win)),
                ("w", .num(Double(win.width))),
                ("h", .num(Double(win.height))),
                ("level", .int(avatarWindow.level.rawValue)),
                ("statusItemLevel", .int(Int(CGWindowLevelForKey(.statusWindow)))),
                ("menuBarLevel", .int(Int(CGWindowLevelForKey(.mainMenuWindow)))),
                ("isVisible", .bool(avatarWindow.isVisible)),
                ("ignoresMouseEvents", .bool(avatarWindow.ignoresMouseEvents)),
                ("isOnActiveSpace", .bool(avatarWindow.isOnActiveSpace)),
            ])),
            ("checks", .obj([
                ("insideScreen", .bool(insideScreen)),
                ("topAligned", .bool(topAligned)),
                ("aboveMenuBar", .bool(aboveMenuBar)),
                ("avoidsNotch", .bool(avoidsNotch)),
                ("characterFitsHorizontally", .bool(charFitsHorizontally)),
                ("characterFitsVertically", .bool(charFitsVertically)),
                ("characterFillPlausible", .bool(fillOk)),
                ("coverageInRange", .bool(coverOk)),
            ])),
            ("character", .obj([
                ("renderedRect", rectJSON(charRect)),
                ("viewW", .num(Double(viewSize.width))),
                ("viewH", .num(Double(viewSize.height))),
                ("fillOfWindowHeight", .num(Double(fill))),
                ("coverage", .num(cover)),
                ("modelMin", .obj([("x", .num(Double(rig.debugGeometry().lo.x))),
                                   ("y", .num(Double(rig.debugGeometry().lo.y))),
                                   ("z", .num(Double(rig.debugGeometry().lo.z)))])),
                ("modelMax", .obj([("x", .num(Double(rig.debugGeometry().hi.x))),
                                   ("y", .num(Double(rig.debugGeometry().hi.y))),
                                   ("z", .num(Double(rig.debugGeometry().hi.z)))])),
                ("cameraZ", .num(Double(rig.debugGeometry().distance))),
            ])),
            ("state", .obj([
                ("mood", .str(rig.mood.rawValue)),
                ("statusLine", .str(statusLine)),
                ("product", .str("DeepSeek 桌宠")),
            ])),
            ("prefs", .obj([
                ("path", .str(prefs.fileURL.path)),
                ("size", .str(prefs.values.size.rawValue)),
                ("anchorX", prefs.values.anchorX.map { JSON.num(Double($0)) } ?? .nul),
                ("clickThrough", .bool(prefs.values.clickThrough)),
                ("lastWriteError", prefs.lastWriteError.map { JSON.str($0) } ?? .nul),
            ])),
        ])
        return (tree.text, ok)
    }

    private func finishVerificationRun() {
        if let path = args.render {
            let image = sceneView.snapshot()
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                print("已写出渲染图：\(path)（\(rep.pixelsWide)×\(rep.pixelsHigh)，覆盖率 \(String(format: "%.3f", coverage(of: image)))）")
            } else {
                print("渲染失败：拿不到位图")
                exit(2)
            }
        }
        if args.diag {
            let result = diagnostics()
            print(result.json)
            exit(result.ok ? 0 : 1)
        }
        if args.render != nil { exit(0) }
    }
}

// MARK: - 开机自启

enum LoginItem {
    static let label = "com.example.dshavatar"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// 返回 nil 表示成功；否则返回人话原因。
    static func apply(enabled: Bool) -> String? {
        let fm = FileManager.default
        if enabled {
            guard let exe = Bundle.main.executableURL?.path else { return "拿不到可执行文件路径" }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            do {
                try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
            } catch {
                return "写 LaunchAgents 失败：\(error.localizedDescription)"
            }
            run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
            return fm.fileExists(atPath: plistURL.path) ? nil : "plist 没写成功"
        } else {
            run("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
            try? fm.removeItem(at: plistURL)
            return nil
        }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
