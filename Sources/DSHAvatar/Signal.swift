// DSH 结果信号：把「你（DSH）产生了新结果」这件事，从会话投影缓存里读出来。
//
// 数据源：~/.dsh/storages/session_projcache/sessions/<sessionID>.json
//   DSH 每发生一个事件就把整个会话状态**投影**写到这里，纯 JSON、
//   不需要任何系统权限、也不需要解压 session.v4.jsonl.zstd。
//   实测字段（2026-10-02，本机 DSH）：
//     record.identity.cwd                        工作目录
//     record.rows.title.val                      会话标题
//     record.rows.turnOutline.val.turns[]        {turn, seq, prompt, response}
//     record.rows.turnOutline.val.draft          正在流式输出的草稿
//     record.rows.sessionStats.val.openStep      **非 nil = 正在干活**
//     record.rows.turnBoundary.val.lastStepBoundary.kind  "start" / "end"
//
// 判定用的是「状态迁移」而不是「看见就报」，因为缓存每一步都会被重写：
//   干活中 → openStep 非 nil
//   出结果 → openStep 由非 nil 变 nil，且该轮 response 由空变非空
//   开新一轮 → turns 数量增加
import AppKit

/// 一轮对话的投影。
struct TurnSnapshot: Equatable {
    var turn: Int
    var seq: Int
    var prompt: String
    var response: String
}

/// 一个会话在某一时刻的投影。
struct SessionSnapshot: Equatable {
    var id: String
    var title: String
    var cwd: String
    var updatedAt: Date
    var turns: [TurnSnapshot]
    var steps: Int
    var working: Bool
    var draftLength: Int

    /// 子代理（teammate）会话的标题是 DSH 内部提示词开头，不该当成「你的结果」。
    var isLikelySubagent: Bool { title.hasPrefix("<") }

    var lastTurn: TurnSnapshot? { turns.last }

