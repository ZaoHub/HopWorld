import SwiftUI

/// 侧边导航栏底部：测速中显示进度，空闲时显示连接/节点实时延迟。
struct TestProgressFloatingBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var connection: ConnectionManager

    private var testManager: NodeTestManager { appState.testManager }

    private var isBatchTesting: Bool {
        testManager.phase == .running || testManager.phase == .paused
    }

    var body: some View {
        Group {
            if isBatchTesting {
                batchTestingContent
            } else if testManager.isProbingApps {
                appProbeContent
            } else {
                liveLatencyContent
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    // MARK: - Batch test

    private var batchTestingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(testManager.statusText.isEmpty ? "正在测速…" : testManager.statusText)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(testManager.phase.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(batchPhaseColor)
            }

            ProgressView(value: testManager.progress)

            HStack(spacing: 10) {
                if testManager.totalCount > 0 {
                    Text("\(testManager.testedCount)/\(testManager.totalCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("可用 \(testManager.availableCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
                Text("不可用 \(testManager.unavailableCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
                Text("失败 \(testManager.failedCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.red)
                Spacer(minLength: 0)
            }

            testActionButtons
        }
    }

    // MARK: - App probe

    private var appProbeContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(testManager.appProbeStatusText)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text("应用探测")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            if let label = testManager.appProbeNodeLabel, !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            testActionButtons
        }
    }

    // MARK: - Live latency

    private var liveLatencyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 8, height: 8)
                if let node = appState.currentNode,
                   connection.state.status == .connected || connection.state.status == .connecting || connection.state.status == .disconnecting {
                    Text(FlagResolver.flag(for: CountryResolver.effectiveCode(for: node)))
                        .font(.caption)
                }
                Text(connectionHeadline)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(connectionHeadline)
            }
            if let latencyText = primaryLatencyLabel {
                HStack {
                    Text("延迟").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(latencyText)
                        .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(latencyColor)
                        .fixedSize()
                }
            }

            Text(connectionSubline)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Divider()

            HStack(alignment: .top, spacing: 8) {
                trafficColumn(
                    "下载", systemImage: "arrow.down",
                    mbps: connection.state.downloadMbps,
                    bytes: connection.state.sessionDownloadBytes
                )
                trafficColumn(
                    "上传", systemImage: "arrow.up",
                    mbps: connection.state.uploadMbps,
                    bytes: connection.state.sessionUploadBytes
                )
            }

            if connection.state.status == .connecting || connection.state.status == .disconnecting {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var testActionButtons: some View {
        HStack(spacing: 8) {
            Button("详情") {
                appState.selectedSidebar = .testing
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if testManager.canPause {
                Button("停止") {
                    appState.stopTesting()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("暂停") {
                    appState.pauseTesting()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if testManager.canResume {
                Button("继续") {
                    Task { await appState.resumeTesting() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var connectionHeadline: String {
        switch connection.state.status {
        case .connected, .connecting, .disconnecting:
            if let title = appState.currentNode?.displayTitle {
                let nodeName = title.components(separatedBy: "|").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? title
                return nodeName.isEmpty ? title : nodeName
            }
            return connection.state.currentCountryName ?? "代理"
        case .error:
            return "连接异常"
        case .disconnected:
            return "未连接"
        }
    }

    private var connectionSubline: String {
        switch connection.state.status {
        case .connected:
            if let exit = connection.state.exitIP {
                return "出口 \(exit)"
            }
            return connection.state.status.displayName
        case .connecting:
            return appState.currentNode.map { "正在连接 \($0.displayTitle)" } ?? connection.state.status.displayName
        case .disconnecting:
            return connection.state.status.displayName
        case .error:
            return connection.state.lastError ?? connection.state.status.displayName
        case .disconnected:
            if let node = appState.currentNode ?? appState.recentNodes.first {
                let status = node.resolvedTestStatus.displayName
                let lat = node.latencyText
                return "最近：\(node.displayTitle) · \(status) \(lat)"
            }
            return "连接后显示实时延迟"
        }
    }

    private var primaryLatencyLabel: String? {
        switch connection.state.status {
        case .connected:
            return LatencyFormat.seconds(connection.state.latency)
        case .connecting, .disconnecting:
            return nil
        case .error, .disconnected:
            if let node = appState.currentNode ?? appState.recentNodes.first,
               let ms = node.lastLatency {
                return LatencyFormat.seconds(ms)
            }
            return nil
        }
    }

    private var latencyColor: Color {
        guard connection.state.status == .connected,
              let ms = connection.state.latency else {
            return .secondary
        }
        let tier = NodeTestStatus.from(latencyMs: ms)
        if tier.isUsable, tier != .fairlySlow, tier != .slow, tier != .ultraSlow {
            return .green
        }
        if tier == .fairlySlow || tier == .slow {
            return .orange
        }
        return .secondary
    }

    private var connectionStatusColor: Color {
        switch connection.state.status {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        case .error: return .red
        case .disconnected: return .secondary
        }
    }

    private var batchPhaseColor: Color {
        switch testManager.phase {
        case .running: return .blue
        case .paused: return .orange
        case .idle, .finished: return .secondary
        }
    }

    private func trafficColumn(_ title: String, systemImage: String, mbps: Double, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Text(speedText(connection.state.status == .connected ? mbps : 0))
                .fontWeight(.medium)
            Text("本次累计 " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary))
                .foregroundStyle(.secondary)
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speedText(_ mbps: Double) -> String {
        let bytesPerSecond = max(0, mbps) * 1_000_000 / 8
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }
}
