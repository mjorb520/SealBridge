// Package.swift
// SealBridge: Safari ↔ 设备隧道的 HTTP 桥

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SealBridge",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SealBridge", targets: ["SealBridge"]),
    ],
    targets: [
        .target(
            name: "SealBridge",
            path: "Sources"
        ),
    ]
)
