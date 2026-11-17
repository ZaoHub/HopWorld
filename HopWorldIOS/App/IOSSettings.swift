import Foundation

enum IOSTheme: String, CaseIterable, Identifiable {
    case blackGold
    case xianxia

    var id: String { rawValue }
    var title: String { self == .blackGold ? "黑金奢华" : "国风仙侠" }
    var description: String { self == .blackGold ? "深黑、鎏金与金属质感" : "水墨云海、玉石与青金符纹" }
    var assetName: String { self == .blackGold ? "HomeReference" : "HomeXianxia" }
}

/// Phone test targets. Same addresses Mac uses for web and apps; desktop-only probes stay out.
enum IOSSettings {
    static let themeKey = "ios.theme"
    static let showSubscriptionNoticesKey = "ios.showSubscriptionNotices"
    static let useAvailableOnlyKey = "ios.useAvailableOnly"
    static let useExitIPOnlyKey = "ios.useExitIPOnly"
    static let useCountryScopeKey = "ios.useCountryScope"
    static let useExcludedCountriesKey = "ios.useExcludedCountries"
    static let useIncludedCountriesKey = "ios.useIncludedCountries"
    static let autoSelectTimeoutKey = "ios.autoSelectTimeout"
    static let autoSelectTimeoutChoices = [5, 10, 15, 20, 30, 60]
    static let customTargetsKey = "ios.customTestTargets"
    static let selectedTargetsKey = "ios.selectedTestTargets"

    struct Target: Identifiable, Hashable, Codable {
        var title: String
        var url: String
        var kind: String
        var id: String { url }
    }

    static let builtInTargets: [Target] = [
        Target(title: "网页连通", url: "https://www.gstatic.com/generate_204", kind: "网页"),
        Target(title: "谷歌", url: "https://www.google.com/generate_204", kind: "网页"),
        Target(title: "谷歌视频", url: "https://www.googlevideo.com/generate_204", kind: "网页"),
        Target(title: "苹果", url: "https://www.apple.com/library/test/success.html", kind: "网页"),
        Target(title: "微软", url: "http://www.msftconnecttest.com/connecttest.txt", kind: "网页"),
        Target(title: "ChatGPT", url: "https://chatgpt.com/generate_204", kind: "网页"),
        Target(title: "TikTok", url: "https://www.tiktok.com/", kind: "网页"),
        Target(title: "Instagram", url: "https://www.instagram.com/", kind: "网页"),
        Target(title: "Telegram", url: "https://telegram.org/", kind: "网页"),
        Target(title: "WhatsApp", url: "https://web.whatsapp.com/", kind: "网页"),
        Target(title: "VK", url: "https://vk.com/", kind: "网页"),
        Target(title: "Discord", url: "https://discord.com/", kind: "网页"),
        Target(title: "Muse", url: "https://www.meta.ai/", kind: "网页"),
        Target(title: "X", url: "https://x.com/", kind: "网页"),
        Target(title: "V2EX", url: "https://www.v2ex.com/", kind: "网页"),
        Target(title: "Facebook", url: "https://www.facebook.com/", kind: "网页"),
        Target(title: "LinkedIn", url: "https://www.linkedin.com/", kind: "网页"),
        Target(title: "Tinder", url: "https://tinder.com/", kind: "网页"),
        Target(title: "Amazon", url: "https://www.amazon.com/", kind: "网页"),
    ] + builtInApps

    /// App 预设。地址与已安装名单相同，避免两处各写一份。
    private static let builtInAppNames = [
        "YouTube", "Telegram", "Instagram", "WhatsApp", "TikTok", "X", "Discord", "ChatGPT",
        "Claude", "GitHub", "Cloudflare"
    ]

    private static let builtInApps: [Target] = builtInAppNames.compactMap { name in
        if name == "Cloudflare" {
            return Target(title: "Cloudflare", url: "https://www.cloudflare.com/cdn-cgi/trace", kind: "App")
        }
        guard let app = installedAppCatalog.first(where: { $0.title == name }) else { return nil }
        return Target(title: app.title, url: app.url, kind: "App")
    }

    struct InstalledApp: Equatable {
        var title: String
        var scheme: String
        var url: String
    }

