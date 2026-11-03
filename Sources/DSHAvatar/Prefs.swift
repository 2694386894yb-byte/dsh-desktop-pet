// 偏好与数据目录。
//
// 默认落在 ~/Library/Application Support/DeepSeek 桌宠/，所有写盘操作都「尽力而为」：
// 写不进去（沙箱、只读盘）不能让形象挂掉——状态留在内存里照常动。
import AppKit

struct Preferences: Codable {
    /// 形象大小档位。
    var size: AvatarSize = .large
    /// 窗口左边缘（屏幕坐标 pt）。nil = 用默认落点（刘海右侧）。
    var anchorX: CGFloat?
    /// 点击穿透：true 时完全不挡菜单栏，也点不到形象。
    var clickThrough: Bool = false
    /// 出结果时是否弹气泡。
    var showBubble: Bool = true
    /// 是否在新结果气泡中显示回复摘要。
    var bubbleShowsSnippet: Bool = false
    /// 气泡停留秒数。
    var bubbleSeconds: Double = 7
    /// 开机自动启动（写 ~/Library/LaunchAgents 里的 plist）。
    var launchAtLogin: Bool = false
    /// 多久没有新动静就从「干活中」回到「空闲」（秒）。
    var workingTimeout: Double = 45
    /// 多久没动静进入打盹状态（秒）。
    var sleepAfter: Double = 900
    /// 只认这些工作目录下的会话；空 = 全都认。
    var workspaceFilter: [String] = []

    static func defaults() -> Preferences { Preferences() }
}

final class Prefs {
    static let shared = Prefs()

    private(set) var values: Preferences = .defaults()
    let home: URL
    let fileURL: URL
    private(set) var lastWriteError: String?

    private init() {
        let env = ProcessInfo.processInfo.environment["DSH_AVATAR_HOME"]
        if let env, !env.isEmpty {
            home = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            home = base.appendingPathComponent("DeepSeek 桌宠")
        }
        fileURL = home.appendingPathComponent("prefs.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
            values = decoded
        }
    }

    /// 落盘。失败只记录原因，不抛也不崩。
    func save() {
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(values)
            try data.write(to: fileURL, options: .atomic)
            lastWriteError = nil
        } catch {
            lastWriteError = "\(error.localizedDescription)（路径：\(fileURL.path)）"
        }
    }

    func mutate(_ body: (inout Preferences) -> Void) {
        body(&values)
        save()
    }
}
