import Foundation
import TrafficLightCore

/// 运行中的任务记录
struct TaskRecord {
    let id: String
    var name: String
    let startedAt: Date
    var lastHeartbeat: Date
}

/// 完成事件（绿灯，等待确认）
struct CompletionRecord {
    let id: String
    let name: String
    let result: String    // success | fail
    let completedAt: Date
}

/// 红绿灯状态机。
///
/// 状态推导规则（与 SKILL.md 保持一致）：
/// - 有待确认的完成事件      → green（最后一个任务成功完成，结果待查看）
/// - 有运行中的任务          → orange（工作中）
/// - 否则                    → red（空闲）
///
/// 超时规则：
/// - 任务心跳超过 60s 未刷新 → 标记丢失并移除
/// - 绿灯超过 10s 未确认     → 自动回到红色
final class StateEngine {

    enum DisplayState: String {
        case red
        case orange
        case green
    }

    static let heartbeatTimeout: TimeInterval = 60
    static let greenAutoAckInterval: TimeInterval = 10

    private(set) var tasks: [TaskRecord] = []
    private(set) var pendingCompletion: CompletionRecord?
    private(set) var lastMessage = "空闲，等待新任务"

    /// 任何事件导致的刷新回调（主线程调用，幂等刷新 UI）
    var onDisplayStateChanged: ((DisplayState) -> Void)?

    var displayState: DisplayState {
        if pendingCompletion != nil { return .green }
        if !tasks.isEmpty { return .orange }
        return .red
    }

    var statusLine: String {
        switch displayState {
        case .red: return "空闲"
        case .orange: return "工作中 · \(tasks.count) 个任务"
        case .green:
            let name = pendingCompletion?.name ?? ""
            return "完成待确认 · \(name)"
        }
    }

    // MARK: - 命令处理（主线程调用）

    @discardableResult
    func handle(_ request: TLRequest) -> TLResponse {
        switch request.cmd {
        case "ping":
            return makeResponse(message: "pong")

        case "start":
            return handleStart(request)

        case "heartbeat":
            return handleHeartbeat(request)

        case "done":
            return handleDone(request)

        case "idle":
            let reason = request.reason?.isEmpty == false ? request.reason! : "等待新任务"
            tasks.removeAll()
            pendingCompletion = nil
            return commit(message: "空闲：\(reason)")

        case "ack":
            guard let pending = pendingCompletion else {
                return makeResponse(ok: false, message: "当前没有待确认的完成事件",
                                    error: "nothing-to-ack")
            }
            if let id = request.id, !id.isEmpty, id != pending.id {
                return makeResponse(ok: false,
                                    message: "完成事件 ID 不匹配：等待确认的是 \(pending.id)",
                                    error: "id-mismatch")
            }
            pendingCompletion = nil
            return commit(message: "已确认完成事件「\(pending.name)」，回到空闲")

        case "reset":
            tasks.removeAll()
            pendingCompletion = nil
            return commit(message: "已重置为空闲")

        case "status":
            return makeResponse(message: lastMessage)

        default:
            return makeResponse(ok: false, message: "未知命令：\(request.cmd)",
                                error: "unknown-command")
        }
    }