    // shortcut: iOS 只能查询 Info.plist 里声明的 URL Scheme，最多 50 个，读不到完整的已安装列表。要多认应用，就同时改这份名单和 LSApplicationQueriesSchemes。
    static let installedAppCatalog: [InstalledApp] = [
        InstalledApp(title: "YouTube", scheme: "youtube", url: "https://www.youtube.com/generate_204"),
        InstalledApp(title: "Telegram", scheme: "tg", url: "https://api.telegram.org/"),
        InstalledApp(title: "Instagram", scheme: "instagram", url: "https://i.instagram.com/"),
        InstalledApp(title: "WhatsApp", scheme: "whatsapp", url: "https://g.whatsapp.net/"),
        InstalledApp(title: "TikTok", scheme: "tiktok", url: "https://api16-normal-c-alisg.tiktokv.com/"),
        InstalledApp(title: "X", scheme: "twitter", url: "https://api.x.com/"),
        InstalledApp(title: "Discord", scheme: "discord", url: "https://discord.com/api/v10/gateway"),
        InstalledApp(title: "ChatGPT", scheme: "chatgpt", url: "https://ios.chat.openai.com/"),
        InstalledApp(title: "微信", scheme: "weixin", url: "https://short.weixin.qq.com/"),
        InstalledApp(title: "QQ", scheme: "mqq", url: "https://ssl.msfwifi.3g.qq.com/"),
        InstalledApp(title: "微博", scheme: "sinaweibo", url: "https://api.weibo.cn/"),
        InstalledApp(title: "哔哩哔哩", scheme: "bilibili", url: "https://app.bilibili.com/"),
        InstalledApp(title: "抖音", scheme: "snssdk1128", url: "https://aweme.snssdk.com/"),
        InstalledApp(title: "小红书", scheme: "xhsdiscover", url: "https://edith.xiaohongshu.com/"),
        InstalledApp(title: "淘宝", scheme: "taobao", url: "https://acs.m.taobao.com/"),
        InstalledApp(title: "支付宝", scheme: "alipay", url: "https://mobilegw.alipay.com/"),
        InstalledApp(title: "京东", scheme: "openapp.jdmobile", url: "https://api.m.jd.com/"),
        InstalledApp(title: "美团", scheme: "imeituan", url: "https://apimobile.meituan.com/"),
        InstalledApp(title: "网易云音乐", scheme: "orpheus", url: "https://interface.music.163.com/"),
        InstalledApp(title: "拼多多", scheme: "pinduoduo", url: "https://api.yangkeduo.com/"),
        InstalledApp(title: "知乎", scheme: "zhihu", url: "https://api.zhihu.com/"),
        InstalledApp(title: "高德地图", scheme: "iosamap", url: "https://www.amap.com/"),
        InstalledApp(title: "百度", scheme: "baiduboxapp", url: "https://mbd.baidu.com/"),
        InstalledApp(title: "钉钉", scheme: "dingtalk", url: "https://www.dingtalk.com/"),
        InstalledApp(title: "企业微信", scheme: "wxwork", url: "https://work.weixin.qq.com/"),
        InstalledApp(title: "快手", scheme: "kwai", url: "https://apissl.gifshow.com/"),
        InstalledApp(title: "饿了么", scheme: "eleme", url: "https://www.ele.me/"),
        InstalledApp(title: "Spotify", scheme: "spotify", url: "https://api.spotify.com/"),
        InstalledApp(title: "Netflix", scheme: "nflx", url: "https://www.netflix.com/"),
        InstalledApp(title: "Facebook", scheme: "fb", url: "https://www.facebook.com/"),
        InstalledApp(title: "LINE", scheme: "line", url: "https://line.me/"),
        InstalledApp(title: "Signal", scheme: "sgnl", url: "https://chat.signal.org/"),
        InstalledApp(title: "Reddit", scheme: "reddit", url: "https://oauth.reddit.com/"),
        InstalledApp(title: "Chrome", scheme: "googlechrome", url: "https://www.google.com/chrome/"),
        InstalledApp(title: "Slack", scheme: "slack", url: "https://slack.com/"),
        InstalledApp(title: "Zoom", scheme: "zoomus", url: "https://zoom.us/"),
        InstalledApp(title: "Teams", scheme: "msteams", url: "https://www.microsoft.com/microsoft-teams/"),
        InstalledApp(title: "Notion", scheme: "notion", url: "https://www.notion.so/"),
        InstalledApp(title: "Claude", scheme: "claude", url: "https://claude.ai/"),
        InstalledApp(title: "Gmail", scheme: "googlegmail", url: "https://mail.google.com/"),
        InstalledApp(title: "Firefox", scheme: "firefox", url: "https://www.mozilla.org/firefox/"),
        InstalledApp(title: "Snapchat", scheme: "snapchat", url: "https://www.snapchat.com/"),
        InstalledApp(title: "LinkedIn", scheme: "linkedin", url: "https://www.linkedin.com/"),
        InstalledApp(title: "Pinterest", scheme: "pinterest", url: "https://www.pinterest.com/"),
        InstalledApp(title: "Twitch", scheme: "twitch", url: "https://www.twitch.tv/"),
        InstalledApp(title: "Steam", scheme: "steam", url: "https://store.steampowered.com/"),
        InstalledApp(title: "CapCut", scheme: "capcut", url: "https://www.capcut.com/"),
        InstalledApp(title: "Duolingo", scheme: "duolingo", url: "https://www.duolingo.com/"),
        InstalledApp(title: "PayPal", scheme: "paypal", url: "https://www.paypal.com/"),
        InstalledApp(title: "GitHub", scheme: "github", url: "https://api.github.com/")
    ]

