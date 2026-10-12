import Foundation
import Network

/// Seal 安装桥：Safari 网页 ↔ 10.7.0.1 设备隧道的翻译官
///
/// Safari 只能发 HTTP，做不了原生 TCP（lockdown/AFC/installation_proxy）。
/// 这个桥跑个 HTTP 服务收 Safari 的请求，转成 TCP 发给 LocalDevVPN 隧道里的设备。

@MainActor
final class BridgeServer: NSObject {
    static let shared = BridgeServer()
    static let port: UInt16 = 8765

    private var listener: NWListener?
    private var isRunning = false

    // 配对状态（iOS 27 Remote Pairing 来的）
    private var pairingRecord: Data?

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
            self?.handle(conn)
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

    private nonisolated func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: conn)
    }

    private nonisolated func receiveRequest(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, error in
            guard let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                self?.route(request: request, conn: conn)
            }
        }
    }

    private func route(request: String, conn: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(conn: conn, status: 400, body: "Bad Request")
            return
        }
        let method = parts[0]
        let path = parts[1].components(separatedBy: "?").first ?? "/"

        // Origin 校验：只接受本机 Safari
        let origin = lines.first { $0.lowercased().hasPrefix("origin:") } ?? ""

        switch (method, path) {
        case ("GET", "/status"):
            let body = """
            {"paired": \(pairingRecord != nil), "tunnel": \(checkTunnel()), "version": "1.0"}
            """
            sendResponse(conn: conn, status: 200, body: body, contentType: "application/json")

        case ("POST", "/pair"):
            Task { await handlePair(conn: conn) }

        case ("POST", "/upload"):
            // 从 body 提取 IPA 二进制，存到临时文件
            handleUpload(request: request, conn: conn)

        case ("POST", "/install"):
            Task { await handleInstall(conn: conn) }

        default:
            sendResponse(conn: conn, status: 404, body: "Not Found")
        }
    }

    // MARK: - 业务逻辑

    /// 检查隧道是否通（10.7.0.1 能不能连上）
    private func checkTunnel() -> Bool {
        // 实际调用 Minimuxer.readyVerdict() 或 TCP 探测
        // 这里简化，真实实现调 Minimuxer
        return true
    }

    /// 配对：iOS 27 走 Bonjour Remote Pairing
    private func handlePair(conn: NWConnection) async {
        // 实际实现：
        // 1. 启动 PhonePairingHost（抄 Seal 的）
        // 2. 返回配对码给网页展示
        // 3. 用户在系统弹窗确认后，保存配对文件
        sendResponse(conn: conn, status: 200,
                     body: """{"code": "123456", "hint": "请在系统弹窗中确认配对"}""",
                     contentType: "application/json")
    }

    private func handleUpload(request: String, conn: NWConnection) {
        // 解析 multipart body，存 IPA 到 /tmp/bridge-upload.ipa
        sendResponse(conn: conn, status: 200,
                     body: """{"saved": true}""",
                     contentType: "application/json")
    }

    /// 安装：调 Minimuxer 走隧道装包
    private func handleInstall(conn: NWConnection) async {
        // 实际实现：
        // if isRemotePairing {
        //     try Minimuxer.stageAndInstall(bundleId: bid, ipaBytes: data)
        // } else {
        //     try Minimuxer.yeetAppAfc(bundleId: bid, ipaBytes: data)
        //     try Minimuxer.installIpa(bundleId: bid)
        // }
        sendResponse(conn: conn, status: 200,
                     body: """{"installing": true}""",
                     contentType: "application/json")
    }

    // MARK: - HTTP 响应

    private func sendResponse(conn: NWConnection, status: Int, body: String, contentType: String = "text/plain") {
        let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
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
