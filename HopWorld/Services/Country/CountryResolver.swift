import Foundation

enum FlagResolver {
    static func flag(for countryCode: String?) -> String {
        guard let code = countryCode?.uppercased(), code.count == 2, code != "XX" else {
            return "🌐"
        }
        let scalars = code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }
}

enum CountryResolver {
    /// Common subscription naming keywords → ISO code + zh display name.
    private static let keywordMap: [(keywords: [String], code: String, name: String)] = [
        (["香港", "HK", "HONG KONG", "HONGKONG"], "HK", "香港"),
        (["台湾", "TW", "TAIWAN", "TAIPEI"], "TW", "台湾"),
        (["澳门", "MO", "MACAO", "MACAU"], "MO", "澳门"),
        (["中国", "CN", "CHINA", "北京", "上海", "深圳", "广州"], "CN", "中国"),
        (["日本", "JP", "JAPAN", "TOKYO", "OSAKA", "东京", "大阪"], "JP", "日本"),
        (["韩国", "KR", "KOREA", "SEOUL", "首尔"], "KR", "韩国"),
        (["新加坡", "SG", "SINGAPORE", "狮城"], "SG", "新加坡"),
        (["美国", "US", "USA", "UNITED STATES", "LOS ANGELES", "NEW YORK", "SEATTLE", "硅谷", "洛杉矶", "纽约"], "US", "美国"),
        (["英国", "GB", "UK", "UNITED KINGDOM", "LONDON", "伦敦"], "GB", "英国"),
        (["德国", "DE", "GERMANY", "FRANKFURT", "柏林", "法兰克福"], "DE", "德国"),
        (["法国", "FR", "FRANCE", "PARIS", "巴黎"], "FR", "法国"),
        (["加拿大", "CA", "CANADA", "TORONTO", "VANCOUVER"], "CA", "加拿大"),
        (["澳大利亚", "AU", "AUSTRALIA", "SYDNEY", "墨尔本"], "AU", "澳大利亚"),
        (["俄罗斯", "RU", "RUSSIA", "MOSCOW", "莫斯科"], "RU", "俄罗斯"),
        (["印度", "IN", "INDIA", "MUMBAI"], "IN", "印度"),
        (["土耳其", "TR", "TURKEY", "ISTANBUL", "伊斯坦布尔"], "TR", "土耳其"),
        (["荷兰", "NL", "NETHERLANDS", "AMSTERDAM", "阿姆斯特丹"], "NL", "荷兰"),
        (["西班牙", "ES", "SPAIN", "MADRID", "马德里"], "ES", "西班牙"),
        (["波兰", "PL", "POLAND", "WARSAW", "华沙"], "PL", "波兰"),
        (["亚美尼亚", "AM", "ARMENIA", "YEREVAN"], "AM", "亚美尼亚"),
        (["摩尔多瓦", "MD", "MOLDOVA", "CHISINAU"], "MD", "摩尔多瓦"),
        (["意大利", "IT", "ITALY", "MILAN", "ROME", "米兰", "罗马"], "IT", "意大利"),
        (["瑞士", "CH", "SWITZERLAND", "ZURICH", "苏黎世"], "CH", "瑞士"),
        (["瑞典", "SE", "SWEDEN", "STOCKHOLM"], "SE", "瑞典"),
        (["挪威", "NO", "NORWAY", "OSLO"], "NO", "挪威"),
        (["芬兰", "FI", "FINLAND", "HELSINKI"], "FI", "芬兰"),
        (["丹麦", "DK", "DENMARK", "COPENHAGEN"], "DK", "丹麦"),
        (["比利时", "BE", "BELGIUM", "BRUSSELS"], "BE", "比利时"),
        (["奥地利", "AT", "AUSTRIA", "VIENNA", "维也纳"], "AT", "奥地利"),
        (["爱尔兰", "IE", "IRELAND", "DUBLIN"], "IE", "爱尔兰"),
        (["葡萄牙", "PT", "PORTUGAL", "LISBON"], "PT", "葡萄牙"),
        (["希腊", "GR", "GREECE", "ATHENS"], "GR", "希腊"),
        (["捷克", "CZ", "CZECH"], "CZ", "捷克"),
        (["匈牙利", "HU", "HUNGARY", "BUDAPEST"], "HU", "匈牙利"),
        (["罗马尼亚", "RO", "ROMANIA", "BUCHAREST"], "RO", "罗马尼亚"),
        (["乌克兰", "UA", "UKRAINE", "KYIV", "KIEV"], "UA", "乌克兰"),
        (["以色列", "IL", "ISRAEL", "TEL AVIV"], "IL", "以色列"),
        (["南非", "ZA", "SOUTH AFRICA"], "ZA", "南非"),
        (["墨西哥", "MX", "MEXICO"], "MX", "墨西哥"),
        (["智利", "CL", "CHILE", "SANTIAGO"], "CL", "智利"),
        (["阿根廷", "AR", "ARGENTINA"], "AR", "阿根廷"),
        (["巴西", "BR", "BRAZIL"], "BR", "巴西"),
        (["菲律宾", "PH", "PHILIPPINES", "MANILA"], "PH", "菲律宾"),
        (["越南", "VN", "VIETNAM", "HANOI"], "VN", "越南"),
        (["泰国", "TH", "THAILAND", "BANGKOK", "曼谷"], "TH", "泰国"),
        (["马来西亚", "MY", "MALAYSIA", "KUALA"], "MY", "马来西亚"),
        (["印度尼西亚", "ID", "INDONESIA", "JAKARTA", "印尼"], "ID", "印尼"),
        (["迪拜", "AE", "UAE", "DUBAI", "阿联酋"], "AE", "阿联酋"),
        (["巴基斯坦", "PK", "PAKISTAN"], "PK", "巴基斯坦"),
        (["孟加拉", "BD", "BANGLADESH"], "BD", "孟加拉"),
        (["尼日利亚", "NG", "NIGERIA"], "NG", "尼日利亚"),
        (["埃及", "EG", "EGYPT"], "EG", "埃及"),
        (["新西兰", "NZ", "NEW ZEALAND"], "NZ", "新西兰"),
        (["冰岛", "IS", "ICELAND"], "IS", "冰岛"),
        (["卢森堡", "LU", "LUXEMBOURG"], "LU", "卢森堡"),
        (["保加利亚", "BG", "BULGARIA"], "BG", "保加利亚"),
        (["塞尔维亚", "RS", "SERBIA"], "RS", "塞尔维亚"),
        (["克罗地亚", "HR", "CROATIA"], "HR", "克罗地亚"),
        (["斯洛伐克", "SK", "SLOVAKIA"], "SK", "斯洛伐克"),
        (["斯洛文尼亚", "SI", "SLOVENIA"], "SI", "斯洛文尼亚"),
        (["立陶宛", "LT", "LITHUANIA"], "LT", "立陶宛"),
        (["拉脱维亚", "LV", "LATVIA"], "LV", "拉脱维亚"),
        (["爱沙尼亚", "EE", "ESTONIA"], "EE", "爱沙尼亚"),
        (["白俄罗斯", "BY", "BELARUS"], "BY", "白俄罗斯"),
        (["哈萨克", "KZ", "KAZAKHSTAN"], "KZ", "哈萨克斯坦"),
        (["乌兹别克", "UZ", "UZBEKISTAN"], "UZ", "乌兹别克斯坦"),
        (["格鲁吉亚", "GE", "GEORGIA", "TBILISI"], "GE", "格鲁吉亚"),
        (["阿塞拜疆", "AZ", "AZERBAIJAN"], "AZ", "阿塞拜疆"),
        (["伊拉克", "IQ", "IRAQ"], "IQ", "伊拉克"),
        (["伊朗", "IR", "IRAN"], "IR", "伊朗"),
        (["沙特", "SA", "SAUDI"], "SA", "沙特"),
        (["卡塔尔", "QA", "QATAR"], "QA", "卡塔尔"),
        (["科威特", "KW", "KUWAIT"], "KW", "科威特"),
        (["柬埔寨", "KH", "CAMBODIA"], "KH", "柬埔寨"),
        (["缅甸", "MM", "MYANMAR", "BURMA"], "MM", "缅甸"),
        (["斯里兰卡", "LK", "SRI LANKA"], "LK", "斯里兰卡"),
        (["尼泊尔", "NP", "NEPAL"], "NP", "尼泊尔"),
        (["蒙古", "MN", "MONGOLIA"], "MN", "蒙古"),
        (["哥伦比亚", "CO", "COLOMBIA"], "CO", "哥伦比亚"),
        (["秘鲁", "PE", "PERU"], "PE", "秘鲁"),
        (["厄瓜多尔", "EC", "ECUADOR"], "EC", "厄瓜多尔"),
        (["乌拉圭", "UY", "URUGUAY"], "UY", "乌拉圭"),
        (["巴拿马", "PA", "PANAMA"], "PA", "巴拿马"),
        (["哥斯达黎加", "CR", "COSTA RICA"], "CR", "哥斯达黎加")
    ]