    /// Asset name for the platform's official logo. Nil for a custom address.
    static func logoAsset(for url: String) -> String? {
        if let asset = webLogoAssets[url] { return asset }
        if let scheme = installedAppCatalog.first(where: { $0.url == url })?.scheme {
            return "Logo" + scheme.replacingOccurrences(of: ".", with: "")
        }
        return nil
    }

    /// Mac preset pages that are not the same address as an installed-app probe.
    private static let webLogoAssets: [String: String] = [
        "https://www.google.com/generate_204": "LogoGoogle",
        "https://www.googlevideo.com/generate_204": "LogoGoogle",
        "https://www.apple.com/library/test/success.html": "LogoApple",
        "http://www.msftconnecttest.com/connecttest.txt": "LogoMicrosoft",
        "https://chatgpt.com/generate_204": "Logochatgpt",
        "https://www.tiktok.com/": "Logotiktok",
        "https://www.instagram.com/": "Logoinstagram",
        "https://telegram.org/": "Logotg",
        "https://web.whatsapp.com/": "Logowhatsapp",
        "https://vk.com/": "LogoVK",
        "https://discord.com/": "Logodiscord",
        "https://www.meta.ai/": "LogoMuse",
        "https://x.com/": "Logotwitter",
        "https://www.v2ex.com/": "LogoV2EX",
        "https://tinder.com/": "LogoTinder",
        "https://www.amazon.com/": "LogoAmazon",
        "https://www.cloudflare.com/cdn-cgi/trace": "LogoCloudflare"
    ]

    static func showsLogo(for url: String) -> Bool {
        logoAsset(for: url) != nil || url == "https://www.gstatic.com/generate_204"
    }

    struct ProbeRequest: Equatable {
        var url: String
        var anyHTTPStatus: Bool
    }

    struct ProbeGroup: Equatable {
        var requests: [ProbeRequest]
        var matchAny: Bool
    }

    /// 旧的官网地址。已选目标会改到 App 服务器；本身已是预设网页的地址保持不变。
    static let retiredProbeURLs: [String: String] = [
        "https://telegram.org/": "https://api.telegram.org/",
        "https://www.instagram.com/": "https://i.instagram.com/",
        "https://web.whatsapp.com/": "https://g.whatsapp.net/",
        "https://www.tiktok.com/": "https://api16-normal-c-alisg.tiktokv.com/",
        "https://x.com/": "https://api.x.com/",
        "https://discord.com/": "https://discord.com/api/v10/gateway",
        "https://chatgpt.com/generate_204": "https://ios.chat.openai.com/",
        "https://weixin.qq.com/": "https://short.weixin.qq.com/",
        "https://im.qq.com/": "https://ssl.msfwifi.3g.qq.com/",
        "https://weibo.com/": "https://api.weibo.cn/",
        "https://www.bilibili.com/": "https://app.bilibili.com/",
        "https://www.douyin.com/": "https://aweme.snssdk.com/",
        "https://www.xiaohongshu.com/": "https://edith.xiaohongshu.com/",
        "https://www.taobao.com/": "https://acs.m.taobao.com/",
        "https://www.alipay.com/": "https://mobilegw.alipay.com/",
        "https://www.jd.com/": "https://api.m.jd.com/",
        "https://www.meituan.com/": "https://apimobile.meituan.com/",
        "https://music.163.com/": "https://interface.music.163.com/",
        "https://www.pinduoduo.com/": "https://api.yangkeduo.com/",
        "https://www.zhihu.com/": "https://api.zhihu.com/",
        "https://www.baidu.com/": "https://mbd.baidu.com/",
        "https://www.kuaishou.com/": "https://apissl.gifshow.com/",
        "https://www.spotify.com/": "https://api.spotify.com/",
        "https://signal.org/": "https://chat.signal.org/",
        "https://www.reddit.com/": "https://oauth.reddit.com/",
        "https://github.com/": "https://api.github.com/"
    ]

