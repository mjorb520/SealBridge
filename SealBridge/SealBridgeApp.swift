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
    @Published var log: [String] = []
    private var timer: Timer?

    func start() {
        BridgeServer.shared.start()
        isRunning = true
        addLog("桥已启动，端口 8765")
        addLog("Safari 打开安装器网页即可使用")
        // 轮询状态（配对全自动，无需手动）
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
    }

    func refreshStatus() {
        let s = BridgeServer.shared.getStatus()
        let wasPaired = paired
        paired = s.paired
        tunnelOK = s.tunnel
        if paired && !wasPaired {
            addLog("设备已就绪，可以安装")
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
                    HStack {
                        Text("状态")
                        Spacer()
                        if model.paired {
                            Text("已就绪").foregroundColor(.green)
                        } else if model.tunnelOK {
                            Text("连接设备中…").foregroundColor(.orange)
                        } else {
                            Text("等待 VPN 隧道").foregroundColor(.orange)
                        }
                    }
                    Text("配对全自动，无需手动操作。隧道通后桥会自动连接设备。")
                        .font(.footnote).foregroundColor(.secondary)
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
