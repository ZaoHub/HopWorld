import SwiftUI
import AppKit

struct CodexResetNotificationSettingsFields: View {
    @Binding var settings: CodexResetNotificationSettings
    @ObservedObject var controller: CodexResetNotificationController
    @State private var search = ""
    @State private var editingID: UUID?
    @State private var nickname = ""
    @State private var address = ""
    @State private var showingEditor = false

    private var editedRecipient: CodexResetNotificationRecipient {
        .init(nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines), address: address)
    }

    private var testValidationError: String? {
        var draft = settings
        draft.enabled = true
        return draft.validationError
    }

    var body: some View {
        Section("Codex 重置提醒") {
            HStack {
                Toggle("启用 iMessage 通知", isOn: $settings.enabled)
                CodexNotificationInfoButton("查看重置提醒规则", text: "首次开启只建立基线，等待后续变化；每 5 分钟随 Codex 用量刷新检查。跃界运行且代理已连接时监测，关闭主窗口后仍继续。\n\n周余量恢复到 100%，或保持 100% 但周重置时间变化时提醒；可用重置次数增加时也提醒，两者同时发生合并为一条。\n\n按规则推断：可用重置次数减少视为手动重置，不发送周额度提醒；其余符合条件的变化视为官方重置，不要求等到原定到期。购买额度不参与判断。")
            }
        }
        Section("收件人 · 已选择 \(settings.selectedRecipients.count) 位") {
            HStack {
                TextField("筛选昵称或账号", text: $search)
                    .textFieldStyle(.roundedBorder)
                CodexNotificationInfoButton("查看收件人与筛选说明", text: "添加 iMessage 手机号或 Apple 账号邮箱，再勾选需要接收通知的人。\n\n仅向勾选的收件人分别发送，重复账号只发一次。筛选只缩小列表，不改变勾选；编辑与删除在“应用设置”后保存。")
            }
            if !settings.recipients.isEmpty && !settings.recipients.contains(where: matches) {
                Text("没有匹配的收件人").foregroundStyle(.secondary)
            }
            ForEach($settings.recipients) { $recipient in
                if matches(recipient) {
                    HStack(spacing: 8) {
                        Toggle(isOn: $recipient.isSelected) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipient.nickname.isEmpty ? "未命名收件人" : recipient.nickname)
                                Text(recipient.address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 0)
                        Button {
                            editingID = recipient.id
                            nickname = recipient.nickname
                            address = recipient.address
                            showingEditor = true
                        } label: { Image(systemName: "pencil") }
                        .help("编辑收件人")
                        .accessibilityLabel("编辑 \(recipient.nickname) 收件人")
                        Button(role: .destructive) {
                            settings.recipients.removeAll { $0.id == recipient.id }
                            if editingID == recipient.id { showingEditor = false }
                        } label: { Image(systemName: "trash") }
                        .help("删除收件人，应用后保存")
                        .accessibilityLabel("删除 \(recipient.nickname) 收件人")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("添加收件人", systemImage: "plus") {
                editingID = nil
                nickname = ""
                address = ""
                showingEditor = true
            }
            if let error = settings.validationError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        Section("监测与发送状态") {
            HStack {
                Text(controller.monitoringStatus).font(.caption)
                Spacer(minLength: 0)
                CodexNotificationInfoButton("查看监测与发送状态说明", text: "自动监测状态来自已应用的设置；下方显示最近一次自动提醒或测试发送的结果。成功提交只表示已交给本机“信息”，不代表收件人已收到，发送失败不自动重试。")
            }
            if controller.isSending { ProgressView().controlSize(.small) }
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("测试发送（\(settings.selectedRecipients.count) 位）") {
                    controller.sendTest(using: settings)
                }
                .disabled(testValidationError != nil || controller.isSending)
                .help(testValidationError ?? "向当前勾选的收件人发送测试 iMessage")
                CodexNotificationInfoButton("查看测试发送说明", text: "实际向当前勾选账号发送一条测试 iMessage，未应用也能测试，不改变自动通知开关或基线。无需先开启自动通知。")
            }
            HStack {
                Button("打开“信息”") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app")) }
                CodexNotificationInfoButton("查看 iMessage 登录与权限说明", text: "请先在本机“信息”登录 iMessage。首次发送时 macOS 会询问自动化权限；如被拒绝，可在系统设置 → 隐私与安全性 → 自动化中允许跃界控制“信息”。")
            }
        }
        .sheet(isPresented: $showingEditor) { recipientEditor }
    }

    private func matches(_ recipient: CodexResetNotificationRecipient) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || recipient.nickname.localizedCaseInsensitiveContains(query)
            || recipient.address.localizedCaseInsensitiveContains(query)
    }

    private var recipientEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editingID == nil ? "添加收件人" : "编辑收件人").font(.headline)
                Spacer()
                CodexNotificationInfoButton("查看收件人账号说明", text: "手机号建议包含国家或地区代码，例如 +86。账号需已开通 iMessage。")
            }
            Form {
                TextField("昵称", text: $nickname)
                TextField("iMessage 手机号或邮箱", text: $address)
            }
            if !address.isEmpty, let error = editedRecipient.addressValidationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { showingEditor = false }
                Button("保存收件人") {
                    if let index = settings.recipients.firstIndex(where: { $0.id == editingID }) {
                        settings.recipients[index].nickname = editedRecipient.nickname
                        settings.recipients[index].address = editedRecipient.deliveryAddress
                    } else {
                        settings.recipients.append(.init(nickname: editedRecipient.nickname,
                            address: editedRecipient.deliveryAddress))
                    }
                    showingEditor = false
                }
                .disabled(editedRecipient.addressValidationError != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440)
    }
}

struct CodexNotificationInfoButton: View {
    let title: String
    let text: String
    @State private var isPresented = false

    init(_ title: String, text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        Button { isPresented = true } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help(title)
            .accessibilityLabel(title)
            .popover(isPresented: $isPresented) {
                Text(text).font(.callout).padding(16).frame(width: 320)
            }
    }
}