    /// 显示名：优先会话标题，标题不可用时退回工作目录名。
    var displayName: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && !t.hasPrefix("<") { return t }
        let dir = (cwd as NSString).lastPathComponent
        return dir.isEmpty ? id : dir
    }

    /// 最近的**已完成**结果（response 非空的那一轮）。
    var lastFinishedTurn: TurnSnapshot? {
        turns.last { !$0.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// 状态机吐出来的事件。
enum SignalEvent: Equatable {
    /// 开始干活（收到提示词 / 开了新一轮）。
    case started(SessionSnapshot)
    /// 出了新结果 —— 形象要动起来的那一下。
    case result(SessionSnapshot, TurnSnapshot)
    /// 干活结束但没拿到结果（被打断 / 出错）。
    case stopped(SessionSnapshot)
}

/// 纯逻辑状态机：喂进快照，吐出事件。没有计时器、没有文件 IO，可以直接测。
struct SignalTracker {
    private struct Seen {
        var turnCount: Int
        var working: Bool
        var lastResponseTurn: Int
        var lastResponseLength: Int
    }

    private var seen: [String: Seen] = [:]
    private(set) var seeded = false

    /// 已经庆祝过的 (会话, 轮次)，防止缓存重写导致同一条结果重复触发。
    private var celebrated: Set<String> = []
    /// 最近一次真的动过的会话。
    private(set) var latestActivity: (sessionID: String, at: Date)?

    /// 第一次看到某会话时只做「种子」，不触发事件：
    /// 否则 App 一启动就会为历史结果放一轮烟花。
    var seedOnlyOnFirstSight = true

    mutating func ingest(_ snapshots: [SessionSnapshot], now: Date = Date()) -> [SignalEvent] {
        var events: [SignalEvent] = []
        // 同一拍里可能有多个会话变化，按更新时间从旧到新处理，保证「最新那个」最后说话。
        for snap in snapshots.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            guard !snap.isLikelySubagent else { continue }

            let finished = snap.lastFinishedTurn
            guard let prev = seen[snap.id] else {
                seen[snap.id] = Seen(turnCount: snap.turns.count,
                                     working: snap.working,
                                     lastResponseTurn: finished?.turn ?? 0,
                                     lastResponseLength: finished?.response.count ?? 0)
                if seedOnlyOnFirstSight {
                    seeded = true
                    if snap.working { latestActivity = (snap.id, now) }
                    continue
                }
                // 不种子时：第一次看到就已经有结果，也当成一次结果。
                if let f = finished {
                    celebrated.insert("\(snap.id)#\(f.turn)")
                    events.append(.result(snap, f))
                }
                continue
            }

            var next = prev
            next.turnCount = snap.turns.count
            next.working = snap.working

            let turnedFinished = prev.working && !snap.working
            let newTurnAppeared = snap.turns.count > prev.turnCount

            // 1) 先看「出结果」：干完活了，并且拿到了一轮非空的回复。
            if let f = finished {
                let key = "\(snap.id)#\(f.turn)"
                let responseGrew = f.response.count != prev.lastResponseLength || f.turn > prev.lastResponseTurn
                if responseGrew && !celebrated.contains(key) {
                    celebrated.insert(key)
                    next.lastResponseTurn = f.turn
                    next.lastResponseLength = f.response.count
                    // 只在「刚干完」或「首次看到这一轮的结果」时报，避免流式中间态乱动。
                    if turnedFinished || !snap.working {
                        latestActivity = (snap.id, now)
                        events.append(.result(snap, f))
                    }
                }
            }

            // 2) 再看「开始干活」。
            if snap.working && !prev.working {
                latestActivity = (snap.id, now)
                events.append(.started(snap))
            } else if newTurnAppeared && snap.working {
                latestActivity = (snap.id, now)
                events.append(.started(snap))
            }

            // 3) 干完了却没结果：停下来，不庆祝。
            if turnedFinished && finished == nil {
                latestActivity = (snap.id, now)
                events.append(.stopped(snap))
            }

            seen[snap.id] = next
        }
        // 超过 200 条就清一清，长跑不掉内存。
        if celebrated.count > 200 { celebrated.removeAll() }
        return events
    }

    /// 会话文件被删（会话被清掉）时清掉记忆。
    mutating func forget(sessionID: String) {
        seen.removeValue(forKey: sessionID)
    }
}

// MARK: - 读盘

enum SessionStore {
    /// 默认目录；DSH_SESSIONS_DIR / DSH_HOME 可覆盖。
    static func defaultRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["DSH_SESSIONS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        let home = env["DSH_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
        return URL(fileURLWithPath: home)
            .appendingPathComponent("storages/session_projcache/sessions")
    }

    /// 解析一个投影 JSON。字段全部按「有就用、没有就默认」处理：
    /// DSH 换版本多一个少一个字段都不该让挂件挂掉。
    static func parse(data: Data, id: String, fallbackDate: Date = Date()) -> SessionSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any] else { return nil }

        func row(_ key: String) -> [String: Any]? {
            guard let rows = record["rows"] as? [String: Any],
                  let r = rows[key] as? [String: Any] else { return nil }
            return r["val"] as? [String: Any]
        }
        func rowValue(_ key: String) -> Any? {
            (record["rows"] as? [String: Any])?[key].flatMap { ($0 as? [String: Any])?["val"] }
        }

        let identity = record["identity"] as? [String: Any] ?? [:]
        let cwd = identity["cwd"] as? String ?? ""
        let title = rowValue("title") as? String ?? ""

        var turns: [TurnSnapshot] = []
        if let outline = row("turnOutline"), let rawTurns = outline["turns"] as? [[String: Any]] {
            for t in rawTurns {
                turns.append(TurnSnapshot(turn: t["turn"] as? Int ?? 0,
                                          seq: t["seq"] as? Int ?? 0,
                                          prompt: t["prompt"] as? String ?? "",
                                          response: t["response"] as? String ?? ""))
            }
        }

        let stats = row("sessionStats") ?? [:]
        let boundary = row("turnBoundary") ?? [:]
        let lastStepKind = (boundary["lastStepBoundary"] as? [String: Any])?["kind"] as? String ?? ""
        let openStep = stats["openStep"] as? [String: Any]
        let working = openStep != nil || lastStepKind == "start"

        var updated = fallbackDate
        // 会话自己的时间戳：有 lastPromptAt / startTime 之类就用，否则退回文件 mtime。
        let timeContext = row("timeContext") ?? [:]
        let stamp = (timeContext["lastMessageTime"] as? Double)
            ?? (stats["lastTurnEndTime"] as? Double)
            ?? (stats["lastStepEndTime"] as? Double)
            ?? (openStep?["startTime"] as? Double)
        if let stamp, stamp > 0 {
            updated = Date(timeIntervalSince1970: stamp / 1000.0)
        }

        return SessionSnapshot(id: id,
                               title: title,
                               cwd: cwd,
                               updatedAt: updated,
                               turns: turns,
                               steps: stats["steps"] as? Int ?? 0,
                               working: working,
                               draftLength: (row("turnOutline")?["draft"] as? String)?.count ?? 0)
    }
}