    private func handleStart(_ request: TLRequest) -> TLResponse {
        guard let id = request.id, !id.isEmpty else {
            return makeResponse(ok: false, message: "缺少 --id 参数", error: "missing-id")
        }
        let name = (request.name?.isEmpty == false) ? request.name! : "未命名任务"
        let now = Date()
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].name = name
            tasks[idx].lastHeartbeat = now
            return commit(message: "任务已刷新：\(name)（共 \(tasks.count) 个任务）")
        }
        tasks.append(TaskRecord(id: id, name: name, startedAt: now, lastHeartbeat: now))
        return commit(message: "任务开始：\(name)（共 \(tasks.count) 个任务）")
    }

    private func handleHeartbeat(_ request: TLRequest) -> TLResponse {
        guard let id = request.id, !id.isEmpty else {
            return makeResponse(ok: false, message: "缺少 --id 参数", error: "missing-id")
        }
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else {
            return makeResponse(ok: false,
                                message: "任务不存在或已结束：\(id)，请先 start",
                                error: "unknown-task")
        }
        tasks[idx].lastHeartbeat = Date()
        return commit(message: "心跳刷新：\(tasks[idx].name)")
    }

    private func handleDone(_ request: TLRequest) -> TLResponse {
        guard let id = request.id, !id.isEmpty else {
            return makeResponse(ok: false, message: "缺少 --id 参数", error: "missing-id")
        }
        let result = request.result ?? "success"
        guard result == "success" || result == "fail" else {
            return makeResponse(ok: false, message: "--result 只能是 success 或 fail",
                                error: "bad-result")
        }

        // 先取出任务名再移除记录；ID 未登记时容错处理（App 可能重启过）
        var known = true
        var name = "任务-\(String(id.suffix(8)))"
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            name = tasks[idx].name
            tasks.remove(at: idx)
        } else if let declared = request.name, !declared.isEmpty {
            name = declared
            known = false
        } else {
            known = false
        }

        let prefix = known ? "" : "（任务 ID 未登记，已按结果处理）"
        if result == "fail" {
            return commit(message: tasks.isEmpty
                ? "任务失败：\(name)\(prefix)"
                : "任务失败：\(name)（仍有 \(tasks.count) 个任务运行中）\(prefix)")
        }
        if tasks.isEmpty {
            pendingCompletion = CompletionRecord(id: id, name: name, result: result,
                                                 completedAt: Date())
            return commit(message: "任务完成，待确认：\(name)\(prefix)")
        }
        return commit(message: "任务完成：\(name)（仍有 \(tasks.count) 个任务运行中）\(prefix)")
    }

    // MARK: - 超时清扫（定时调用）

    /// 心跳超时的任务标记丢失；绿灯超时自动确认。有变化时通知 UI。
    @discardableResult
    func sweep(now: Date = Date()) -> Bool {
        var changed = false
        let stale = tasks.filter { now.timeIntervalSince($0.lastHeartbeat) > Self.heartbeatTimeout }
        if !stale.isEmpty {
            let names = stale.map { $0.name }.joined(separator: "、")
            tasks.removeAll { t in stale.contains(where: { $0.id == t.id }) }
            lastMessage = "心跳超时，任务已丢失：\(names)"
            changed = true
        }
        if let pending = pendingCompletion,
           now.timeIntervalSince(pending.completedAt) > Self.greenAutoAckInterval {
            pendingCompletion = nil
            lastMessage = "完成事件超时未确认，自动回到空闲：\(pending.name)"
            changed = true
        }
        if changed { onDisplayStateChanged?(displayState) }
        return changed
    }

    // MARK: - 辅助

    /// 更新消息并通知 UI 刷新
    private func commit(message: String) -> TLResponse {
        lastMessage = message
        onDisplayStateChanged?(displayState)
        return makeResponse(message: message)
    }

    private func makeResponse(ok: Bool = true, message: String,
                              error: String? = nil) -> TLResponse {
        let now = Date()
        let infos = tasks.map { t in
            TLTaskInfo(id: t.id, name: t.name,
                       started_at: TLTime.iso(t.startedAt),
                       last_heartbeat: TLTime.iso(t.lastHeartbeat),
                       seconds_since_heartbeat: Int(now.timeIntervalSince(t.lastHeartbeat)))
        }
        let completion = pendingCompletion.map {
            TLCompletion(id: $0.id, name: $0.name, result: $0.result,
                         completed_at: TLTime.iso($0.completedAt))
        }
        return TLResponse(ok: ok, state: displayState.rawValue,
                          running_tasks: tasks.count, tasks: infos,
                          last_completion: completion, message: message, error: error)
    }
}
