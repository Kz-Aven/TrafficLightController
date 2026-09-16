import Foundation
import TrafficLightCore

// trafficlight — 控制 TrafficLight 桌面红绿灯的命令行工具。
//
// 用法:
//   trafficlight start     --id <任务ID> [--name "<任务名>"]
//   trafficlight heartbeat --id <任务ID>
//   trafficlight done      --id <任务ID> --result success|fail [--name "<任务名>"]
//   trafficlight idle      [--reason "<原因>"]
//   trafficlight ack       [--id <任务ID>]
//   trafficlight status
//   trafficlight reset
//
// 所有命令输出单行 JSON（stdout），ok=true 时退出码为 0，否则为 1。
// App 未运行时会自动尝试启动 App（--no-launch 关闭该行为）。

let cliVersion = "1.0.0"

struct ParsedCommand {
    var request: TLRequest
    var autoLaunch = true
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
}

func printHelp() {
    print("""
    trafficlight \(cliVersion) — 控制 TrafficLight 桌面红绿灯

    用法:
      trafficlight start     --id <任务ID> [--name "<任务名>"]   开始任务（红灯→橙灯）
      trafficlight heartbeat --id <任务ID>                      刷新任务心跳
      trafficlight done      --id <任务ID> --result success|fail 标记任务完成
      trafficlight idle      [--reason "<原因>"]                 进入空闲（红灯）
      trafficlight ack       [--id <任务ID>]                     确认完成事件（绿灯→红灯）
      trafficlight status                                        查询当前状态
      trafficlight reset                                        强制重置为空闲

    选项:
      --no-launch   App 未运行时不尝试自动启动
      -h, --help    显示帮助
      -v, --version 显示版本

    输出: 单行 JSON，例如
      {"ok":true,"state":"orange","running_tasks":1,...}
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func parseArguments(_ args: [String]) throws -> ParsedCommand {
    var positional: [String] = []
    var id: String?, name: String?, result: String?, reason: String?
    var autoLaunch = true

    var i = 0
    func nextValue(_ flag: String) throws -> String {
        i += 1
        guard i < args.count, !args[i].hasPrefix("--") else {
            throw CLIError(description: "参数 \(flag) 缺少取值")
        }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--id": id = try nextValue(a)
        case "--name": name = try nextValue(a)
        case "--result": result = try nextValue(a)
        case "--reason": reason = try nextValue(a)
        case "--no-launch": autoLaunch = false
        default:
            if a.hasPrefix("--") {
                throw CLIError(description: "未知参数：\(a)")
            }
            positional.append(a)
        }
        i += 1
    }

    guard positional.count == 1 else {
        throw CLIError(description: "需要恰好一个子命令（start/heartbeat/done/idle/ack/status/reset）")
    }
    let cmd = positional[0]
    let request: TLRequest
    switch cmd {
    case "start", "heartbeat":
        guard let id, !id.isEmpty else { throw CLIError(description: "\(cmd) 需要 --id 参数") }
        request = TLRequest(cmd: cmd, id: id, name: name)
    case "done":
        guard let id, !id.isEmpty else { throw CLIError(description: "done 需要 --id 参数") }
        guard result == "success" || result == "fail" else {
            throw CLIError(description: "done 需要 --result success 或 --result fail")
        }
        request = TLRequest(cmd: cmd, id: id, name: name, result: result)
    case "idle":
        request = TLRequest(cmd: cmd, reason: reason)
    case "ack":
        request = TLRequest(cmd: cmd, id: id)
    case "status", "reset":
        request = TLRequest(cmd: cmd)
    default:
        throw CLIError(description: "未知子命令：\(cmd)")
    }
    return ParsedCommand(request: request, autoLaunch: autoLaunch)
}

/// 尝试通过 LaunchServices 启动 TrafficLight.app
func launchApp() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", TLProtocol.bundleIdentifier]
    try? process.run()
}

// MARK: - main

let rawArgs = Array(CommandLine.arguments.dropFirst())

if rawArgs.isEmpty || rawArgs.contains("-h") || rawArgs.contains("--help") {
    printHelp()
    exit(0)
}
if rawArgs.contains("-v") || rawArgs.contains("--version") {
    print(cliVersion)
    exit(0)
}

let parsed: ParsedCommand
do {
    parsed = try parseArguments(rawArgs)
} catch {
    printHelp()
    fail("参数错误：\(error)")
}

// App 未运行时自动启动并等待其就绪
var response: TLResponse?
do {
    response = try TLClient.send(parsed.request)
} catch TLClient.ClientError.serverNotRunning {
    if !parsed.autoLaunch {
        response = nil
    } else {
        launchApp()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            usleep(300_000)
            if let r = try? TLClient.send(parsed.request, connectTimeoutMS: 800) {
                response = r
                break
            }
        }
    }
} catch {
    response = nil
    FileHandle.standardError.write(("错误：\(error)\n").data(using: .utf8)!)
}

if let response {
    print(TLJSON.encode(response))
    exit(response.ok ? 0 : 1)
}

// 失败：JSON 走 stdout 供 Agent 解析，人话提示走 stderr
print(TLJSON.encode(TLResponse.failure(
    "TrafficLight App 未运行且自动启动失败",
    error: "app-not-running")))
FileHandle.standardError.write((
    "提示：请先安装并启动 TrafficLight.app（可运行 install.sh），或检查是否被系统拦截。\n"
).data(using: .utf8)!)
exit(1)
