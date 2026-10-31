import Foundation

@main
struct NodeGroupNameCheck {
    static func main() {
        var subscription = Subscription(name: "新的组名", originalURL: "https://example.com/sub")
        var node = ProxyNode(
            name: "US 美国_88",
            protocolType: .vless,
            server: "example.com",
            port: 443,
            subscriptionID: subscription.id,
            sourceName: "旧的组名"
        )
        assert(node.groupName(subscriptions: [subscription]) == "新的组名")
        subscription.name = "重命名后的组"
        assert(node.groupName(subscriptions: [subscription]) == "重命名后的组")
        assert(node.groupName(subscriptions: []) == "旧的组名")
        subscription.name = "  \n"
        assert(node.groupName(subscriptions: [subscription]) == "旧的组名")
        node.sourceName = " \n "
        assert(node.groupName(subscriptions: []) == "未知订阅")
        node.subscriptionID = nil
        assert(node.groupName(subscriptions: []) == "手动导入")
        node.sourceName = "本地分享组"
        assert(node.groupName(subscriptions: []) == "本地分享组")
        assert(node.name == "US 美国_88")
        print("Node group name checks passed (8 assertions)")
    }
}
