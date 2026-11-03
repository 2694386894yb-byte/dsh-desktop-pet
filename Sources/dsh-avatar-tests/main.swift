// 纯逻辑单元测试（本机没有 Xcode，也就没有 XCTest，所以自带极简断言器）。
//
// 测的是「不依赖屏幕、不依赖 DSH 真在跑」的那部分：
//   1. 菜单栏几何：默认落点、刘海避让、贴顶摆放
//   2. 结果状态机：什么时候该跳、什么时候不该跳、子代理会话要不要理
//   3. 文本摘要：Markdown 清理与截断
import AppKit

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ \(label)\(detail.isEmpty ? "" : " —— \(detail)")")
    }
}

func section(_ name: String) { print("\n[\(name)]") }

// MARK: 1. 菜单栏几何

section("菜单栏几何（本机实测数据：1470×956，菜单栏 33pt，刘海 179pt）")
let screenRect = NSRect(x: 0, y: 0, width: 1470, height: 956)
let visibleRect = NSRect(x: 0, y: 48, width: 1470, height: 875)
let leftArea = NSRect(x: 0, y: 924, width: 646, height: 32)
let rightArea = NSRect(x: 825, y: 924, width: 645, height: 32)
let notchGeo = BarGeometry(screen: screenRect, visible: visibleRect, safeTop: 32, notchLeft: leftArea, notchRight: rightArea)

check(abs(notchGeo.barHeight - 33) < 0.01, "菜单栏高度 = 33pt")
check(notchGeo.hasNotch, "识别出刘海")
check(notchGeo.notch?.width == 179, "刘海宽度 = 179pt", "实际 \(notchGeo.notch?.width ?? -1)")
check(notchGeo.notch?.minX == 646 && notchGeo.notch?.maxX == 825, "刘海区间 646..825")

let medium = notchGeo.windowSize(for: .medium)
check(abs(medium.width - 95) < 0.01 && abs(medium.height - 81) < 0.01, "鸟形中号窗口 95×81pt", "实际 \(medium.width)×\(medium.height)")

let defaultX = notchGeo.defaultAnchorX(windowWidth: medium.width)
check(defaultX == 828, "默认落点紧贴刘海右侧（828）", "实际 \(defaultX)")
let defaultFrame = notchGeo.windowFrame(anchorX: nil, size: .medium)
check(abs(defaultFrame.maxY - screenRect.maxY) < 0.01, "窗口顶边贴屏幕顶（菜单栏顶部）")
check(!defaultFrame.intersects(notchGeo.notch!), "默认位置不压刘海")
check(notchGeo.screen.contains(defaultFrame), "默认位置在屏内")

// 用户把形象拖到刘海上 → 必须被推出去
let nudged = notchGeo.windowFrame(anchorX: 700, size: .medium)
check(!nudged.intersects(notchGeo.notch!), "拖到刘海上会被推开", "得到 x=\(nudged.origin.x)")
check(nudged.origin.x == 828 || nudged.origin.x == 646 - medium.width - 3, "推到刘海某一侧", "得到 \(nudged.origin.x)")

// 拖出屏幕 → 必须被夹住
let farLeft = notchGeo.windowFrame(anchorX: -500, size: .medium)
check(farLeft.origin.x == 0, "拖出左边界会被夹回 0", "得到 \(farLeft.origin.x)")
let farRight = notchGeo.windowFrame(anchorX: 5000, size: .medium)
check(abs(farRight.maxX - screenRect.maxX) < 0.01, "拖出右边界会被夹回屏内")

// 无刘海的机器（外接屏）：退回「距右边缘 300pt」
let plainGeo = BarGeometry(screen: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                           visible: NSRect(x: 0, y: 70, width: 1920, height: 985),
                           safeTop: 0, notchLeft: nil, notchRight: nil)
