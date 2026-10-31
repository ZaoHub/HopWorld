import SwiftUI

/// 侧边导航栏底部：显示延迟与应用连通测试进度，空闲时显示连接实时信息。
struct TestProgressFloatingBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var connection: ConnectionManager

    @EnvironmentObject private var testManager: NodeTestManager

    private var isBatchTesting: Bool {
        testManager.phase == .running || testManager.phase == .paused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isBatchTesting {
                batchTestingContent
            }
            if appState.appProbeBatch.isRunning {
                appProbeBatchContent
            }
            if testManager.isProbingApps {
                appProbeContent
            }
            if !isBatchTesting, !appState.appProbeBatch.isRunning, !testManager.isProbingApps {
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

            Grid(horizontalSpacing: 2, verticalSpacing: 4) {
                GridRow(alignment: .firstTextBaseline) {
                    batchStatisticText("\(testManager.totalCount)", color: .secondary)
                        .help("总数：\(testManager.totalCount)")
                    batchStatisticText("可用", color: .green)
                    batchStatisticText("不可用", color: .orange)
                    batchStatisticText("失败", color: .red)
                }
                GridRow(alignment: .firstTextBaseline) {
                    batchStatisticText("\(testManager.testedCount)", color: .secondary)
                        .help("已测试：\(testManager.testedCount)")
                    batchStatisticText("\(testManager.availableCount)", color: .green)
                    batchStatisticText("\(testManager.unavailableCount)", color: .orange)
                    batchStatisticText("\(testManager.failedCount)", color: .red)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("测试统计")
            .accessibilityValue("已测试 \(testManager.testedCount)，总数 \(testManager.totalCount)，可用 \(testManager.availableCount)，不可用 \(testManager.unavailableCount)，失败 \(testManager.failedCount)")

            testActionButtons
        }
    }

    private func batchStatisticText(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .help(value)
    }

    // MARK: - App probe

    private var appProbeBatchContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppProbeProgressView(
                title: "应用连通 · 可用节点",
                completed: appState.appProbeBatch.completed,
                total: appState.appProbeBatch.total,
                statusText: appState.appProbeBatch.statusText
            )
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button("详情") { appState.selectedSidebar = .testing }
                Spacer(minLength: 4)
                Button("停止") { appState.stopAppProbeBatch() }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var appProbeContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppProbeProgressView(
                title: "应用连通 · 单节点",
                completed: testManager.appProbeCompletedCount,
                total: testManager.appProbeResults.count,
                statusText: testManager.appProbeNodeLabel.map { appState.settings.nodeDisplayName($0) }
                    ?? testManager.appProbeStatusText
            )
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button("详情") { appState.selectedSidebar = .testing }
                Spacer(minLength: 4)
                Button("取消探测") {
                    testManager.resetAppProbes(targets: appState.settings.automaticAppProbeTargets)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Live latency

    private var liveLatencyContent: some View {
        let countryText = Text(connectionHeadline).font(.caption.weight(.semibold))
        let typeText = Text(connectionExitIPType.map { " · \($0)" } ?? "")
            .font(.caption2).foregroundColor(.secondary)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 8, height: 8)
                if let node = appState.currentNode,
                   connection.state.status == .connected || connection.state.status == .connecting || connection.state.status == .disconnecting {
                    Text(FlagResolver.flag(for: CountryResolver.effectiveCode(for: node)))
                        .font(.caption)
                }
                Text("\(countryText)\(typeText)")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(connectionExitIPType.map { "\(connectionHeadline) · 出口 IP 属性：\($0)" } ?? connectionHeadline)
                if connection.state.status == .connecting || connection.state.status == .disconnecting {
                    ProgressView()
                        .controlSize(.small)
                }
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

            Group {
                if connection.state.status == .connected, let connectedAt = connection.state.connectedAt {
                    HStack(spacing: 4) {
                        Text("连接时长")
                        Text(connectedAt, style: .timer)
                            .monospacedDigit()
                    }
                } else {
                    Text(connectionSubline)
                }
            }
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
                    alignment: .leading,
                    mbps: connection.state.downloadMbps,
                    bytes: connection.state.sessionDownloadBytes
                )
                trafficColumn(
                    "上传", systemImage: "arrow.up",
                    alignment: .trailing,
                    mbps: connection.state.uploadMbps,
                    bytes: connection.state.sessionUploadBytes
                )
            }

        }
    }

    private var testActionButtons: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button("详情") {
                appState.selectedSidebar = .testing
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if testManager.canPause {
                Spacer(minLength: 4)
                Button("停止") {
                    appState.stopTesting()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Spacer(minLength: 4)
                Button("暂停") {
                    appState.pauseTesting()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if testManager.canResume {
                Spacer(minLength: 4)
                Button("继续") {
                    Task { await appState.resumeTesting() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
    }

    private var connectionHeadline: String {
        switch connection.state.status {
        case .connected, .connecting, .disconnecting:
            if let node = appState.currentNode {
                return CountryResolver.displayName(for: CountryResolver.effectiveCode(for: node))
            }
            return connection.state.currentCountryCode.map { CountryResolver.displayName(for: $0) } ?? "代理"
        case .error:
            return "连接异常"
        case .disconnected:
            return "未连接"
        }
    }

    private var connectionExitIPType: String? {
        switch connection.state.status {
        case .connected:
            return (connection.state.exitIPType ?? appState.currentNode?.exitMetadata?.networkType)?.displayName ?? "未知"
        case .connecting, .disconnecting:
            return appState.currentNode?.exitMetadata?.networkType?.displayName ?? "未知"
        case .error, .disconnected:
            return nil
        }
    }

    private var connectionSubline: String {
        switch connection.state.status {
        case .connected:
            return connection.state.status.displayName
        case .connecting:
            return appState.currentNode.map { "正在连接 \(appState.settings.nodeDisplayTitle($0))" } ?? connection.state.status.displayName
        case .disconnecting:
            return connection.state.status.displayName
        case .error:
            return connection.state.lastError ?? connection.state.status.displayName
        case .disconnected:
            if let node = appState.currentNode ?? appState.recentNodes.first {
                let status = node.resolvedTestStatus.displayName
                let lat = node.latencyText
                return "最近：\(appState.settings.nodeDisplayTitle(node)) · \(status) \(lat)"
            }
            return "连接后显示实时延迟"
        }
    }

    private var primaryLatencyLabel: String? {
        switch connection.state.status {
        case .connected:
            return LatencyFormat.display(connection.state.latency)
        case .connecting, .disconnecting:
            return nil
        case .error, .disconnected:
            if let node = appState.currentNode ?? appState.recentNodes.first,
               let ms = node.lastLatency {
                return LatencyFormat.display(ms)
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

    private func trafficColumn(_ title: String, systemImage: String, alignment: HorizontalAlignment, mbps: Double, bytes: Int64) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Text(speedText(connection.state.status == .connected ? mbps : 0))
                .fontWeight(.medium)
            Text("本次累计")
                .foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.secondary)
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
    }

    private func speedText(_ mbps: Double) -> String {
        let bytesPerSecond = max(0, mbps) * 1_000_000 / 8
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }
}

struct AppProbeProgressView: View {
    var title: String
    var completed: Int
    var total: Int
    var statusText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .fontWeight(.medium)
                Spacer(minLength: 4)
                Text("\(completed)/\(total)")
                    .monospacedDigit()
            }
            .font(.caption)
            ProgressView(value: Double(completed), total: Double(max(1, total)))
                .accessibilityLabel(title)
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(statusText)
        }
    }
}
