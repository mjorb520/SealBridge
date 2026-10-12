import SwiftUI

/// SealBridge 主入口：极简，只负责把桥跑起来
@main
struct SealBridgeApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
    }
}

@MainActor
final class BridgeModel: ObservableObject {
    @Published var isRunning = false
    @Published var paired = false
    @Published var tunnelOK = false
    @Published var pairCode: String?
    @Published var pairing = false
    @Published var log: [String] = []
    private var timer: Timer?

    func start() {
        BridgeServer.shared.start()
        isRunning = true
        addLog("桥已启动，端口 8765")
        addLog("Safari 打开安装器网页即可使用")
        // 轮询状态
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
    }

    func refreshStatus() {
        let s = BridgeServer.shared.getStatus()
        paired = s.paired
        tunnelOK = s.tunnel
        if let code = s.pairCode, !code.isEmpty {
            if pairCode != code {
                pairCode = code
                addLog("配对码: \(code)，请在系统弹窗中确认")
            }
            pairing = true
        } else if s.paired {
            pairing = false
            pairCode = nil
        }
    }

    func startPairing() {
        pairing = true
        pairCode = nil
        addLog("开始配对…")
        BridgeServer.shared.triggerPairing { [weak self] code in
            Task { @MainActor [weak self] in
                if let code = code {
                    self?.pairCode = code
                    self?.addLog("配对码: \(code)")
                }
            }
        }
    }

    func addLog(_ msg: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(time) \(msg)")
    }
}

struct ContentView: View {
    @EnvironmentObject var model: BridgeModel

    var body: some View {
        NavigationView {
            List {
                Section("状态") {
                    HStack {
                        Text("桥服务")
                        Spacer()
                        Text(model.isRunning ? "运行中" : "已停止")
                            .foregroundColor(model.isRunning ? .green : .red)
                    }
                    HStack {
                        Text("配对")
                        Spacer()
                        Text(model.paired ? "已配对" : "未配对")
                            .foregroundColor(model.paired ? .green : .orange)
                    }
                    HStack {
                        Text("隧道")
                        Spacer()
                        Text(model.tunnelOK ? "通畅" : "未检测")
                            .foregroundColor(model.tunnelOK ? .green : .orange)
                    }
                }
                Section("配对") {
                    if let code = model.pairCode {
                        HStack {
                            Text("配对码")
                            Spacer()
                            Text(code)
                                .font(.title2.bold())
                                .foregroundColor(.blue)
                        }
                        Text("请在系统弹出的配对窗口中输入此码确认")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        Button(action: { model.startPairing() }) {
                            HStack {
                                Spacer()
                                Text(model.pairing ? "配对中…" : "开始配对")
                                Spacer()
                            }
                        }
                        .disabled(model.pairing || model.paired)
                    }
                }
                Section("日志") {
                    ForEach(model.log, id: \.self) { line in
                        Text(line).font(.caption).foregroundColor(.secondary)
                    }
                }
                Section {
                    Text("这是 Seal 网页安装器的桥。用完 Seal 装好后可以删除。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("SealBridge")
        }
    }
}
