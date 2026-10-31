import AppKit
import ApplicationServices

struct CodexInterfaceHealthSnapshot: Equatable, Sendable {
    enum Status: String, Sendable {
        case observing, permissionRequired, unavailable
        var displayName: String {
            switch self {
            case .observing: return "正在识别 Codex 可见的状态提示"
            case .permissionRequired: return "需要辅助功能权限才能识别界面提示"
            case .unavailable: return "当前无法确认 Codex 界面状态"
            }
        }
    }

    var inviteEnabled: Bool?
    var workspaceUnavailable: Bool?
    var reconnecting: Bool?
    var waitingForNetwork: Bool?
    var status: Status = .unavailable
    var readable: Bool { status == .observing }
}

/// Reads only status controls from the supplied Codex process; it never requests AX permission.
enum CodexInterfaceHealthReader {
    struct Node: Sendable {
        let role: String
        var label: String? = nil
        var enabled: Bool? = nil
        var hidden = false
        var children: [Node] = []
    }

    private struct Entry {
        let element: AXUIElement
        let parent: Int?
        let depth: Int
        var node: Node
        var childIndices: [Int] = []
    }

    static func snapshot(pid: pid_t) -> CodexInterfaceHealthSnapshot {
        guard AXIsProcessTrusted() else { return .init(status: .permissionRequired) }
        guard pid > 0, let process = NSRunningApplication(processIdentifier: pid),
              process.bundleIdentifier == "com.openai.codex", !process.isTerminated, !process.isHidden else { return .init() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.080
        let application = AXUIElementCreateApplication(pid)
        func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(0.050, remaining)))
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
        }
        guard let windows = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement], !windows.isEmpty else { return .init() }
        var entries: [Entry] = []
        var complete = windows.count <= 8
        for window in windows.prefix(8) {
            if attribute(window, kAXMinimizedAttribute as CFString) as? Bool == true { complete = false; continue }
            entries.append(Entry(element: window, parent: nil, depth: 0, node: Node(role: kAXWindowRole)))
        }
        guard !entries.isEmpty else { return .init() }
        let roots = Array(entries.indices)
        var index = 0
        while index < entries.count {
            guard entries.count < 1_400, ProcessInfo.processInfo.systemUptime < deadline else { complete = false; break }
            let element = entries[index].element
            guard let role = attribute(element, kAXRoleAttribute as CFString) as? String else { complete = false; index += 1; continue }
            entries[index].node = Node(role: role)
            if attribute(element, "AXHidden" as CFString) as? Bool == true {
                entries[index].node.hidden = true
                index += 1
                continue
            }
            if isControl(role) {
                entries[index].node.label = controlLabel(element, attribute: attribute)
                entries[index].node.enabled = attribute(element, kAXEnabledAttribute as CFString) as? Bool
            }
            // Editable values and document contents are never fetched.
            if [kAXTextAreaRole, kAXTextFieldRole, "AXComboBox", "AXSecureTextField"].contains(role) {
                index += 1
                continue
            }
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                guard entries[index].depth < 32, entries.count + children.count < 1_400 else { complete = false; index += 1; continue }
                let depth = entries[index].depth + 1
                for child in children {
                    entries[index].childIndices.append(entries.count)
                    entries.append(Entry(element: child, parent: index, depth: depth, node: Node(role: "")))
                }
            } else if [kAXGroupRole, kAXWindowRole, "AXWebArea", kAXScrollAreaRole].contains(role) {
                complete = false
            }
            index += 1
        }
        // Only a compact group already containing Retry may expose a workspace warning title.
        for groupIndex in entries.indices where isGroup(entries[groupIndex].node.role) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { complete = false; break }
            let children = entries[groupIndex].childIndices.filter { !entries[$0].node.hidden }
            guard !children.isEmpty, children.count <= 8 else { continue }
            let candidates = children + children.flatMap { entries[$0].childIndices.count <= 8 ? entries[$0].childIndices : [] }
            guard candidates.count <= 16,
                  candidates.contains(where: { isRetry(entries[$0].node) }) else { continue }
            for child in candidates where [kAXStaticTextRole, "AXHeading"].contains(entries[child].node.role) {
                let element = entries[child].element
                let label = attribute(element, kAXTitleAttribute as CFString) as? String
                    ?? attribute(element, kAXValueAttribute as CFString) as? String
                if let label, isWorkspaceTitle(label) { entries[child].node.label = label }
            }
        }
        if ProcessInfo.processInfo.systemUptime >= deadline { complete = false }
        // Tree values contain only short native control labels and recognized warning titles.
        for child in entries.indices.reversed() {
            if let parent = entries[child].parent { entries[parent].node.children.insert(entries[child].node, at: 0) }
        }
        return classify(roots.map { entries[$0].node }, complete: complete && index == entries.count)
    }

    static func classify(_ roots: [Node], complete: Bool = true) -> CodexInterfaceHealthSnapshot {
        guard roots.contains(where: { !$0.hidden }) else { return .init() }
        var snapshot = CodexInterfaceHealthSnapshot(status: .observing)
        var inviteValues: [Bool] = []
        func visit(_ node: Node) {
            guard !node.hidden else { return }
            if isControl(node.role), let label = node.label {
                let label = normalized(label)
                if [kAXMenuItemRole, kAXButtonRole, kAXMenuButtonRole].contains(node.role),
                   label == "邀请好友" || label == "invite a friend" || label == "invite friends"
                    || label.hasPrefix("邀请好友") || label.hasPrefix("invite a friend")
                    || label.hasPrefix("invite friends"),
                   let enabled = node.enabled {
                    inviteValues.append(enabled)
                }
                if isRetryStatusControl(node.role) {
                    if label.range(of: #"^(?:正在重新连接|正在重连|reconnecting)(?:(?:\.\.\.|…)?\s*(?:\d+\s*/\s*\d+)?)?$"#, options: .regularExpression) != nil {
                        snapshot.reconnecting = true
                    }
                    if label.range(of: #"^(?:(?:reconnecting|正在重新连接|正在重连)(?:\.\.\.|…)?\s*[,，·]?\s*)?(?:waiting for network|等待网络|正在等待网络)(?:\.\.\.|…)?$"#, options: .regularExpression) != nil {
                        snapshot.waitingForNetwork = true
                    }
                }
            }
            if isGroup(node.role), !node.children.isEmpty, node.children.count <= 8 {
                let children = node.children.filter { !$0.hidden }
                let candidates = children + children.flatMap { $0.children.count <= 8 ? $0.children : [] }
                if candidates.count <= 16,
                   candidates.contains(where: isRetry),
                   candidates.contains(where: { !$0.hidden && [kAXStaticTextRole, "AXHeading"].contains($0.role) && $0.label.map(isWorkspaceTitle) == true }) {
                    snapshot.workspaceUnavailable = true
                }
            }
            if ![kAXTextAreaRole, kAXTextFieldRole, "AXComboBox", "AXSecureTextField"].contains(node.role) {
                for child in node.children { visit(child) }
            }
        }
        for root in roots { visit(root) }
        if !inviteValues.isEmpty, Set(inviteValues).count == 1 { snapshot.inviteEnabled = inviteValues.first }
        if complete {
            snapshot.workspaceUnavailable = snapshot.workspaceUnavailable ?? false
            snapshot.reconnecting = snapshot.reconnecting ?? false
            snapshot.waitingForNetwork = snapshot.waitingForNetwork ?? false
        }
        return snapshot
    }

    private static func controlLabel(_ element: AXUIElement, attribute: (AXUIElement, CFString) -> CFTypeRef?) -> String? {
        let label = attribute(element, kAXTitleAttribute as CFString) as? String
            ?? attribute(element, kAXDescriptionAttribute as CFString) as? String
        guard let label, label.count <= 160 else { return nil }
        return label
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isControl(_ role: String) -> Bool {
        [kAXMenuItemRole, kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXDisclosureTriangleRole].contains(role)
    }

    private static func isRetryStatusControl(_ role: String) -> Bool {
        [kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXDisclosureTriangleRole].contains(role)
    }

    private static func isGroup(_ role: String) -> Bool { [kAXGroupRole, "AXStatus"].contains(role) }

    private static func isRetry(_ node: Node) -> Bool {
        !node.hidden && node.role == kAXButtonRole && node.label.map { ["重试", "retry", "try again"].contains(normalized($0)) } == true
    }

    private static func isWorkspaceTitle(_ label: String) -> Bool {
        ["无法加载工作空间设置", "无法加载工作区设置", "couldn’t load workspace settings", "couldn't load workspace settings", "could not load workspace settings"].contains(normalized(label))
    }
}
