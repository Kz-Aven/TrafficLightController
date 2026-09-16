import Foundation

/// App 与 CLI 共享的协议常量、请求/响应模型与 Socket 客户端。
public enum TLProtocol {
    public static let bundleIdentifier = "com.kzaven.trafficlight"
    public static let socketName = "trafficlight.sock"

    /// Unix domain socket 路径（同一用户下所有进程一致）
    public static var socketPath: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(socketName)
    }
}

// MARK: - 请求 / 响应模型

public struct TLRequest: Codable {
    public var cmd: String
    public var id: String?
    public var name: String?
    public var result: String?
    public var reason: String?

    public init(cmd: String, id: String? = nil, name: String? = nil,
                result: String? = nil, reason: String? = nil) {
        self.cmd = cmd
        self.id = id
        self.name = name
        self.result = result
        self.reason = reason
    }
}

public struct TLTaskInfo: Codable {
    public var id: String
    public var name: String
    public var started_at: String
    public var last_heartbeat: String
    public var seconds_since_heartbeat: Int

    public init(id: String, name: String, started_at: String,
                last_heartbeat: String, seconds_since_heartbeat: Int) {
        self.id = id
        self.name = name
        self.started_at = started_at
        self.last_heartbeat = last_heartbeat
        self.seconds_since_heartbeat = seconds_since_heartbeat
    }
}

public struct TLCompletion: Codable {
    public var id: String
    public var name: String
    public var result: String
    public var completed_at: String

    public init(id: String, name: String, result: String, completed_at: String) {
        self.id = id
        self.name = name
        self.result = result
        self.completed_at = completed_at
    }
}

public struct TLResponse: Codable {
    public var ok: Bool
    public var state: String            // red | orange | green
    public var running_tasks: Int
    public var tasks: [TLTaskInfo]
    public var last_completion: TLCompletion?
    public var message: String
    public var error: String?

    public init(ok: Bool, state: String, running_tasks: Int, tasks: [TLTaskInfo],
                last_completion: TLCompletion?, message: String, error: String? = nil) {
        self.ok = ok
        self.state = state
        self.running_tasks = running_tasks
        self.tasks = tasks
        self.last_completion = last_completion
        self.message = message
        self.error = error
    }

    public static func failure(_ message: String, error: String) -> TLResponse {
        TLResponse(ok: false, state: "red", running_tasks: 0, tasks: [],
                   last_completion: nil, message: message, error: error)
    }
}

// MARK: - JSON 编解码

public enum TLJSON {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    public static func decodeRequest(_ string: String) -> TLRequest? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TLRequest.self, from: data)
    }

    public static func decodeResponse(_ string: String) -> TLResponse? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TLResponse.self, from: data)
    }
}

public enum TLTime {
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func iso(_ date: Date) -> String {
        fmt.string(from: date)
    }
}

// MARK: - Socket 底层（App 单实例检测与 CLI 客户端共用）

public enum TLUnixSocket {
    /// 构造 AF_UNIX 地址
    public static func makeAddr(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                let n = min(strlen(cstr) + 1, raw.count)
                _ = memcpy(raw.baseAddress, cstr, n)
            }
        }
        return addr
    }

    /// 非阻塞 connect（带超时），成功返回阻塞模式的 fd
    static func connect(timeoutMS: Int32) -> Int32? {
        let path = TLProtocol.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        let originalFlags = fcntl(fd, F_GETFL, 0)
        fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)

        var addr = makeAddr(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 && errno != EINPROGRESS && errno != EAGAIN {
            close(fd)
            return nil
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        if poll(&pfd, 1, timeoutMS) <= 0 {
            close(fd)
            return nil
        }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        if soError != 0 {
            close(fd)
            return nil
        }
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
        fcntl(fd, F_SETFL, originalFlags)   // 恢复阻塞模式
        return fd
    }
}

/// CLI 侧客户端：发送一条命令并等待 JSON 响应
public enum TLClient {
    /// socket 上是否已有 App 实例在监听
    public static func isServerRunning() -> Bool {
        guard let fd = TLUnixSocket.connect(timeoutMS: 500) else { return false }
        close(fd)
        return true
    }

    public enum ClientError: Error, CustomStringConvertible {
        case serverNotRunning
        case permissionDenied
        case timeout
        case badResponse

        public var description: String {
            switch self {
            case .serverNotRunning: return "TrafficLight App 未运行"
            case .permissionDenied: return "当前进程无权连接 TrafficLight 的本地 socket"
            case .timeout: return "等待 TrafficLight App 响应超时"
            case .badResponse: return "TrafficLight App 返回了无法解析的数据"
            }
        }
    }

    /// 发送请求并同步等待响应（供 CLI 使用）
    public static func send(_ request: TLRequest,
                            connectTimeoutMS: Int32 = 1000,
                            responseTimeoutMS: Int32 = 5000) throws -> TLResponse {
        guard let fd = TLUnixSocket.connect(timeoutMS: connectTimeoutMS) else {
            if errno == EPERM || errno == EACCES {
                throw ClientError.permissionDenied
            }
            throw ClientError.serverNotRunning
        }
        defer { close(fd) }

        var payload = (TLJSON.encode(request) + "\n").data(using: .utf8)!
        let sent = payload.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Void.self) else { return -1 }
            return Darwin.send(fd, base, payload.count, 0)
        }
        guard sent == payload.count else { throw ClientError.timeout }

        var buffer = Data()
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            if buffer.isEmpty {
                if poll(&pfd, 1, responseTimeoutMS) <= 0 { throw ClientError.timeout }
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                if errno == EAGAIN && !buffer.isEmpty { continue }
                throw ClientError.timeout
            }
            let data = chunk[0..<n]
            if let idx = data.firstIndex(of: 0x0A) {
                buffer.append(contentsOf: data[0..<idx])
                break
            }
            buffer.append(contentsOf: data)
            if buffer.count > 65536 { throw ClientError.badResponse }
        }
        guard let text = String(data: buffer, encoding: .utf8),
              let response = TLJSON.decodeResponse(text) else {
            throw ClientError.badResponse
        }
        return response
    }
}