/// 定时扫目录。只有 (mtime, size) 变了的文件才会被重新解析——
/// 挂件要一直挂着，不能每秒把几十个会话全读一遍。
final class SessionWatcher {
    struct Scan {
        var changed: [SessionSnapshot] = []
        /// 最近动过的那个会话（用于状态栏那一行字）。
        var newest: SessionSnapshot?
        /// 被删掉的会话 id。
        var removed: [String] = []
        var error: String?
    }

    private struct CacheEntry: Equatable { var mtime: Date; var size: Int }

    private let root: URL
    private let queue = DispatchQueue(label: "com.example.dshavatar.watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cache: [String: CacheEntry] = [:]
    private var known: [String: SessionSnapshot] = [:]

    var interval: TimeInterval = 0.8
    /// 只认最近这么久之内动过的会话（防止把几天前的会话翻出来放烟花）。
    var recentSeconds: TimeInterval = 1800
    var onChange: ((Scan) -> Void)?

    init(root: URL = SessionStore.defaultRoot()) {
        self.root = root
    }

    var directory: URL { root }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.scanAndEmit() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 同步扫一次，返回结果（也用于诊断）。
    func scan() -> Scan {
        var result = Scan()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            result.error = "读不到会话目录：\(root.path)"
            return result
        }
        let now = Date()
        var alive = Set<String>()
        for name in names where name.hasSuffix(".json") {
            let path = root.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: path.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.intValue else { continue }
            let id = String(name.dropLast(5))
            alive.insert(id)
            let entry = CacheEntry(mtime: mtime, size: size)
            let isNew = cache[path.path] == nil || cache[path.path]! != entry
            cache[path.path] = entry
            guard isNew else { continue }
            guard now.timeIntervalSince(mtime) <= recentSeconds else { continue }
            guard size > 2, size < 8 * 1024 * 1024 else { continue }
            guard let data = try? Data(contentsOf: path) else { continue }
            guard let snap = SessionStore.parse(data: data, id: id, fallbackDate: mtime) else { continue }
            known[id] = snap
            result.changed.append(snap)
        }
        for id in known.keys where !alive.contains(id) {
            known.removeValue(forKey: id)
            result.removed.append(id)
        }
        // newest：changed 里最新的那个，否则用记忆里最新的。
        result.newest = (result.changed.max { $0.updatedAt < $1.updatedAt })
            ?? known.values.max { $0.updatedAt < $1.updatedAt }
        return result
    }

    private func scanAndEmit() {
        let scan = scan()
        guard scan.newest != nil || !scan.changed.isEmpty || !scan.removed.isEmpty || scan.error != nil else { return }
        let s = scan
        DispatchQueue.main.async { [weak self] in self?.onChange?(s) }
    }
}

// MARK: - 文本处理

enum Snippet {
    /// 把回复压成一行能放进气泡的摘要：去 Markdown 记号、去代码块、压空白、截断。
    static func oneLine(_ text: String, limit: Int = 68) -> String {
        var s = text
        // 去掉围栏代码块整体
        while let start = s.range(of: "```") {
            if let end = s.range(of: "```", range: start.upperBound..<s.endIndex) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                s.removeSubrange(start.lowerBound..<s.endIndex)
            }
        }
        // 行内记号
        for token in ["**", "__", "`", "~~", "*"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        // 链接 [文字](url) → 文字
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // 标题记号
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        // 列表记号
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        // 尖括号标签（含 system-reminder 之类）
        s = s.replacingOccurrences(of: #"<[^>]{1,80}>"#, with: " ", options: .regularExpression)
        // 压空白
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit {
            s = String(s.prefix(limit)) + "…"
        }
        return s
    }
}
