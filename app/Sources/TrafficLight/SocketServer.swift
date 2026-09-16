import Foundation
import TrafficLightCore

/// 本地 Unix domain socket 服务：接收 CLI 发来的 JSON 命令（一行一条），
/// 交由主线程的 handler 处理后回写一行 JSON 响应，随后关闭连接。
final class SocketServer {

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "trafficlight.socket")
    /// 命令处理器（会被调度到主线程执行，返回响应）
    private let handler: (TLRequest) -> TLResponse

    init(handler: @escaping (TLRequest) -> TLResponse) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// 是否已有实例在监听（用于单实例检测）
    static func isAlreadyRunning() -> Bool {
        TLClient.isServerRunning()
    }

    func start() throws {
        let path = TLProtocol.socketPath
        try? FileManager.default.removeItem(atPath: path)   // 清理残留 socket 文件

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "TrafficLight", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 socket"])
        }
        var addr = TLUnixSocket.makeAddr(path)
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw NSError(domain: "TrafficLight", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "无法监听 \(path)"])
        }
        // 非阻塞：acceptPending 依靠 EAGAIN 退出循环，否则会阻塞在 accept 上占死串行队列
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        serverFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
            try? FileManager.default.removeItem(atPath: TLProtocol.socketPath)
        }
    }

    private func acceptPending() {
        while true {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFD, $0, &len)
                }
            }
            if client < 0 { break }
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    /// 处理单个连接：读一行请求 → 主线程执行 → 回写响应 → 关闭
    private func serve(_ fd: Int32) {
        defer { close(fd) }

        // BSD 上 accept 出的 socket 会继承监听 socket 的 O_NONBLOCK，
        // 必须显式清除，否则下方 read 会在数据到达前立刻返回 EAGAIN
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK)
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
        // 限制客户端读取时间，避免异常连接占住串行队列
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        while true {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            if n <= 0 { return }                       // EOF 或超时
            if byte == 0x0A { break }
            buffer.append(byte)
            if buffer.count > 65536 { return }
        }

        let request = String(data: buffer, encoding: .utf8).flatMap { TLJSON.decodeRequest($0) }
        let response: TLResponse
        if let request {
            response = DispatchQueue.main.sync { [handler] in handler(request) }
        } else {
            response = TLResponse.failure("无法解析命令", error: "bad-request")
        }

        let payload = (TLJSON.encode(response) + "\n").data(using: .utf8)!
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Void.self) else { return }
            _ = Darwin.send(fd, base, payload.count, 0)
        }
    }
}
