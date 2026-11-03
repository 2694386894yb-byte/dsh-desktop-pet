// 探针：验证「第三方窗口能不能盖住 macOS 菜单栏」，并打印放置 3D 形象要用的几何。
//
// 只做两件事：
//   1. 在菜单栏高度上开一个无边框透明窗口，画一块亮粉色 + 白圆；
//   2. 把屏幕几何、刘海两侧的空白区（auxiliaryTopLeft/RightArea）、
//      窗口真实层级、occlusionState 写进 /tmp/dsh-avatar-probe.txt。
//
// 判定标准：截图里那块亮粉色**盖住了菜单栏**（而不是被菜单栏盖住/看不见）。
import AppKit

final class ProbeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemPink.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14)).fill()
    }
}

func rectString(_ r: NSRect) -> String {
    String(format: "x=%.0f y=%.0f w=%.0f h=%.0f", r.origin.x, r.origin.y, r.size.width, r.size.height)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.screens.first else { exit(2) }

var report: [String] = []
report.append("时间：\(ISO8601DateFormatter().string(from: Date()))")
report.append("屏幕数量：\(NSScreen.screens.count)")
report.append("screen.frame          = \(rectString(screen.frame))")
report.append("screen.visibleFrame   = \(rectString(screen.visibleFrame))")
report.append("菜单栏高度（推算）      = \(screen.frame.maxY - screen.visibleFrame.maxY) pt")
report.append("screen.safeAreaInsets = top=\(screen.safeAreaInsets.top) left=\(screen.safeAreaInsets.left) bottom=\(screen.safeAreaInsets.bottom) right=\(screen.safeAreaInsets.right)")
if #available(macOS 12.0, *) {
    let l = screen.auxiliaryTopLeftArea, r = screen.auxiliaryTopRightArea
    report.append("刘海左侧空白区         = \(l.map(rectString) ?? "nil")")
    report.append("刘海右侧空白区         = \(r.map(rectString) ?? "nil")")
    report.append("刘海宽度（推算）        = \(l != nil && r != nil ? screen.frame.width - l!.width - r!.width : 0) pt")
}

let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
let winSize = NSSize(width: 150, height: barHeight)
// 先钉在菜单栏右半部分的空白处（x=620 起），只是为了截图能一眼看到。
let origin = NSPoint(x: screen.frame.minX + 620, y: screen.frame.maxY - barHeight)
let win = NSWindow(contentRect: NSRect(origin: origin, size: winSize),
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
win.isOpaque = false
win.backgroundColor = .clear
win.hasShadow = false
win.ignoresMouseEvents = true
win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
// 关键：层级必须高过 kCGMainMenuWindowLevel(24) 与状态项(25)。
let levels: [(String, NSWindow.Level)] = [
    ("screenSaver(1000)", NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))),
]
win.level = levels[0].1
win.contentView = ProbeView(frame: NSRect(origin: .zero, size: winSize))
win.orderFrontRegardless()

report.append("窗口 frame            = \(rectString(win.frame))")
report.append("窗口 level            = \(win.level.rawValue)（menu bar = \(CGWindowLevelForKey(.mainMenuWindow)), status item = \(CGWindowLevelForKey(.statusWindow))）")
report.append("窗口 ignoresMouseEvents = \(win.ignoresMouseEvents)")
report.append("窗口 isVisible          = \(win.isVisible)")
report.append("窗口 occlusionState     = \(win.occlusionState.rawValue)（2 = visible）")

// 再从 WindowServer 的角度确认一次：这扇窗真的在系统窗口列表里，且层级是我设的那个。
if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
    for entry in list {
        let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
        guard owner.contains("probe") || owner.contains("DSH") else { continue }
        let layer = entry[kCGWindowLayer as String] as? Int ?? -999
        let num = entry[kCGWindowNumber as String] as? Int ?? -1
        let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
        report.append("WindowServer: owner=\(owner) id=\(num) layer=\(layer) bounds=\(boundsDict)")
    }
}

report.append("结论：见截图——粉色块若盖住菜单栏，则 .screenSaver 层级可用。")
let out = report.joined(separator: "\n") + "\n"
try? out.write(toFile: "/tmp/dsh-avatar-probe.txt", atomically: true, encoding: .utf8)
FileHandle.standardOutput.write(out.data(using: .utf8)!)

// 活 12 秒足够截图，然后自己退出。
DispatchQueue.main.asyncAfter(deadline: .now() + 12) { app.terminate(nil) }
app.run()
