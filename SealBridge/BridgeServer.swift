import Foundation
import Network
import Minimuxer

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

    // MARK: - HTTP 处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: conn)
    }

    private nonisolated func receiveRequest(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }
            // 尝试读取完整 body（Content-Length）
            let request = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                self?.route(request: request, rawData: data, conn: conn)
            }
        }
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

        switch (method, path) {
        case ("GET", "/status"):
            let paired = pairingDone
            let tunnel = checkTunnel()
            let body = """
            {"paired": \(paired), "tunnel": \(tunnel), "version": "1.0"}
            """
            sendResponse(conn: conn, status: 200, body: body, contentType: "application/json")

        case ("POST", "/pair"):
            handlePair(conn: conn)

        case ("POST", "/upload"):
            handleUpload(request: request, rawData: rawData, conn: conn)

        case ("POST", "/install"):
            // 从 query 或 body 取 bundleId
            let bundleId = extractBundleId(from: request) ?? "com.example.app"
            Task { await handleInstall(bundleId: bundleId, conn: conn) }

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

    /// 检查隧道是否通：走 Minimuxer 的就绪判据
    private func checkTunnel() -> Bool {
        return Minimuxer.ready()
    }

    /// 配对：iOS 27 走 Bonjour Remote Pairing
    private func handlePair(conn: NWConnection) {
        // 如果已在配对，返回当前码
        if let code = currentPairCode {
            sendResponse(conn: conn, status: 200,
                         body: """{"code": "\(code)", "hint": "请在系统弹窗中确认配对"}""",
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
                     body: """{"waiting": true, "hint": "正在启动配对，请稍后查询配对码"}""",
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
                         body: """{"saved": false, "error": "未收到 IPA 数据"}""",
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
                         body: """{"saved": true, "size": \(ipaData.count)}""",
                         contentType: "application/json")
        } catch {
            sendResponse(conn: conn, status: 500,
                         body: """{"saved": false, "error": "\(error.localizedDescription)"}""",
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

    /// 安装：调 Minimuxer 走隧道装包
    private func handleInstall(bundleId: String, conn: NWConnection) async {
        guard let ipaURL = uploadedIpaURL else {
            sendResponse(conn: conn, status: 400,
                         body: """{"installed": false, "error": "请先上传 IPA"}""",
                         contentType: "application/json")
            return
        }

        do {
            let ipaBytes = try Data(contentsOf: ipaURL)
            print("[Bridge] 开始安装 \(bundleId) (\(ipaBytes.count) bytes)")

            // 先 AFC 传包，再调 installation_proxy 安装
            try Install.yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
            try Install.installIpa(bundleId: bundleId)

            print("[Bridge] 安装完成: \(bundleId)")
            // 清理临时文件
            try? FileManager.default.removeItem(at: ipaURL)
            uploadedIpaURL = nil

            sendResponse(conn: conn, status: 200,
                         body: """{"installed": true, "bundleId": "\(bundleId)"}""",
                         contentType: "application/json")
        } catch {
            print("[Bridge] 安装失败: \(error)")
            sendResponse(conn: conn, status: 500,
                         body: """{"installed": false, "error": "\(error.localizedDescription)"}""",
                         contentType: "application/json")
        }
    }

    // MARK: - HTTP 响应

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
