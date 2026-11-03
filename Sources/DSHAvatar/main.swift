// 进程入口。命令行参数见 Arguments（--diag / --render / --demo / --position …）。
import AppKit

let arguments = Arguments(CommandLine.arguments)

// --state-dir 必须在任何 Prefs.shared 访问之前生效（Prefs 是懒加载单例）。
if let dir = arguments.stateDir {
    setenv("DSH_AVATAR_HOME", (dir as NSString).expandingTildeInPath, 1)
}

let application = NSApplication.shared
let delegate = AppDelegate(args: arguments)
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