check(!plainGeo.hasNotch, "无刘海机型：hasNotch = false")
check(plainGeo.defaultAnchorX(windowWidth: 38) == 1620, "无刘海默认落点 = 右边缘 -300pt")
check(abs(plainGeo.barHeight - 25) < 0.01, "无刘海菜单栏高度按可见区推算 = 25pt")

// 大中小三档的窗口尺寸
check(AvatarSize.small.avatarHeight < AvatarSize.medium.avatarHeight
      && AvatarSize.medium.avatarHeight < AvatarSize.large.avatarHeight, "三档尺寸递增")
check(AvatarSize.large.next == .small, "尺寸档位循环")

// MARK: 2. 结果状态机

section("结果状态机")

func snapshot(id: String = "s1", title: String = "桌面3D形象消息栏插件",
              cwd: String = "/Users/example/projects",
              turns: [(Int, String)] = [], working: Bool = false,
              updated: Date = Date(timeIntervalSince1970: 1000)) -> SessionSnapshot {
    SessionSnapshot(id: id, title: title, cwd: cwd, updatedAt: updated,
                    turns: turns.enumerated().map { TurnSnapshot(turn: $0.offset + 1, seq: $0.offset, prompt: "p", response: $0.element.1) },
                    steps: turns.count, working: working, draftLength: 0)
}

// 首次看到只做种子，不放烟花
var tracker = SignalTracker()
let bootEvents = tracker.ingest([snapshot(turns: [(1, "早就写好的结果")])])
check(bootEvents.isEmpty, "首次看到已有结果的会话 → 不触发（避免一启动就放烟花）")

// 干活中：先 started
let startEvents = tracker.ingest([snapshot(turns: [(1, "")], working: true)])
check(startEvents == [.started(snapshot(turns: [(1, "")], working: true))], "从空闲进入干活 → started",
      "实际 \(startEvents)")

// 还没干完（response 仍为空）→ 什么也不发
let midEvents = tracker.ingest([snapshot(turns: [(1, "")], working: true)])
check(midEvents.isEmpty, "干活中重复写缓存 → 不重复触发")

// 干完：response 非空且 working 落下 → result（有且只有一次）
let doneSnap = snapshot(turns: [(1, "已经做完了，这是结果")], working: false)
let doneEvents = tracker.ingest([doneSnap])
check(doneEvents.count == 1, "干完一轮 → 恰好一个事件", "实际 \(doneEvents.count)")
if case .result(let s, let t) = doneEvents.first {
    check(s.id == "s1" && t.turn == 1 && t.response.contains("结果"), "result 事件带对了会话与轮次")
} else {
    check(false, "干完一轮 → result 事件", "实际 \(doneEvents)")
}

// 同一条结果再写一次缓存 → 不许再跳
let againEvents = tracker.ingest([doneSnap])
check(againEvents.isEmpty, "同一条结果重复写缓存 → 不重复庆祝")

// 第二轮：干活 → 出结果
_ = tracker.ingest([snapshot(turns: [(1, "第一轮结果"), (2, "")], working: true)])
let secondEvents = tracker.ingest([snapshot(turns: [(1, "第一轮结果"), (2, "第二轮结果")], working: false)])
check(secondEvents.count == 1, "第二轮出结果 → 一个事件", "实际 \(secondEvents.count)")

// 干完但没结果（被打断）→ stopped，不庆祝
var tracker2 = SignalTracker()
_ = tracker2.ingest([snapshot(turns: [(1, "")], working: true)])
let stopEvents = tracker2.ingest([snapshot(turns: [(1, "")], working: false)])
check(stopEvents.count == 1 && stopEvents.first == .stopped(snapshot(turns: [(1, "")], working: false)),
      "干完但没拿到结果 → stopped（不庆祝）", "实际 \(stopEvents)")

