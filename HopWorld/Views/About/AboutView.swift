import AppKit
import SwiftUI

struct AboutView: View {
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
            LabeledContent("版本", value: appVersion)
                .font(.callout)
                .padding(.top, 4)
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("支持开发")
                .font(.title2.weight(.semibold))
            Text("如果跃界对你有帮助，欢迎请作者喝杯咖啡。微信 / 支付宝扫码即可。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 20) {
                ForEach(SupportPayChannel.allCases) { channel in
                    PayCodeCard(channel: channel) {
                        enlarged = channel
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text("收款码仅用于自愿支持，与代理服务无关。")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

/// 从用户提供的收款码图中解析出的 payload + 主背景色。
enum SupportPayChannel: String, CaseIterable, Identifiable {
    case wechat
    case alipay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wechat: return "微信支付"
        case .alipay: return "支付宝"
        }
    }

    var headline: String {
        switch self {
        case .wechat: return "推荐使用微信支付"
        case .alipay: return "推荐使用支付宝"
        }
    }

    var accountLabel: String {
        switch self {
        case .wechat: return "L E R O Y"
        case .alipay: return "喵喵数码"
        }
    }

    var footerHint: String {
        switch self {
        case .wechat: return "微信支付"
        case .alipay: return "打开支付宝［扫一扫］"
        }
    }

    /// 与原图主背景一致。
    var background: Color {
        switch self {
        case .wechat: return Color(red: 7 / 255, green: 193 / 255, blue: 96 / 255)   // #07C160
        case .alipay: return Color(red: 22 / 255, green: 120 / 255, blue: 255 / 255) // #1678FF
        }
    }

    var payload: String {
        switch self {
        case .wechat:
            return "wxp://f2f0GMSCwBWM6Esa1EBmJLXz3gQZkWKmQ0XdgXpmCiGnxxM"
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
        VStack(spacing: 16) {
            Text(channel.headline)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

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
            }

            Text(channel.accountLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))

            Text(channel.footerHint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(channel.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: onEnlarge)
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

            Button("关闭", action: onClose)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
        .padding(36)
        .frame(minWidth: 380, minHeight: 480)
        .background(channel.background)
    }
}