    // shortcut: 没有单独服务器地址的 App 仍测官网，这不能代表 App 一定能用。确认到 App 服务器后再加进 appServerURLs。
    private static let appServerURLs: Set<String> = [
        "https://api.telegram.org/",
        "https://i.instagram.com/",
        "https://g.whatsapp.net/",
        "https://api.x.com/",
        "https://discord.com/api/v10/gateway",
        "https://ios.chat.openai.com/",
        "https://short.weixin.qq.com/",
        "https://ssl.msfwifi.3g.qq.com/",
        "https://api.weibo.cn/",
        "https://app.bilibili.com/",
        "https://edith.xiaohongshu.com/",
        "https://acs.m.taobao.com/",
        "https://mobilegw.alipay.com/",
        "https://api.m.jd.com/",
        "https://apimobile.meituan.com/",
        "https://interface.music.163.com/",
        "https://api.yangkeduo.com/",
        "https://api.zhihu.com/",
        "https://mbd.baidu.com/",
        "https://apissl.gifshow.com/",
        "https://api.spotify.com/",
        "https://chat.signal.org/",
        "https://oauth.reddit.com/",
        "https://api.github.com/"
    ]

    private static let specialProbeGroups: [String: ProbeGroup] = [
        "https://www.youtube.com/generate_204": ProbeGroup(requests: [
            ProbeRequest(url: "https://www.youtube.com/generate_204", anyHTTPStatus: false),
            ProbeRequest(url: "https://redirector.googlevideo.com/", anyHTTPStatus: true)
        ], matchAny: false),
        "https://chatgpt.com/generate_204": ProbeGroup(requests: [
            ProbeRequest(url: "https://chatgpt.com/generate_204", anyHTTPStatus: true)
        ], matchAny: false),
        "https://www.cloudflare.com/cdn-cgi/trace": ProbeGroup(requests: [
            "https://www.cloudflare.com/cdn-cgi/trace",
            "https://1.1.1.1/cdn-cgi/trace"
        ].map { ProbeRequest(url: $0, anyHTTPStatus: false) }, matchAny: true),
        "https://claude.ai/": ProbeGroup(requests: [
            "https://claude.ai/cdn-cgi/trace",
            "https://claude.ai/"
        ].map { ProbeRequest(url: $0, anyHTTPStatus: true) }, matchAny: true),
        "https://api16-normal-c-alisg.tiktokv.com/": ProbeGroup(requests: [
            "https://api16-normal-c-alisg.tiktokv.com/",
            "https://api16-normal-c-useast1a.tiktokv.com/",
            "https://api16-normal-c-useast2a.tiktokv.com/"
        ].map { ProbeRequest(url: $0, anyHTTPStatus: true) }, matchAny: true),
        "https://aweme.snssdk.com/": ProbeGroup(requests: [
            "https://aweme.snssdk.com/",
            "https://api.amemv.com/"
        ].map { ProbeRequest(url: $0, anyHTTPStatus: true) }, matchAny: true)
    ]

    static func probeGroup(for url: String) -> ProbeGroup {
        if let group = specialProbeGroups[url] { return group }
        if appServerURLs.contains(url) {
            return ProbeGroup(requests: [ProbeRequest(url: url, anyHTTPStatus: true)], matchAny: false)
        }
        return ProbeGroup(requests: [ProbeRequest(url: url, anyHTTPStatus: false)], matchAny: false)
    }

