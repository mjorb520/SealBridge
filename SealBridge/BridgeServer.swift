import Foundation
import Network

/// Seal 安装桥：Safari 网页 ↔ 10.7.0.1 设备隧道的翻译官
///
/// Safari 只能发 HTTP，做不了原生 TCP（lockdown/AFC/installation_proxy）。
/// 这个桥跑个 HTTP 服务收 Safari 的请求，转成 Minimuxer 调用发给设备。

@MainActor
final class BridgeServer: NSObject {
    static let shared = BridgeServer()
    static let port: UInt16 = 8765

    private var listener: NWListener?
    private var isRunning = false

    // 配对状态
    private var pairingHost: PhonePairingHost?
    private var currentPairCode: String?
    private var pairingDone = false

    // 上传的 IPA 暂存路径
    private var uploadedIpaURL: URL?

    // 安装进度（网页轮询用）
    private var installProgress: Double = 0
    private var installStatus: String = "idle"  // idle / installing / done / error
    private var installError: String?

    func start() {
        guard !isRunning else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        } catch {
            print("[Bridge] 监听失败: \(error)")
            return
        }
        listener?.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in
                self?.handle(conn)
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))
        isRunning = true
        print("[Bridge] HTTP 服务已启动，端口 \(Self.port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - App UI 调用

    struct BridgeStatus {
        let paired: Bool
        let tunnel: Bool
        let pairCode: String?
    }

    func getStatus() -> BridgeStatus {
        return BridgeStatus(paired: pairingDone, tunnel: checkTunnel(), pairCode: currentPairCode)
    }

    /// App 内触发配对，配对码通过回调返回
    func triggerPairing(onCode: @escaping (String?) -> Void) {
        if let code = currentPairCode {
            onCode(code)
            return
        }
        let host = PhonePairingHost()
        self.pairingHost = host
        // 轮询配对码
        host.start { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePairEvent(event)
                if case .showingCode(let code) = event {
                    onCode(code)
                } else if case .completed = event {
                    onCode(nil)
                } else if case .failed = event {
                    onCode(nil)
                }
            }
        }
        // 5 秒后如果还没码，返回 nil 让 UI 继续轮询
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.currentPairCode == nil && !(self?.pairingDone ?? false) {
                onCode(nil)
            }
        }
    }

    // MARK: - HTTP 处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: conn)
    }

    private nonisolated func receiveRequest(on conn: NWConnection) {
        // 先读 header，解析 Content-Length，再循环读完整个 body（支持大 IPA 分块上传）
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
                guard let self = self else { conn.cancel(); return }
                if let data = data, !data.isEmpty {
                    buffer.append(data)
                }
                // 检查是否已读完 header + body
                if let (headerLen, contentLen) = Self.parseHeader(in: buffer) {
                    let totalNeeded = headerLen + contentLen
                    if buffer.count >= totalNeeded {
                        let requestData = buffer
                        let request = String(data: requestData.prefix(headerLen), encoding: .utf8) ?? ""
                        Task { @MainActor [weak self] in
                            self?.route(request: request, rawData: requestData, conn: conn)
                        }
                        return
                    }
                } else if isComplete {
                    // 没有 Content-Length，按已有数据处理
                    let requestData = buffer
                    let request = String(data: requestData, encoding: .utf8) ?? ""
                    Task { @MainActor [weak self] in
                        self?.route(request: request, rawData: requestData, conn: conn)
                    }
                    return
                }
                if isComplete && buffer.isEmpty {
                    conn.cancel()
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    /// 从 buffer 解析 header 长度和 Content-Length。返回 nil 表示 header 还没收全。
    private nonisolated static func parseHeader(in buffer: Data) -> (headerLen: Int, contentLen: Int)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: sep) else { return nil }
        let headerLen = range.upperBound
        let headerStr = String(data: buffer.prefix(headerLen), encoding: .utf8) ?? ""
        var contentLen = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLen = Int(val) ?? 0
            }
        }
        return (headerLen, contentLen)
    }

    private func route(request: String, rawData: Data, conn: NWConnection) {
        let headerEnd = request.range(of: "\r\n\r\n")
        let headerPart = headerEnd.map { String(request[..<($0.lowerBound)]) } ?? request
        let lines = headerPart.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(conn: conn, status: 400, body: "Bad Request")
            return
        }
        let method = parts[0]
        let path = parts[1].components(separatedBy: "?").first ?? "/"

        // CORS 预检
        if method == "OPTIONS" {
            sendPreflight(conn: conn)
            return
        }

        switch (method, path) {
        case ("GET", "/status"):
            let tunnel = checkTunnel()
            // paired = 隧道通且能调 lockdown 拿 UDID（真实可用性，不是手动标记）
            var paired = false
            var udid = ""
            if tunnel {
                if let fetchedUDID = Minimuxer.fetchUDID(), !fetchedUDID.isEmpty {
                    paired = true
                    udid = fetchedUDID
                }
            }
            let pairCode = currentPairCode ?? ""
            let body = "{\"paired\": \(paired), \"tunnel\": \(tunnel), \"version\": \"1.0\", \"udid\": \"\(udid)\", \"pairCode\": \"\(pairCode)\"}"
            sendResponse(conn: conn, status: 200, body: body, contentType: "application/json")

        case ("POST", "/pair"):
            handlePair(conn: conn)

        case ("POST", "/upload"):
            handleUpload(request: request, rawData: rawData, conn: conn)

        case ("POST", "/install"):
            // 从 query 或 body 取 bundleId
            let bundleId = extractBundleId(from: request) ?? "com.example.app"
            Task { await handleInstall(bundleId: bundleId, conn: conn) }

        case ("GET", "/progress"):
            let errStr = installError ?? ""
            let body = "{\"status\": \"\(installStatus)\", \"progress\": \(installProgress), \"error\": \"\(errStr)\"}"
            sendResponse(conn: conn, status: 200, body: body, contentType: "application/json")

        default:
            sendResponse(conn: conn, status: 404, body: "Not Found")
        }
    }

    private func extractBundleId(from request: String) -> String? {
        // 从 URL query 取 bundleId
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let urlString = parts[1]
        guard let qStart = urlString.firstIndex(of: "?") else { return nil }
        let query = String(urlString[urlString.index(after: qStart)...])
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == "bundleId" {
                return kv[1].removingPercentEncoding
            }
        }
        return nil
    }

    // MARK: - 业务逻辑

    /// 检查隧道是否通：直连 10.7.0.1:62078（lockdown），通了就是隧道在了
    private func checkTunnel() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(62078).bigEndian
        addr.sin_addr.s_addr = inet_addr("10.7.0.1")
        // 2 秒超时
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// 配对：iOS 27 走 Bonjour Remote Pairing
    private func handlePair(conn: NWConnection) {
        // 如果已在配对，返回当前码
        if let code = currentPairCode {
            sendResponse(conn: conn, status: 200,
                         body: "{\"code\": \"\(code)\", \"hint\": \"请在系统弹窗中确认配对\"}",
                         contentType: "application/json")
            return
        }

        let host = PhonePairingHost()
        self.pairingHost = host
        host.start { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePairEvent(event)
            }
        }
        // 立即返回等待中，网页轮询 /status 或再次 POST /pair 取码
        sendResponse(conn: conn, status: 200,
                     body: "{\"waiting\": true, \"hint\": \"正在启动配对，请稍后查询配对码\"}",
                     contentType: "application/json")
    }

    private func handlePairEvent(_ event: PhonePairingHost.Event) {
        switch event {
        case .requestingLocalNetwork:
            print("[Bridge] 配对：请求本地网络权限")
        case .waitingForSystemConfirmation:
            print("[Bridge] 配对：等待系统确认")
        case .showingCode(let code):
            currentPairCode = code
            print("[Bridge] 配对码: \(code)")
        case .completed(let url):
            pairingDone = true
            currentPairCode = nil
            pairingHost = nil
            print("[Bridge] 配对完成: \(url.path)")
        case .failed(let reason):
            currentPairCode = nil
            pairingHost = nil
            print("[Bridge] 配对失败: \(reason)")
        }
    }

    /// 上传：解析 multipart body，存 IPA 到临时文件
    private func handleUpload(request: String, rawData: Data, conn: NWConnection) {
        // 找 boundary
        let lines = request.components(separatedBy: "\r\n")
        var boundary: String?
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-type:") && lower.contains("multipart/form-data") {
                if let bRange = line.range(of: "boundary=") {
                    boundary = String(line[bRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        let ipaData: Data?
        if let boundary = boundary {
            ipaData = extractMultipartFile(data: rawData, boundary: boundary)
        } else {
            // 直接是 raw body
            if let headerEnd = rawData.firstRange(of: Data("\r\n\r\n".utf8)) {
                ipaData = rawData.subdata(in: headerEnd.upperBound..<rawData.count)
            } else {
                ipaData = nil
            }
        }

        guard let ipaData = ipaData, !ipaData.isEmpty else {
            sendResponse(conn: conn, status: 400,
                         body: "{\"saved\": false, \"error\": \"未收到 IPA 数据\"}",
                         contentType: "application/json")
            return
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-upload-\(UUID().uuidString).ipa")
        do {
            try ipaData.write(to: tmpURL)
            uploadedIpaURL = tmpURL
            print("[Bridge] IPA 已保存: \(tmpURL.path) (\(ipaData.count) bytes)")
            sendResponse(conn: conn, status: 200,
                         body: "{\"saved\": true, \"size\": \(ipaData.count)}",
                         contentType: "application/json")
        } catch {
            sendResponse(conn: conn, status: 500,
                         body: "{\"saved\": false, \"error\": \"\(error.localizedDescription)\"}",
                         contentType: "application/json")
        }
    }

    private func extractMultipartFile(data: Data, boundary: String) -> Data? {
        let boundaryData = Data("--\(boundary)".utf8)
        let endBoundaryData = Data("--\(boundary)--".utf8)

        var searchRange = data.startIndex..<data.endIndex
        // 跳过第一个 boundary
        guard let firstBound = data.range(of: boundaryData, in: searchRange) else { return nil }
        searchRange = firstBound.upperBound..<data.endIndex

        // 找 part header 结束
        let headerEnd = Data("\r\n\r\n".utf8)
        guard let headerEndRange = data.range(of: headerEnd, in: searchRange) else { return nil }
        let fileStart = headerEndRange.upperBound

        // 找结束 boundary
        let fileEnd: Data.Index
        if let endRange = data.range(of: endBoundaryData, in: fileStart..<data.endIndex) {
            fileEnd = endRange.lowerBound
        } else if let nextBound = data.range(of: boundaryData, in: fileStart..<data.endIndex) {
            fileEnd = nextBound.lowerBound
        } else {
            return nil
        }

        // 去掉末尾的 \r\n
        var end = fileEnd
        if end >= data.startIndex.advanced(by: 2) {
            let crlf = data[(end.advanced(by: -2))..<end]
            if crlf == Data("\r\n".utf8) {
                end = end.advanced(by: -2)
            }
        }
        guard fileStart < end else { return nil }
        return data.subdata(in: fileStart..<end)
    }

    /// 安装：调 Minimuxer 走隧道装包（进度可通过 /progress 轮询）
    private func handleInstall(bundleId: String, conn: NWConnection) async {
        guard let ipaURL = uploadedIpaURL else {
            sendResponse(conn: conn, status: 400,
                         body: "{\"installed\": false, \"error\": \"请先上传 IPA\"}",
                         contentType: "application/json")
            return
        }

        installStatus = "installing"
        installProgress = 0
        installError = nil

        do {
            let ipaBytes = try Data(contentsOf: ipaURL)
            print("[Bridge] 开始安装 \(bundleId) (\(ipaBytes.count) bytes)")
            installProgress = 0.1

            // 先 AFC 传包，再调 installation_proxy 安装
            try Install.yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
            installProgress = 0.6
            try Install.installIpa(bundleId: bundleId)
            installProgress = 1.0

            print("[Bridge] 安装完成: \(bundleId)")
            // 清理临时文件
            try? FileManager.default.removeItem(at: ipaURL)
            uploadedIpaURL = nil

            installStatus = "done"
            sendResponse(conn: conn, status: 200,
                         body: "{\"installed\": true, \"bundleId\": \"\(bundleId)\"}",
                         contentType: "application/json")
        } catch {
            print("[Bridge] 安装失败: \(error)")
            installStatus = "error"
            installError = error.localizedDescription
            sendResponse(conn: conn, status: 500,
                         body: "{\"installed\": false, \"error\": \"\(error.localizedDescription)\"}",
                         contentType: "application/json")
        }
    }

    // MARK: - HTTP 响应

    private func sendPreflight(conn: NWConnection) {
        let header = "HTTP/1.1 204 No Content\r\n" +
                     "Access-Control-Allow-Origin: *\r\n" +
                     "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
                     "Access-Control-Allow-Headers: Content-Type\r\n" +
                     "Content-Length: 0\r\n" +
                     "Connection: close\r\n\r\n"
        let data = header.data(using: .utf8) ?? Data()
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func sendResponse(conn: NWConnection, status: Int, body: String, contentType: String = "text/plain") {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "OK"
        }
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status) \(statusText)\r\n" +
                     "Content-Type: \(contentType); charset=utf-8\r\n" +
                     "Content-Length: \(bodyData.count)\r\n" +
                     "Access-Control-Allow-Origin: *\r\n" +
                     "Connection: close\r\n\r\n"
        var response = header.data(using: .utf8) ?? Data()
        response.append(bodyData)
        conn.send(content: response, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - Data helper

private extension Data {
    func firstRange(of subdata: Data) -> Range<Index>? {
        return self.range(of: subdata)
    }
}