// 子代理会话（标题是内部提示词）→ 完全不理
var tracker3 = SignalTracker()
_ = tracker3.ingest([snapshot(id: "sub", title: "<system-reminder> 你是子代理", turns: [(1, "")], working: true)])
let subEvents = tracker3.ingest([snapshot(id: "sub", title: "<system-reminder> 你是子代理", turns: [(1, "子代理结果")], working: false)])
check(subEvents.isEmpty, "子代理会话的结果不触发形象动作")

// 多个会话一起变：只按会话各自去重，不会互相干扰
var tracker4 = SignalTracker()
_ = tracker4.ingest([snapshot(id: "a", turns: [(1, "")], working: true),
                     snapshot(id: "b", turns: [(1, "")], working: true)])
let multi = tracker4.ingest([snapshot(id: "a", turns: [(1, "A 的结果")], working: false),
                             snapshot(id: "b", turns: [(1, "B 的结果")], working: false)])
check(multi.count == 2, "两个会话各自出结果 → 两个事件", "实际 \(multi.count)")

// 显示名：标题是内部提示词时退回目录名
let subName = snapshot(title: "<system-reminder> x", cwd: "/Users/example/projects")
check(subName.displayName == "projects", "标题是内部提示词 → 退回目录名", "实际 \(subName.displayName)")
check(snapshot().displayName == "桌面3D形象消息栏插件", "正常标题直接用")

// MARK: 3. 解析真实投影（用本机真实文件的结构）

section("解析 DSH 投影 JSON")
let sampleJSON = """
{"version":7,"record":{"identity":{"formatVersion":4,"cwd":"/Users/example/projects"},
"rows":{"title":{"ver":1,"seq":66,"val":"桌面3D形象消息栏插件"},
"turnOutline":{"ver":2,"seq":66,"val":{"turns":[{"turn":1,"seq":4,"prompt":"做一个3D形象","response":""}],"draft":"正在写"}},
"sessionStats":{"ver":1,"seq":66,"val":{"turns":1,"steps":15,"openStep":{"turn":1,"step":15,"startTime":1790938685142}}},
"turnBoundary":{"ver":2,"seq":66,"val":{"lastTurn":1,"lastStepBoundary":{"kind":"start","seq":126}}}}}}
"""
if let snap = SessionStore.parse(data: Data(sampleJSON.utf8), id: "sX") {
    check(snap.title == "桌面3D形象消息栏插件", "解出标题")
    check(snap.cwd == "/Users/example/projects", "解出工作目录")
    check(snap.turns.count == 1 && snap.turns[0].prompt == "做一个3D形象", "解出轮次与提示词")
    check(snap.working, "openStep 非空 → working = true")
    check(snap.steps == 15, "解出步数")
} else {
    check(false, "能解析真实结构的投影 JSON")
}
check(SessionStore.parse(data: Data("不是 JSON".utf8), id: "bad") == nil, "坏 JSON → 返回 nil（不崩）")
check(SessionStore.parse(data: Data("{}".utf8), id: "empty") == nil, "缺字段 → 返回 nil（不崩）")

// MARK: 4. 摘要文本

section("摘要文本")
check(Snippet.oneLine("## 标题\n\n**加粗** 结果 `代码`") == "标题 加粗 结果 代码", "去掉 Markdown 记号",
      "实际 \(Snippet.oneLine("## 标题\n\n**加粗** 结果 `代码`"))")
check(Snippet.oneLine("看这里 [文档](https://example.com/a) 就懂了") == "看这里 文档 就懂了", "链接只留文字")
check(Snippet.oneLine("```\ncode block\n```\n真正的结论") == "真正的结论", "代码块整段丢掉")
check(Snippet.oneLine("<system-reminder>内部提示</system-reminder> 真实内容") == "内部提示 真实内容", "尖括号标签变空格")
let long = Snippet.oneLine(String(repeating: "字", count: 200))
check(long.count == 69 && long.hasSuffix("…"), "超长截断到 68 字 + 省略号", "实际 \(long.count)")

// MARK: 结果

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
if failed > 0 { exit(1) }
print("全部通过 ✅")