    static func probesAppServer(_ url: String) -> Bool {
        appServerURLs.contains(url) || [
            "https://www.youtube.com/generate_204",
            "https://api16-normal-c-alisg.tiktokv.com/",
            "https://aweme.snssdk.com/"
        ].contains(url)
    }

    static func migrateCustomTargets(_ items: [Target]) -> [Target] {
        var seen = Set(builtInTargets.map(\.url))
        var result: [Target] = []
        for item in items {
            let url = retiredProbeURLs[item.url] ?? item.url
            guard seen.insert(url).inserted else { continue }
            result.append(url == item.url ? item : Target(title: item.title, url: url, kind: item.kind))
        }
        return result
    }

    static func installedApps(opening: (String) -> Bool) -> [InstalledApp] {
        installedAppCatalog.filter { opening($0.scheme) }
    }

    /// 预设里已有同一网址时只勾选，不另加一条。
    static func adoptInstalledApp(_ app: InstalledApp, custom: [Target], selected: [String]) -> (custom: [Target], selected: [String]) {
        var custom = custom
        let exists = builtInTargets.contains { $0.url == app.url } || custom.contains { $0.url == app.url }
        if !exists, let target = customTarget(title: app.title, url: app.url, kind: "App") {
            custom.append(target)
        }
        var selected = selected
        let known = builtInTargets.contains { $0.url == app.url } || custom.contains { $0.url == app.url }
        if known && !selected.contains(app.url) { selected.append(app.url) }
        return (custom, selected)
    }

