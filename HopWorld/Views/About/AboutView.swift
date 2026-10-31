import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var appState: AppState
    @State private var enlarged: SupportPayChannel?

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                componentUpdatesEntry
                supportSection
                footer
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .sheet(item: $enlarged) { channel in
            EnlargedPayCodeView(channel: channel) {
                enlarged = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("跃界")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("HopWorld")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text("基于 Xray 的 macOS 代理客户端。测速、收藏、故障切换与订阅更新，尽量少打扰。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var componentUpdatesEntry: some View {
        HStack(spacing: 16) {
            Text("应用版本 \(appVersion)")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("组件更新").font(.headline)
                UsageHelpButton(title: "组件更新说明", text: "统一管理 Xray、sing-box 与 GeoFiles 的版本和自动更新。")
            }
            Spacer()
            Button("管理更新") { appState.showComponentUpdates = true }
                .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("支持开发")
                .font(.title2.weight(.semibold))
            Text("如果跃界对你有帮助，欢迎请作者喝杯咖啡。支持微信 / USDT / 支付宝，点击收款码可放大查看。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                ForEach(SupportPayChannel.allCases) { channel in
                    PayCodeCard(channel: channel) {
                        enlarged = channel
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("收款码仅用于自愿支持，与代理服务无关。")
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                Text("中文地名数据：")
                Link("GeoNames", destination: URL(string: "https://www.geonames.org/")!)
                Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

struct ComponentUpdatesDialog: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("组件更新").font(.title2.weight(.semibold))
                    UsageHelpButton(title: "更新说明", text: "每天启动会检查更新。开启自动更新后，检查到可用版本会立即安装：Xray 只装官方稳定版，sing-box / GeoFiles 装当前应用已适配版本。也可手动点「检查更新」；关闭自动更新时需再点「安装版本」或「更新」。安装后下次连接或测试生效，当前连接不受影响。")
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            XrayVersionSection(updater: appState.xrayUpdater)
            Divider()
            ComponentUpdateRow(updater: appState.singBoxUpdater)
            Divider()
            ComponentUpdateRow(updater: appState.geoFilesUpdater)
            Divider()
            ComponentDownloadMirrorRow(updater: appState.xrayUpdater)
        }
        .padding(20)
        .frame(width: 740)
        .fixedSize(horizontal: false, vertical: true)
    }

}

private struct ComponentDownloadMirrorRow: View {
    @ObservedObject var updater: XrayUpdateManager

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("下载线路")
                UsageHelpButton(title: "下载线路说明", text: "三个组件共用此设置。仅加速安装包下载；版本检查仍走 GitHub API。镜像为第三方公益服务，下载后仍校验官方 SHA256。")
            }
            Picker("下载线路", selection: $updater.downloadMirror) {
                ForEach(XrayDownloadMirror.allCases) { mirror in
                    Text(mirror.title).tag(mirror)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(updater.isUpdating)
            Spacer()
        }
    }
}

private struct ComponentUpdateRow: View {
    @ObservedObject var updater: ComponentUpdateManager

    private var details: String {
        var lines = [updater.component.summary]
        if updater.installedVersion == nil {
            lines.append(updater.component == .geoFiles ? "当前使用 Xray 随附规则。" : "尚未安装，首次使用时按需下载。")
        }
        if let latest = updater.latestVersion { lines.append("上游稳定版：\(latest)") }
        if let version = updater.installVersion { lines.append("可安装版本：\(version)") }
        lines.append(updater.status)
        if updater.component == .singBox {
            lines.append("仅安装已验证兼容的稳定版 \(SingBoxInstaller.approvedVersion)。")
        }
        if let checked = updater.lastCheckedAt {
            lines.append("上次检查：" + checked.formatted(date: .abbreviated, time: .shortened))
        }
        return lines.joined(separator: "\n\n")
    }

    private var showsStatus: Bool {
        updater.isBusy || updater.hasError || updater.lastCheckedAt != nil
            || updater.downloadProgress != nil
    }

    private var statusColor: Color {
        if updater.hasError { return .red }
        if updater.status.contains("发现可用更新") { return .orange }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(updater.component.title).font(.headline)
                    UsageHelpButton(title: "\(updater.component.title) 更新说明", text: details)
                }
                .fixedSize()
                Text(updater.installedVersion ?? "未单独安装")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let progress = updater.downloadProgress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if updater.isBusy {
                    ProgressView().controlSize(.small)
                }
                Toggle("自动更新", isOn: Binding(
                    get: { updater.automaticUpdates },
                    set: { enabled in
                        let turnedOn = enabled && !updater.automaticUpdates
                        updater.automaticUpdates = enabled
                        if turnedOn { Task { await updater.checkForUpdates() } }
                    }
                ))
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
                    .accessibilityLabel("\(updater.component.title) 自动更新")
                Button(updater.hasError ? "重新检查" : "检查更新") {
                    Task { await updater.checkForUpdates() }
                }
                .disabled(updater.isBusy)
                .help(updater.automaticUpdates
                      ? "检查有无新版本；开启自动更新时发现可用版本会立即安装"
                      : "检查有无新版本；有更新时请点「更新」安装")
                .accessibilityLabel("检查 \(updater.component.title) 更新")
                if let version = updater.installVersion {
                    Button("更新") { Task { await updater.update() } }
                        .disabled(updater.isBusy)
                        .help("更新至 \(version)")
                        .accessibilityLabel("更新 \(updater.component.title) 至 \(version)")
                }
            }
            .buttonStyle(.bordered)
            if let progress = updater.downloadProgress {
                ProgressView(value: progress).controlSize(.small)
            }
            if showsStatus {
                Text(updater.status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .task { await updater.refreshInstalledVersion() }
    }
}

private struct XrayVersionSection: View {
    @ObservedObject var updater: XrayUpdateManager

    private var details: String {
        var lines = [
            "主要代理内核与节点测试。",
            "开启自动更新后，检查到更新会安装「官方稳定版」；关闭时需在「安装版本」里手动选择。",
            "「最新版本」可能是预发布版，仅手动安装，自动更新不会选用。",
            updater.status
        ]
        if let target = updater.updatingVersion { lines.append("目标版本：\(target)") }
        if let checked = updater.lastCheckedAt {
            lines.append("上次检查：" + checked.formatted(date: .abbreviated, time: .shortened))
        }
        return lines.joined(separator: "\n\n")
    }

    private var showsStatus: Bool {
        updater.isUpdating || updater.hasUpdateError || updater.lastCheckedAt != nil
            || updater.downloadProgress != nil
    }

    private var statusColor: Color {
        if updater.hasUpdateError { return .red }
        if updater.status.contains("发现官方稳定版") { return .orange }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Xray").font(.headline)
                    UsageHelpButton(title: "Xray 更新说明", text: details)
                }
                .fixedSize()
                Text(updater.installedVersion ?? "未检测到")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let progress = updater.downloadProgress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if updater.isUpdating {
                    ProgressView().controlSize(.small)
                }
                Toggle("自动更新", isOn: Binding(
                    get: { updater.automaticUpdates },
                    set: { enabled in
                        let turnedOn = enabled && !updater.automaticUpdates
                        updater.automaticUpdates = enabled
                        if turnedOn { Task { await updater.checkForUpdates() } }
                    }
                ))
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
                    .accessibilityLabel("Xray 自动更新")
                Button(updater.hasUpdateError ? "重新检查" : "检查更新") {
                    Task { await updater.checkForUpdates() }
                }
                .disabled(updater.isUpdating)
                .help(updater.automaticUpdates
                      ? "检查版本；开启自动更新时会安装官方稳定版"
                      : "检查版本；有更新时请到「安装版本」选择官方稳定版")
                .accessibilityLabel("检查 Xray 更新")
                Menu("安装版本") {
                    releaseButton("官方稳定版", release: updater.stableRelease, version: updater.stableVersion)
                    releaseButton("最新版本", release: updater.latestRelease, version: updater.latestVersion)
                }
                .fixedSize()
                .disabled(updater.isUpdating || (updater.stableRelease == nil && updater.latestRelease == nil))
                .accessibilityLabel("选择 Xray 安装版本")
            }
            .buttonStyle(.bordered)
            if let progress = updater.downloadProgress {
                ProgressView(value: progress).controlSize(.small)
            }
            if showsStatus {
                Text(updater.status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .task { await updater.refreshInstalledVersion() }
    }

    private func releaseButton(_ title: String, release: XrayRelease?, version: String?) -> some View {
        let installed = version != nil && updater.installedVersion == version
        let suffix = installed ? "（已安装）" : (release?.prerelease == true ? "（预发布）" : "")
        return Button("\(title) \(version ?? "尚未获取")\(suffix)") {
            if let release { Task { await updater.update(to: release) } }
        }
        .disabled(updater.isUpdating || release == nil || installed)
    }
}

/// 从用户提供的收款码图中解析出的 payload 与卡片主题。
enum SupportPayChannel: String, CaseIterable, Identifiable {
    case wechat
    case usdt
    case alipay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wechat: return "微信支付"
        case .usdt: return "USDT"
        case .alipay: return "支付宝"
        }
    }

    var headline: String {
        switch self {
        case .wechat: return "推荐使用微信支付"
        case .usdt: return "USDT 收款"
        case .alipay: return "推荐使用支付宝"
        }
    }

    var accountLabel: String {
        switch self {
        case .wechat: return "L E R O Y"
        case .usdt: return "USDT（ERC20）"
        case .alipay: return "喵喵数码"
        }
    }

    var footerHint: String {
        switch self {
        case .wechat: return "微信支付"
        case .usdt: return "仅支持 Ethereum 网络"
        case .alipay: return "打开支付宝［扫一扫］"
        }
    }

    var background: Color {
        switch self {
        case .wechat: return Color(red: 7 / 255, green: 193 / 255, blue: 96 / 255)   // #07C160
        case .usdt: return Color(red: 0, green: 128 / 255, blue: 128 / 255)         // #008080
        case .alipay: return Color(red: 22 / 255, green: 120 / 255, blue: 255 / 255) // #1678FF
        }
    }

    var payload: String {
        switch self {
        case .wechat:
            return "wxp://f2f0GMSCwBWM6Esa1EBmJLXz3gQZkWKmQ0XdgXpmCiGnxxM"
        case .usdt:
            return "0x67c110DCDBE2174AA32c84D26D8C337294086838"
        case .alipay:
            return "https://qr.alipay.com/fkx18579lgdnd6ogigc3qc1"
        }
    }

    func qrImage(dimension: CGFloat) -> NSImage? {
        QRCodeGenerator.image(from: payload, dimension: dimension)
    }
}

private struct PayCodeCard: View {
    let channel: SupportPayChannel
    let onEnlarge: () -> Void

    var body: some View {
        Button(action: onEnlarge) {
            VStack(spacing: 16) {
                Text(channel.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(height: 20)

                if let image = channel.qrImage(dimension: 220) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 148, height: 148)
                        .padding(8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text("二维码生成失败")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 148, height: 148)
                        .padding(8)
                }

                Text(channel.accountLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(height: 18)

                Text(channel.footerHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(height: 18)
            }
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .background(channel.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("放大\(channel.title)收款码")
        .accessibilityHint(channel.footerHint)
        .help("点击放大")
    }
}

private struct EnlargedPayCodeView: View {
    let channel: SupportPayChannel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(channel.headline)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            if let image = channel.qrImage(dimension: 480) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Text(channel.accountLabel)
                .font(.headline)
                .foregroundStyle(.white)

            Text(channel.footerHint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))

            if channel == .usdt {
                Text(channel.payload)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(width: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("关闭", action: onClose)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
        .padding(36)
        .frame(minWidth: 380, minHeight: 480)
        .background(channel.background)
    }
}

