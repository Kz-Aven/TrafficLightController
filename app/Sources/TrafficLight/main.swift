import AppKit

// 单实例保护：若已有 TrafficLight 在运行（socket 可连通），静默退出本次启动
if SocketServer.isAlreadyRunning() {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 无 Dock 图标、不抢焦点，仅状态栏常驻
app.run()