    static var customTargets: [Target] {
        get {
            guard let text = UserDefaults.standard.string(forKey: customTargetsKey),
                  let data = text.data(using: .utf8),
                  let items = try? JSONDecoder().decode([Target].self, from: data) else { return [] }
            let migrated = migrateCustomTargets(items)
            if migrated != items,
               let data = try? JSONEncoder().encode(migrated),
               let updated = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(updated, forKey: customTargetsKey)
            }
            return migrated
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue), let text = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(text, forKey: customTargetsKey)
        }
    }

    static var targets: [Target] { builtInTargets + customTargets }

    static func customTarget(title: String, url: String, kind: String) -> Target? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, ["网页", "App"].contains(kind),
              let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.url != nil,
              components.user == nil, components.password == nil else { return nil }
        return Target(title: title, url: url, kind: kind)
    }

    static let timeoutRange = 1...30

    static func selectedTestURLs(from text: String) -> [String] {
        if let data = text.data(using: .utf8),
           let selected = try? JSONDecoder().decode([String].self, from: data) {
            let allowed = Set(targets.map(\.url))
            var seen = Set<String>()
            return selected.map { url in
                builtInTargets.contains(where: { $0.url == url }) ? url : (retiredProbeURLs[url] ?? url)
            }.filter { allowed.contains($0) && seen.insert($0).inserted }
        }
        let legacy = UserDefaults.standard.string(forKey: "ios.testURL")
        return [legacy.flatMap { url in targets.contains(where: { $0.url == url }) ? url : nil } ?? builtInTargets[0].url]
    }

    static func encodedTestURLs(_ urls: [String]) -> String {
        let allowed = Set(targets.map(\.url))
        var seen: Set<String> = []
        let selected = urls.filter { allowed.contains($0) && seen.insert($0).inserted }
        guard let data = try? JSONEncoder().encode(selected), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static var selectedTestURLs: [String] {
        get { selectedTestURLs(from: UserDefaults.standard.string(forKey: selectedTargetsKey) ?? "") }
        set { UserDefaults.standard.set(encodedTestURLs(newValue), forKey: selectedTargetsKey) }
    }

    static var timeoutSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "ios.testTimeout")
            return timeoutRange.contains(stored) ? stored : 8
        }
        set { UserDefaults.standard.set(min(30, max(1, newValue)), forKey: "ios.testTimeout") }
    }

    static var batchTimeoutSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "ios.batchTestTimeout")
            return timeoutRange.contains(stored) ? stored : 2
        }
        set { UserDefaults.standard.set(min(30, max(1, newValue)), forKey: "ios.batchTestTimeout") }
    }

    static func title(for url: String) -> String {
        targets.first { $0.url == url }?.title ?? "网页连通"
    }

    static var useAvailableOnly: Bool {
        get { defaultOn(useAvailableOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: useAvailableOnlyKey) }
    }

    static var useExitIPOnly: Bool {
        get { defaultOn(useExitIPOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: useExitIPOnlyKey) }
    }

    static var autoSelectTimeoutSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: autoSelectTimeoutKey)
            return autoSelectTimeoutChoices.contains(stored) ? stored : 15
        }
        set { UserDefaults.standard.set(autoSelectTimeoutChoices.contains(newValue) ? newValue : 15, forKey: autoSelectTimeoutKey) }
    }

    static var useCountryScope: IOSUseCountryScope {
        get { IOSUseCountryScope(rawValue: UserDefaults.standard.string(forKey: useCountryScopeKey) ?? "") ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: useCountryScopeKey) }
    }

    static var useExcludedCountries: Set<String> {
        get { countryCodes(forKey: useExcludedCountriesKey) }
        set { setCountryCodes(newValue, forKey: useExcludedCountriesKey) }
    }

    static var useIncludedCountries: Set<String> {
        get { countryCodes(forKey: useIncludedCountriesKey) }
        set { setCountryCodes(newValue, forKey: useIncludedCountriesKey) }
    }

    static func measuredCountryCode(_ node: ProxyNode) -> String? {
        guard let raw = node.exitMetadata?.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let code = raw.uppercased()
        guard code.count == 2, code != "XX" else { return nil }
        return code
    }

    static func allowsUse(_ node: ProxyNode) -> Bool {
        blockMessage(node) == nil
    }

    /// 首页连接用：已选中且符合条件的节点优先，否则取延迟排序后的第一个。
    static func connectChoice(selected: ProxyNode?, in nodes: [ProxyNode]) -> ProxyNode? {
        let allowed = IOSNodeSort.byLatency(nodes).filter(allowsUse)
        if let selected, allowed.contains(where: { $0.id == selected.id }) { return selected }
        return allowed.first
    }

    /// 当前节点没有出口时，按延迟排序取它后面第一个仍符合条件的节点，到末尾再从头找。
    static func nextConnectChoice(after nodeID: UUID, in nodes: [ProxyNode]) -> ProxyNode? {
        let sorted = IOSNodeSort.byLatency(nodes)
        let start = (sorted.firstIndex { $0.id == nodeID } ?? -1) + 1
        let rotated = Array(sorted.dropFirst(start)) + Array(sorted.prefix(max(0, start)))
        return rotated.first(where: allowsUse)
    }

    static func blockMessage(_ node: ProxyNode) -> String? {
        if useAvailableOnly && !node.resolvedTestStatus.isUsable {
            return "这个节点还不可用，不能选择。"
        }
        let ip = node.exitMetadata?.ip.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if useExitIPOnly && ip.isEmpty {
            return "这个节点还没有出口 IP，不能选择。"
        }
        guard outsideCountryScope(node) else { return nil }
        if measuredCountryCode(node) == nil {
            return "这个节点还没有测到出口国家，不能选择。"
        }
        if useCountryScope == .excluded {
            return "这个节点的出口国家已被排除，不能选择。"
        }
        return "这个节点不在指定国家里，不能选择。"
    }

    static func outsideCountryScope(_ node: ProxyNode) -> Bool {
        switch useCountryScope {
        case .all:
            return false
        case .excluded, .included:
            guard let code = measuredCountryCode(node) else { return true }
            if useCountryScope == .excluded { return useExcludedCountries.contains(code) }
            return !useIncludedCountries.contains(code)
        }
    }

    private static func defaultOn(_ key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func countryCodes(forKey key: String) -> Set<String> {
        guard let text = UserDefaults.standard.string(forKey: key),
              let data = text.data(using: .utf8),
              let codes = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(codes.map { $0.uppercased() })
    }

    private static func setCountryCodes(_ codes: Set<String>, forKey key: String) {
        let values = codes.map { $0.uppercased() }.sorted()
        guard let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(text, forKey: key)
    }
}

enum IOSUseCountryScope: String, CaseIterable, Identifiable {
    case all
    case excluded
    case included

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部国家"
        case .excluded: return "排除国家"
        case .included: return "指定国家"
        }
    }
}

