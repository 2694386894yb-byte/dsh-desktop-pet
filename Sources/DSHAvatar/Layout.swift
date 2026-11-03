// 菜单栏几何与摆放规则。
//
// 全部用屏幕坐标（左下原点），单位 pt。实测本机（2026-10-02）：
//   screen.frame        = 0,0 1470×956
//   screen.visibleFrame = 0,48 1470×875   → 菜单栏高 33pt，Dock 48pt
//   safeAreaInsets.top  = 32               → 有刘海
//   刘海左侧空白区       = x 0..646
//   刘海右侧空白区       = x 825..1470
//   刘海宽 179pt，物理挖空，**像素不存在**，形象绝不能摆在那里。
import AppKit

enum AvatarSize: String, Codable, CaseIterable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    /// 形象在屏幕上的目标高度。
    ///
    /// 菜单栏本体 33pt（带刘海机型）。圆润鸟形需要更宽的窗口和更大尺寸，
    /// 中号默认 76pt 高，明显大于旧机器人，同时窗口仍避开刘海。
    var avatarHeight: CGFloat {
        switch self {
        case .small: return 40
        case .medium: return 76
        case .large: return 88
        }
    }

    var next: AvatarSize {
        switch self {
        case .small: return .medium
        case .medium: return .large
        case .large: return .small
        }
    }
}

/// 菜单栏几何：屏幕、可见区、刘海两侧的可用空白。
struct BarGeometry {
    let screen: NSRect
    let visible: NSRect
    let safeTop: CGFloat
    let notchLeft: NSRect?
    let notchRight: NSRect?

    init(screen screenRef: NSScreen) {
        self.screen = screenRef.frame
        self.visible = screenRef.visibleFrame
        self.safeTop = screenRef.safeAreaInsets.top
        self.notchLeft = screenRef.auxiliaryTopLeftArea
        self.notchRight = screenRef.auxiliaryTopRightArea
    }

    /// 显式几何（给测试用，NX 屏造不出来）。
    init(screen: NSRect, visible: NSRect, safeTop: CGFloat, notchLeft: NSRect?, notchRight: NSRect?) {
        self.screen = screen
        self.visible = visible
        self.safeTop = safeTop
        self.notchLeft = notchLeft
        self.notchRight = notchRight
    }

    /// 菜单栏高度：屏幕顶到可见区顶的距离。
    var barHeight: CGFloat { max(0, screen.maxY - visible.maxY) }

    /// 刘海（物理挖空）矩形；没刘海时为 nil。
    var notch: NSRect? {
        guard let l = notchLeft, let r = notchRight, r.minX > l.maxX else { return nil }
        let h = max(safeTop, barHeight)
        return NSRect(x: l.maxX, y: screen.maxY - h, width: r.minX - l.maxX, height: h)
    }

    var hasNotch: Bool { notch != nil }

    /// 默认落点：紧贴刘海右侧那一段留白。
    ///
    /// 为什么不放更靠右：右边那一片是状态项（图标）+ 时钟的地盘，它们会随
    /// 用户装了什么而左右移动；紧贴刘海右侧是全场唯一「谁都还没占」的位置。
    /// 没有刘海的机器就退到距右边缘 300pt，给时钟和状态项留常规位置。
    func defaultAnchorX(windowWidth: CGFloat) -> CGFloat {
        if let n = notch {
            return n.maxX + 3
        }
        return screen.maxX - 300
    }

    /// 把窗口左边缘夹到合法位置：不出屏、不压刘海。
    func clampX(_ x: CGFloat, windowWidth: CGFloat) -> CGFloat {
        var v = min(max(x, screen.minX), screen.maxX - windowWidth)
        if let n = notch {
            let w = NSRect(x: v, y: screen.maxY - barHeight, width: windowWidth, height: barHeight)
            if w.intersects(n) {
                // 就近推到刘海左侧或右侧；两边都放不下就贴右边。
                let leftX = n.minX - windowWidth - 3
                let rightX = n.maxX + 3
                let fitsLeft = leftX >= screen.minX
                let fitsRight = rightX + windowWidth <= screen.maxX
                if fitsLeft && (!fitsRight || abs(v - leftX) <= abs(v - rightX)) {
                    v = leftX
                } else if fitsRight {
                    v = rightX
                } else {
                    v = max(screen.minX, min(v, screen.maxX - windowWidth))
                }
            }
        }
        return v
    }

    /// 窗口尺寸：形象高度 + 一点余量（上下留白，粒子爆发不会被硬切）。
    func windowSize(for size: AvatarSize) -> NSSize {
        let h = size.avatarHeight
        return NSSize(width: ceil(h * 1.25), height: ceil(h + 5))
    }

    /// 窗口矩形：顶边贴屏幕顶（= 菜单栏顶部），水平位置由 anchorX 决定。
    func windowFrame(anchorX: CGFloat?, size: AvatarSize) -> NSRect {
        let s = windowSize(for: size)
        let x = clampX(anchorX ?? defaultAnchorX(windowWidth: s.width), windowWidth: s.width)
        return NSRect(x: x, y: screen.maxY - s.height, width: s.width, height: s.height)
    }
}