    private static let keywordMapBySpecificity = keywordMap.sorted {
        ($0.keywords.map(\.count).max() ?? 0) > ($1.keywords.map(\.count).max() ?? 0)
    }

    private static let knownISOCodes: Set<String> = Set(Locale.Region.isoRegions.map(\.identifier))

    /// Preferred zh display names; fall back to system localization.
    private static let zhNames: [String: String] = Dictionary(
        uniqueKeysWithValues: keywordMap.map { ($0.code, $0.name) }
    )

    static func displayName(for code: String) -> String {
        let upper = code.uppercased()
        if upper == "XX" { return "其他" }
        if let zh = zhNames[upper] { return zh }
        if let localized = Locale(identifier: "zh_CN").localizedString(forRegionCode: upper) {
            return localized
        }
        return Locale.current.localizedString(forRegionCode: upper) ?? upper
    }

    /// Resolve country from a node remark/name.
    static func resolve(fromName name: String) -> (code: String, name: String)? {
        if let fromFlag = extractFromRegionalIndicators(name) {
            return (fromFlag, displayName(for: fromFlag))
        }
        if let fromPattern = extractISOCode(from: name) {
            return (fromPattern, displayName(for: fromPattern))
        }

        let upper = name.uppercased()
        // Prefer longer phrases; skip bare Latin ISO digraphs here (handled by extractISOCode)
        // so "PARIS" doesn't match "IS", "CHINA" doesn't match "CH". Keep 中国 / 日本 etc.
        for entry in keywordMapBySpecificity {
            for keyword in entry.keywords {
                let isBareISO = keyword.count == 2 && keyword.allSatisfy { $0.isLetter && $0.isASCII }
                if isBareISO { continue }
                if upper.contains(keyword.uppercased()) {
                    return (entry.code, entry.name)
                }
            }
        }
        return nil
    }

