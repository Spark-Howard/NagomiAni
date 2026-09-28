import Foundation
import Network

/// 极简本地回环 HTTP 文件服务器（仅 127.0.0.1）。
///
/// 用途：把本地生成的媒体文件以 http:// URL 提供给播放内核——
/// mpv/ffmpeg 拉流时会发 Range 请求探测 MP4 尾部的 moov atom，因此
/// 必须实现 206 Partial Content，否则在线 seek 不可用。
///
/// 设计取舍：
/// - 每个连接独立处理（NWConnection 异步发送，不阻塞队列）
/// - 回应 `Connection: close`，客户端按请求重连——本地回环代价可忽略
/// - 只支持 GET/HEAD，路径映射限制在根目录内（拒绝 `..` 穿越）
public final class LoopbackHTTPServer: @unchecked Sendable {
    public enum ServerError: LocalizedError {
        case listenerFailed
        public var errorDescription: String? { "无法启动本地回环服务器" }
    }

    private let rootURL: URL
    private let queue = DispatchQueue(label: "nagomiani.loopback.http")
    private var listener: NWListener?
    private var assignedPort: UInt16 = 0
    private var startContinuations: [CheckedContinuation<UInt16, Error>] = []

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    deinit {
        listener?.cancel()
    }

    /// 启动服务器并等待端口分配完成（返回实际监听端口）。重复调用返回同一端口。
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: ServerError.listenerFailed)
                    return
                }
                if self.assignedPort > 0 {
                    cont.resume(returning: self.assignedPort)
                    return
                }
                self.startContinuations.append(cont)
                guard self.listener == nil else { return } // 已在启动中，等 ready 统一 resume

                let listener: NWListener
                do {
                    listener = try NWListener(using: .tcp, on: .any) // 0 = 系统分配空闲端口
                } catch {
                    self.finishStart(.failure(error))
                    return
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection: connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.assignedPort = listener.port?.rawValue ?? 0
                        self.finishStart(.success(self.assignedPort))
                    case .failed(let error):
                        // 清掉失败的 listener：否则下次 start 会因 listener 非 nil
                        // 直接返回，等待中的 continuation 永远无人 resume（永久挂起）
                        self.listener?.cancel()
                        self.listener = nil
                        self.finishStart(.failure(error))
                    default:
                        break
                    }
                }
                self.listener = listener
                listener.start(queue: self.queue)
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.assignedPort = 0
        }
    }

    /// 统一 resume 所有等待 start() 的调用（queue 上调用）
    private func finishStart(_ result: Result<UInt16, Error>) {
        let conts = startContinuations
        startContinuations = []
        for cont in conts {
            switch result {
            case .success(let port): cont.resume(returning: port)
            case .failure(let error): cont.resume(throwing: error)
            }
        }
    }

    // MARK: - 请求处理

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection: connection, buffer: Data())
    }

    /// 累积接收直到出现空行（header 结束）
    private func receiveHeader(connection: NWConnection, buffer: Data) {
        guard buffer.count < 64 * 1024 else {
            respondSimple(connection, status: 431, body: "headers too large")
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buf = buffer
            if let data, !data.isEmpty {
                buf.append(data)
                if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
                    self.dispatch(connection: connection, headerData: headerData)
                    return
                }
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receiveHeader(connection: connection, buffer: buf)
        }
    }

    private func dispatch(connection: NWConnection, headerData: Data) {
        let text = String(decoding: headerData, as: UTF8.self)
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            respondSimple(connection, status: 400, body: "bad request")
            return
        }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            respondSimple(connection, status: 400, body: "bad request")
            return
        }
        let method = parts[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            respondSimple(connection, status: 405, body: "method not allowed")
            return
        }

        // Range 头（大小写不敏感）
        var rangeHeader: String?
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == "range" {
                rangeHeader = kv[1]
            }
        }

        guard let file = resolveFile(path: parts[1]),
              let fileData = try? Data(contentsOf: file) else {
            respondSimple(connection, status: 404, body: "not found")
            return
        }

        let fileSize = Int64(fileData.count)
        let range = Self.parseRange(rangeHeader, fileSize: fileSize)

        var headers = "HTTP/1.1 \(range != nil ? "206" : "200") OK\r\n"
        headers += "Content-Type: \(Self.contentType(forExtension: file.pathExtension))\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "Connection: close\r\n"
        var bodyStart: Int64 = 0
        var bodyLength = fileSize
        if let range {
            bodyStart = range.start
            bodyLength = range.end - range.start + 1
            headers += "Content-Range: bytes \(range.start)-\(range.end)/\(fileSize)\r\n"
        }
        headers += "Content-Length: \(bodyLength)\r\n\r\n"
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            guard method == "GET", bodyLength > 0 else {
                connection.cancel()
                return
            }
            self.sendBytes(connection: connection, data: fileData,
                           offset: Int(bodyStart), remaining: bodyLength)
        })
    }

    /// 把请求路径映射到根目录内的文件（拒绝穿越）
    private func resolveFile(path: String) -> URL? {
        let decoded = path.removingPercentEncoding ?? path
        var components = decoded.split(separator: "/")
        guard !components.isEmpty else { return nil }
        guard !components.contains("..") else { return nil }
        var url = rootURL
        for component in components {
            url.appendPathComponent(String(component))
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 解析 Range 头；无法解析/越界返回 nil（退化为 200 全量）
    static func parseRange(_ header: String?, fileSize: Int64) -> (start: Int64, end: Int64)? {
        guard let header, fileSize > 0 else { return nil }
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        // "start-"：从 start 到末尾；"-suffix"：末尾 suffix 字节；"start-end"：闭区间
        if let start = Int64(parts[0]) {
            let end = parts[1].isEmpty ? fileSize - 1 : min(Int64(parts[1]) ?? 0, fileSize - 1)
            guard start <= end, start < fileSize else { return nil }
            return (start, end)
        }
        if parts[0].isEmpty, let suffix = Int64(parts[1]), suffix > 0 {
            let length = min(suffix, fileSize)
            return (fileSize - length, fileSize - 1)
        }
        return nil
    }

    /// 分块发送内存数据（256KB/块），出错即断开
    private func sendBytes(connection: NWConnection, data: Data, offset: Int, remaining: Int64) {
        guard remaining > 0, offset < data.count else {
            connection.cancel()
            return
        }
        let chunkSize = Int(min(Int64(256 * 1024), Int64(remaining), Int64(data.count - offset)))
        let chunk = data.subdata(in: offset..<(offset + chunkSize))
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.sendBytes(connection: connection, data: data,
                           offset: offset + chunkSize, remaining: remaining - Int64(chunkSize))
        })
    }

    private func respondSimple(_ connection: NWConnection, status: Int, body: String) {
        let bodyData = Data(body.utf8)
        var response = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
        response += "Content-Type: text/plain; charset=utf-8\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var out = Data(response.utf8)
        out.append(bodyData)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 431: return "Request Header Fields Too Large"
        default: return "Error"
        }
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "m4s": return "video/iso.segment"
        case "ts": return "video/mp2t"
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }
}
