import AppKit
import SwiftUI

struct NodeDetailView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var connection: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    let nodeID: UUID
    @State private var copied = false

    private var node: ProxyNode? {
        appState.nodes.first { $0.id == nodeID }
    }

    private var shareLink: String? {
        guard let node else { return nil }
        return ShareLinkExporter.makeShareLink(from: node)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let node {
                    Form {
                        Section("基本信息") {
                            LabeledContent("名称", value: appState.settings.nodeDisplayTitle(node))
                            LabeledContent("协议", value: node.protocolType.displayName)
                            LabeledContent("节点地址", value: "\(node.server):\(node.port)")
                            LabeledContent("传输", value: node.transportDisplayName)
                            LabeledContent("安全", value: node.protocolType == .wireguard ? "WireGuard 内置加密" : node.security.displayName)
                            LabeledContent(
                                "国家",
                                value: "\(FlagResolver.flag(for: CountryResolver.effectiveCode(for: node))) \(CountryResolver.effectiveCountry(for: node).name)"
                            )
                            NodeExitBasicInformation(
                                metadata: node.exitMetadata,
                                countryCode: node.exitMetadata?.countryCode ?? node.countryCode,
                                showChinese: appState.settings.showChineseNodeMetadata
                            )
                            if let sub = subscriptionName(for: node) {
                                LabeledContent("订阅", value: sub)
                            }
                            if node.isFavorite {
                                LabeledContent("收藏", value: "是")
                            }
                        }
                        .textSelection(.enabled)

                        if node.pendingConfigUpdate || node.pendingRemoval {
                            Section("订阅同步") {
                                if node.pendingConfigUpdate {
                                    LabeledContent("参数更新", value: "待应用（连接中仍用旧配置）")
                                    if appState.connection.state.currentNodeID == node.id,
                                       appState.connection.state.status == .connected {
                                        Button("立即应用并重连") {
                                            Task { await appState.applyPendingConfigForCurrentNode() }
                                        }
                                    }
                                }
                                if node.pendingRemoval {
                                    LabeledContent("订阅状态", value: "待移除（断开后删除）")
                                }
                            }
                        }

                        Section("测速") {
                            LabeledContent("状态", value: node.resolvedTestStatus.displayName)
                            LabeledContent("延迟", value: node.latencyText)
                            LabeledContent("最后一次可用", value: node.lastAvailableText)
                            if let date = node.lastTestDate {
                                LabeledContent(
                                    "最近测速",
                                    value: date.formatted(date: .abbreviated, time: .shortened)
                                )
                            }
                        }

                        Section("连接参数") {
                            if let uuid = hydrated(node).uuid, !uuid.isEmpty {
                                LabeledContent("UUID", value: uuid)
                            }
                            if let method = hydrated(node).method, !method.isEmpty {
                                LabeledContent("加密", value: method)
                            }
                            if let flow = node.flow, !flow.isEmpty {
                                LabeledContent("Flow", value: flow)
                            }
                            if let sni = node.sni, !sni.isEmpty {
                                LabeledContent("SNI", value: sni)
                            }
                            if let host = node.host, !host.isEmpty {
                                LabeledContent("Host", value: host)
                            }
                            if let path = node.path, !path.isEmpty {
                                LabeledContent("Path", value: path)
                            }
                            if let service = node.serviceName, !service.isEmpty {
                                LabeledContent("Service", value: service)
                            }
                            if let fp = node.fingerprint, !fp.isEmpty {
                                LabeledContent("Fingerprint", value: fp)
                            }
                            if let alpn = node.alpn, !alpn.isEmpty {
                                LabeledContent("ALPN", value: alpn)
                            }
                            if FinalMaskCodec.normalize(node.finalMaskJSON) != nil {
                                LabeledContent("FinalMask", value: "已启用（TCP fragment）")
                            }
                            if node.security == .reality {
                                if let pbk = hydrated(node).publicKey, !pbk.isEmpty {
                                    LabeledContent("Public Key", value: pbk)
                                }
                                if let sid = hydrated(node).shortID, !sid.isEmpty {
                                    LabeledContent("Short ID", value: sid)
                                }
                            }
                        }

                        Section("分享") {
                            if let link = shareLink {
                                Text(link)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                HStack {
                                    Button(copied ? "已复制" : "复制链接") {
                                        copyShareLink(link)
                                    }
                                    .disabled(copied)

                                    ShareLink(item: link) {
                                        Label("系统分享", systemImage: "square.and.arrow.up")
                                    }
                                }
                            } else {
                                Text("无法生成分享链接（缺少凭证或参数不完整）")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .formStyle(.grouped)
                } else {
                    UnavailablePlaceholder("节点不存在", systemImage: "server.rack")
                }
            }
            .navigationTitle("节点详情")
            .task(id: nodeID) {
                await appState.refreshMissingExitTypes(nodeIDs: [nodeID])
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if let node {
                    ToolbarItem(placement: .primaryAction) {
                        if connection.state.currentNodeID == node.id,
                           connection.state.status == .connected || connection.state.status == .connecting
                            || connection.state.status == .disconnecting {
                            Button(role: .destructive) {
                                Task { await appState.disconnect() }
                                dismiss()
                            } label: {
                                Text(connection.state.status == .disconnecting ? "断开中…" : "断开")
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(connection.state.status == .disconnecting)
                            .help("断开当前节点连接")
                        } else if node.lastTestStatus == .untested {
                            Button("测试") {
                                Task {
                                    await appState.testNodes([node])
                                }
                            }
                            .disabled(appState.testManager.isTesting)
                        } else {
                            Button("连接") {
                                appState.requestConnect(to: node)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 480)
        }
    }

    private func hydrated(_ node: ProxyNode) -> ProxyNode {
        var copy = node
        KeychainStore.hydrateCredentials(&copy)
        return copy
    }

    private func subscriptionName(for node: ProxyNode) -> String? {
        if let id = node.subscriptionID,
           let sub = appState.subscription(for: id) {
            return sub.name
        }
        if let source = node.sourceName, !source.isEmpty {
            return source
        }
        return nil
    }

    private func copyShareLink(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        copied = true
        appState.statusBanner = "已复制分享链接"
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

private struct NodeExitBasicInformation: View {
    @ObservedObject private var cityLibrary = ChineseCityLibrary.shared
    let metadata: NodeExitMetadata?
    let countryCode: String?
    let showChinese: Bool

    var body: some View {
        let city = ExitMetadataLocalization.city(metadata?.city, countryCode: countryCode,
            localizedCity: metadata?.localizedCity, showChinese: showChinese)
        let networkOperator = ExitMetadataLocalization.networkOperator(metadata?.networkOperator, showChinese: showChinese)
        Group {
            LabeledContent("出口 IP", value: metadata?.ip ?? "未知")
            LabeledContent("出口 IP 属性", value: metadata?.networkType?.displayName ?? "未知")
            LabeledContent("出口城市", value: city)
                .help(ExitMetadataLocalization.help(raw: metadata?.city, displayed: city, showChinese: showChinese))
            LabeledContent("出口运营商", value: networkOperator)
                .help(ExitMetadataLocalization.help(raw: metadata?.networkOperator, displayed: networkOperator, showChinese: showChinese))
            LabeledContent("ASN", value: metadata?.asn ?? "未知")
        }
    }
}
