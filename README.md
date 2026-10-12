# SealBridge

Seal 网页安装器的桥 App：Safari 网页 ↔ 设备隧道的翻译官。

```
Safari 网页 ──HTTP──→ SealBridge ──TCP──→ 10.7.0.1 ──→ iPhone
（签名）              （本 App）      （LocalDevVPN 隧道）
```

## 为什么需要它

Safari 网页只能发 HTTP，做不了原生 TCP（lockdown/AFC/installation_proxy）。
这个桥跑个 HTTP 服务，把网页的请求翻译成 TCP 发给设备。

## 接口

| 接口 | 方法 | 说明 |
|------|------|------|
| `/status` | GET | 配对状态、隧道状态 |
| `/pair` | POST | iOS 27 Remote Pairing，返回配对码 |
| `/upload` | POST | 接收已签名 IPA |
| `/install` | POST | 调 Minimuxer 安装 |

## 复用

- Minimuxer：从 MJorb 仓库 `Vendor/Minimuxer` 拿
- 配对：抄 Seal 的 `PhonePairingHost`（iOS 27 Bonjour）
- 签名：网页端二开 SideImpactor 的 WASM zsign

## 用户流程

1. App Store 装 SealBridge
2. Safari 打开网页安装器
3. 网页签名 → 桥安装 Seal
4. Seal 装好后，SealBridge 可删