    /// Stored code if present; otherwise infer from name. Never invents a fake ISO code.
    static func effectiveCountry(for node: ProxyNode) -> (code: String, name: String) {
        if let code = node.countryCode?.uppercased(), !code.isEmpty, code != "XX" {
            return (code, node.countryName ?? displayName(for: code))
        }
        if let resolved = resolve(fromName: node.name) {
            return resolved
        }
        return ("XX", "其他")
    }

    static func effectiveCode(for node: ProxyNode) -> String {
        effectiveCountry(for: node).code
    }

    static func applyNameHeuristics(to node: inout ProxyNode) {
        guard node.countryCode == nil || node.countryName == nil else { return }
        if let resolved = resolve(fromName: node.name) {
            if node.countryCode == nil { node.countryCode = resolved.code }
            if node.countryName == nil { node.countryName = resolved.name }
        }
    }

    static func applyExitIP(
        to node: inout ProxyNode,
        countryCode: String?,
        countryName: String?
    ) {
        if let countryCode {
            node.countryCode = countryCode.uppercased()
        }
        if let countryName {
            node.countryName = countryName
        }
    }

    static func group(_ nodes: [ProxyNode]) -> [CountryGroup] {
        var buckets: [String: CountryGroup] = [:]

        for node in nodes where !node.pendingRemoval {
            let resolved = effectiveCountry(for: node)
            let code = resolved.code
            let name = resolved.name
            let flag = FlagResolver.flag(for: code == "XX" ? nil : code)
            var group = buckets[code] ?? CountryGroup(code: code, name: name, flag: flag, nodes: [])
            group.nodes.append(node)
            buckets[code] = group
        }

        return buckets.values.sorted { lhs, rhs in
            if lhs.code == "XX" { return false }
            if rhs.code == "XX" { return true }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Name parsing helpers

    /// `_CN_`, `[CN]`, `(CN)`, `/CN/`, `|CN|`, `CN-`, `-CN-`
    private static func extractISOCode(from name: String) -> String? {
        let patterns = [
            #"[_\ entr(\p{Lu}{2})[_\]]"#,
            #"\((\p{Lu}{2})\)"#,
            #"/(\p{Lu}{2})/"#,
            #"\|(\p{Lu}{2})\|"#,
            #"(?:^|[\s\-|/])(\p{Lu}{2})(?:[\s\-|/]|$)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(name.startIndex..., in: name)
            let matches = regex.matches(in: name, range: range)
            for match in matches where match.numberOfRanges >= 2 {
                guard let codeRange = Range(match.range(at: 1), in: name) else { continue }
                let code = String(name[codeRange]).uppercased()
                if isValidISOCode(code) { return code }
            }
        }
        return nil
    }

    /// Leading/embedded 🇨🇳-style regional-indicator pairs in the remark.
    private static func extractFromRegionalIndicators(_ name: String) -> String? {
        let scalars = Array(name.unicodeScalars)
        var i = 0
        while i + 1 < scalars.count {
            let a = scalars[i].value
            let b = scalars[i + 1].value
            // Regional Indicator Symbol Letter A…Z = U+1F1E6…U+1F1FF
            if (0x1F1E6...0x1F1FF).contains(a), (0x1F1E6...0x1F1FF).contains(b) {
                let c1 = Character(UnicodeScalar(UInt32(65 + (a - 0x1F1E6)))!)
                let c2 = Character(UnicodeScalar(UInt32(65 + (b - 0x1F1E6)))!)
                let code = String([c1, c2])
                if isValidISOCode(code) { return code }
            }
            i += 1
        }
        return nil
    }

    private static func isValidISOCode(_ code: String) -> Bool {
        guard code.count == 2, code.allSatisfy(\.isLetter) else { return false }
        // Prefer Apple's ISO list; keep common proxy codes that may lag the OS list.
        if knownISOCodes.contains(code) { return true }
        return ["HK", "MO", "TW", "CN", "XK"].contains(code)
    }
}