enum IOSNodeSort {
    static func byLatency(_ nodes: [ProxyNode]) -> [ProxyNode] {
        nodes.sorted { lhs, rhs in
            let left = bucket(lhs), right = bucket(rhs)
            if left != right { return left < right }
            let leftLatency = lhs.lastLatency ?? Int.max
            let rightLatency = rhs.lastLatency ?? Int.max
            if leftLatency != rightLatency { return leftLatency < rightLatency }
            let order = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func bucket(_ node: ProxyNode) -> Int {
        switch node.resolvedTestStatus {
        case .ultraFast, .fast, .fairlyFast, .fairlySlow, .slow, .ultraSlow: return 0
        case .testing: return 1
        case .untested: return 2
        case .failed: return 3
        case .unavailable: return node.lastLatency == nil ? 5 : 4
        }
    }
}

struct IOSNodeTally: Equatable {
    var total = 0
    var available = 0
    var unavailable = 0
    var failed = 0
    var untested = 0

    static func make(_ nodes: [ProxyNode]) -> IOSNodeTally {
        var tally = IOSNodeTally(total: nodes.count)
        for node in nodes {
            switch node.resolvedTestStatus {
            case .unavailable: tally.unavailable += 1
            case .failed: tally.failed += 1
            case .untested: tally.untested += 1
            default:
                if node.resolvedTestStatus.isUsable { tally.available += 1 }
            }
        }
        return tally
    }

    var line: String { "总 \(total) · 可用 \(available) · 不可用 \(unavailable) · 失败 \(failed) · 未测试 \(untested)" }
}

enum IOSNodeScope: String, CaseIterable, Identifiable {
    case all
    case available
    case unavailable
    case failed
    case untested

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .available: return "可用"
        case .unavailable: return "不可用"
        case .failed: return "失败"
        case .untested: return "未测试"
        }
    }

    func matches(_ node: ProxyNode) -> Bool {
        switch self {
        case .all: return true
        case .available: return node.resolvedTestStatus.isUsable
        case .unavailable: return node.resolvedTestStatus == .unavailable
        case .failed: return node.resolvedTestStatus == .failed
        case .untested: return node.resolvedTestStatus == .untested
        }
    }
}

enum IOSNodeIdentity {
    static func key(_ node: ProxyNode) -> String {
        [
            node.protocolType.rawValue,
            node.server.lowercased(),
            String(node.port),
            node.uuid ?? "",
            node.password ?? "",
            node.transport.rawValue
        ].joined(separator: "\n")
    }

    /// Keep the previous id and test result when the refreshed link is the same node.
    static func keepingResults(existing: [ProxyNode], proposed: [ProxyNode], subscriptionID: UUID, sourceName: String) -> [ProxyNode] {
        var pool: [String: [ProxyNode]] = [:]
        for node in existing {
            pool[key(node), default: []].append(node)
        }
        return proposed.map { node in
            var copy = node
            copy.subscriptionID = subscriptionID
            copy.sourceName = sourceName
            CountryResolver.applyNameHeuristics(to: &copy)
            guard var matches = pool[key(copy)], !matches.isEmpty else { return copy }
            var kept = matches.removeFirst()
            pool[key(copy)] = matches
            kept.name = copy.name
            kept.protocolType = copy.protocolType
            kept.server = copy.server
            kept.port = copy.port
            kept.uuid = copy.uuid
            kept.password = copy.password
            kept.username = copy.username
            kept.method = copy.method
            kept.alterId = copy.alterId
            kept.flow = copy.flow
            kept.encryption = copy.encryption
            kept.transport = copy.transport
            kept.security = copy.security
            kept.sni = copy.sni
            kept.host = copy.host
            kept.path = copy.path
            kept.serviceName = copy.serviceName
            kept.publicKey = copy.publicKey
            kept.shortID = copy.shortID
            kept.fingerprint = copy.fingerprint
            kept.spiderX = copy.spiderX
            kept.alpn = copy.alpn
            kept.allowInsecure = copy.allowInsecure
            kept.countryCode = copy.countryCode
            kept.countryName = copy.countryName
            kept.subscriptionID = subscriptionID
            kept.sourceName = sourceName
            CountryResolver.applyNameHeuristics(to: &kept)
            return kept
        }
    }
}
