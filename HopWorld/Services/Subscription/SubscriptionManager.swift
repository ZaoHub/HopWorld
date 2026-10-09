import Foundation

struct SubscriptionTestReport: Sendable {
    var resolvedURL: String
    var httpStatus: Int?
    var downloadBytes: Int
    var formatName: String
    var totalParsed: Int
    var validCount: Int
    var duplicateCount: Int
    var invalidCount: Int
    var durationMS: Int
    var errorMessage: String?
}

@MainActor
final class SubscriptionManager: ObservableObject {
    @Published var updateState: SubscriptionUpdateState = .idle
    @Published var lastTestReport: SubscriptionTestReport?

    private let fetcher = SubscriptionFetcher()
    private let logger = AppLogger.shared

    func detectDateTemplate(for urlString: String) -> DateTemplateDetection {
        SubscriptionDateTemplateDetector.detect(from: urlString)
    }

    func candidateDates(
        offset: Int,
        fallbackDays: Int,
        timeZoneID: String
    ) -> [Date] {
        let timeZone = TimeZone(identifier: timeZoneID) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let base = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: offset, to: base) ?? base

        var dates: [Date] = []
        for day in 0...max(0, fallbackDays) {
            if let date = calendar.date(byAdding: .day, value: -day, to: start) {
                dates.append(date)
            }
        }
        return dates
    }

    func resolveURL(for subscription: Subscription, date: Date) -> String {
        let timeZone = TimeZone(identifier: subscription.urlDateTimeZoneID) ?? TimeZone(identifier: "Asia/Shanghai")!
        if subscription.urlMode == .dateTemplate, let template = subscription.urlTemplate {
            return SubscriptionDateTemplate(template: template).resolve(date: date, timeZone: timeZone)
        }
        return subscription.resolvedURL ?? subscription.originalURL
    }

    func nextPreviewURL(for subscription: Subscription) -> String {
        // Fixed addresses don't rotate by date — preview is the configured URL itself.
        guard subscription.urlMode == .dateTemplate else {
            return subscription.originalURL
        }
        let timeZone = TimeZone(identifier: subscription.urlDateTimeZoneID) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Next update starts from "today + dateOffset" (usually today).
        let target = calendar.date(byAdding: .day, value: subscription.dateOffset, to: Date()) ?? Date()
        return resolveURL(for: subscription, date: target)
    }

    func computeNextUpdateAt(for subscription: Subscription, from date: Date = Date()) -> Date? {
        guard subscription.autoUpdate, subscription.updateInterval != .manual else { return nil }
        let timeZone = TimeZone(identifier: subscription.timeZoneID) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        switch subscription.updateInterval {
        case .daily, .every2Days, .weekly:
            var components = calendar.dateComponents([.year, .month, .day], from: date)
            components.hour = subscription.updateHour
            components.minute = subscription.updateMinute
            components.second = 0
            var candidate = calendar.date(from: components) ?? date
            if candidate <= date {
                let days: Int = {
                    switch subscription.updateInterval {
                    case .daily: return 1
                    case .every2Days: return 2
                    case .weekly: return 7
                    default: return 1
                    }
                }()
                candidate = calendar.date(byAdding: .day, value: days, to: candidate) ?? candidate
            }
            return candidate
        case .every6Hours, .every12Hours:
            guard let interval = subscription.updateInterval.seconds else { return nil }
            return date.addingTimeInterval(interval)
        case .manual:
            return nil
        }
    }

    /// Documented backoff after failed updates: 1 → 5 → 30 minutes.
    func scheduleFailureRetry(for subscription: inout Subscription, from date: Date = Date()) {
        subscription.updateFailureCount += 1
        let minutes: TimeInterval = {
            switch subscription.updateFailureCount {
            case 1: return 1
            case 2: return 5
            default: return 30
            }
        }()
        subscription.nextRetryAt = date.addingTimeInterval(minutes * 60)
    }

    func clearFailureRetry(for subscription: inout Subscription) {
        subscription.updateFailureCount = 0
        subscription.nextRetryAt = nil
    }

    func testAddress(_ subscription: Subscription) async -> SubscriptionTestReport {
        defer { updateState = .idle }
        let started = Date()
        updateState = .resolvingURL

        let dates = candidateDates(
            offset: subscription.dateOffset,
            fallbackDays: subscription.fallbackDays,
            timeZoneID: subscription.urlDateTimeZoneID
        )

        for (index, date) in dates.enumerated() {
            let url = resolveURL(for: subscription, date: date)
            updateState = .fetching
            do {
                let response = try await fetcher.fetch(urlString: url)
                updateState = .validating
                guard SubscriptionPayloadValidator.validateBasic(response.data) else { continue }
                updateState = .parsing
                let parsed = try SubscriptionContentParser.parse(data: response.data)
                let deduped = SubscriptionMerger.deduplicate(parsed.validNodes)
                let duration = Int(Date().timeIntervalSince(started) * 1000)
                let report = SubscriptionTestReport(
                    resolvedURL: url,
                    httpStatus: response.statusCode,
                    downloadBytes: response.data.count,
                    formatName: parsed.formatName,
                    totalParsed: parsed.validNodes.count + parsed.invalidCount,
                    validCount: parsed.validNodes.count,
                    duplicateCount: max(0, parsed.validNodes.count - deduped.count),
                    invalidCount: parsed.invalidCount,
                    durationMS: duration,
                    errorMessage: index > 0 ? "使用回退日期" : nil
                )
                lastTestReport = report
                updateState = .completed
                return report
            } catch {
                continue
            }
        }

        let report = SubscriptionTestReport(
            resolvedURL: subscription.originalURL,
            httpStatus: nil,
            downloadBytes: 0,
            formatName: "—",
            totalParsed: 0,
            validCount: 0,
            duplicateCount: 0,
            invalidCount: 0,
            durationMS: Int(Date().timeIntervalSince(started) * 1000),
            errorMessage: "全部候选地址均不可用"
        )
        lastTestReport = report
        updateState = .failed(report.errorMessage ?? "失败")
        return report
    }

    func update(
        _ subscription: Subscription,
        existingNodes: [ProxyNode],
        preserveNodeIDs: Set<UUID> = []
    ) async -> (Subscription, [ProxyNode], SubscriptionUpdateLog) {
        defer { updateState = .idle }
        if subscription.isShareLinksBundle {
            return await updateShareLinksBundle(subscription, existingNodes: existingNodes, preserveNodeIDs: preserveNodeIDs)
        }

        var sub = subscription
        sub.lastAttemptAt = Date()
        updateState = .resolvingURL
        logger.info("开始更新订阅：\(sub.name)", category: .subscription)

        let dates = candidateDates(
            offset: sub.dateOffset,
            fallbackDays: sub.fallbackDays,
            timeZoneID: sub.urlDateTimeZoneID
        )

        var payload: Data?
        var actualURL: String?
        var httpStatus: Int?
        var usedFallback = false
        var resolvedDateText: String?
        var etag: String?
        var lastModified: String?
        var lastFailureReason: String?

        for (index, date) in dates.enumerated() {
                let resolved = resolveURL(for: sub, date: date)
            updateState = .fetching
            do {
                // Never reuse validators across different dated URLs — otherwise a date
                // change can get a spurious 304 and skip merge entirely.
                let sameURL = sub.lastResolvedURL == resolved
                var response = try await fetcher.fetch(
                    urlString: resolved,
                    etag: sameURL ? sub.etag : nil,
                    lastModified: sameURL ? sub.lastModified : nil
                )
                httpStatus = response.statusCode
                if response.notModified {
                    if sameURL {
                        sub.lastSuccessAt = Date()
                        sub.lastHTTPStatus = 304
                        sub.lastError = nil
                        sub.statusMessage = "订阅没有变化"
                        sub.nextUpdateAt = computeNextUpdateAt(for: sub)
                        clearFailureRetry(for: &sub)
                        let log = SubscriptionUpdateLog(
                            subscriptionID: sub.id,
                            finishedAt: Date(),
                            requestedURL: resolved,
                            httpStatus: 304,
                            success: true,
                            contentHash: sub.contentHash,
                            resolvedDateText: formatDate(date, timeZoneID: sub.urlDateTimeZoneID)
                        )
                        updateState = .completed
                        return (sub, existingNodes, log)
                    }
                    // URL changed but server still 304'd — refetch without validators.
                    response = try await fetcher.fetch(
                        urlString: resolved,
                        etag: nil,
                        lastModified: nil
                    )
                    httpStatus = response.statusCode
                    if response.notModified {
                        lastFailureReason = "日期地址返回 304，已跳过"
                        continue
                    }
                }

                updateState = .validating
                guard SubscriptionPayloadValidator.validateBasic(response.data) else {
                    lastFailureReason = "内容校验失败（可能是空页面或 HTML）"
                    continue
                }

                // Probe parse before accepting.
                updateState = .parsing
                let parsed = try SubscriptionContentParser.parse(data: response.data)
                guard !parsed.validNodes.isEmpty else {
                    lastFailureReason = "未解析到有效节点"
                    continue
                }

                payload = response.data
                actualURL = resolved
                etag = response.etag
                lastModified = response.lastModified
                usedFallback = index > 0
                resolvedDateText = formatDate(date, timeZoneID: sub.urlDateTimeZoneID)
                sub.lastResolvedDate = date
                break
            } catch {
                lastFailureReason = error.localizedDescription
                logger.warning("候选地址失败 \(resolved)：\(error.localizedDescription)", category: .subscription)
                continue
            }
        }

        guard let payload, let actualURL else {
            let detail = lastFailureReason.map { "（\($0)）" } ?? ""
            sub.lastError = "更新失败，仍使用上次成功数据\(detail)"
            sub.lastHTTPStatus = httpStatus
            sub.statusMessage = sub.lastError
            scheduleFailureRetry(for: &sub)
            sub.nextUpdateAt = computeNextUpdateAt(for: sub)
            let log = SubscriptionUpdateLog(
                subscriptionID: sub.id,
                finishedAt: Date(),
                requestedURL: resolveURL(for: sub, date: Date()),
                httpStatus: httpStatus,
                success: false,
                errorMessage: sub.lastError
            )
            updateState = .failed(sub.lastError ?? "失败")
            return (sub, existingNodes, log)
        }

        let newHash = CryptoUtil.sha256Hex(payload)
        if newHash == sub.contentHash {
            // Same body as last time — still refresh resolved URL / message, but no merge work.
            let previousURL = sub.lastResolvedURL
            sub.lastSuccessAt = Date()
            sub.lastError = nil
            sub.resolvedURL = actualURL
            sub.lastResolvedURL = actualURL
            sub.etag = etag ?? sub.etag
            sub.lastModified = lastModified ?? sub.lastModified
            if previousURL != actualURL {
                sub.statusMessage = usedFallback
                    ? "今日订阅尚未发布，沿用 \(resolvedDateText ?? "")（节点内容与上次相同）"
                    : "日期已切换，节点内容与上次相同（无需合并）"
            } else {
                sub.statusMessage = usedFallback
                    ? "今日订阅尚未发布，当前使用：\(resolvedDateText ?? "")（内容未变化）"
                    : "订阅没有变化"
            }
            sub.nextUpdateAt = computeNextUpdateAt(for: sub)
            clearFailureRetry(for: &sub)
            updateState = .completed
            let existingCount = existingNodes.filter { $0.subscriptionID == sub.id }.count
            let log = SubscriptionUpdateLog(
                subscriptionID: sub.id,
                finishedAt: Date(),
                requestedURL: actualURL,
                httpStatus: httpStatus,
                success: true,
                fetchedCount: existingCount,
                contentHash: newHash,
                usedFallbackDate: usedFallback,
                resolvedDateText: resolvedDateText
            )
            return (sub, existingNodes, log)
        }

        do {
            updateState = .parsing
            let parsed = try await Task.detached(priority: .userInitiated) {
                try SubscriptionContentParser.parse(data: payload)
            }.value
            guard !parsed.validNodes.isEmpty else {
                throw ParserError.noValidNodes
            }

            // Destructive overwrite protection
            let oldForSub = existingNodes.filter { $0.subscriptionID == sub.id }
            if sub.updateMode == .overwrite,
               !oldForSub.isEmpty,
               Double(parsed.validNodes.count) < Double(oldForSub.count) * 0.1 {
                sub.lastError = "订阅节点数量异常下降 \(oldForSub.count) → \(parsed.validNodes.count)，已保留旧节点"
                sub.statusMessage = sub.lastError
                scheduleFailureRetry(for: &sub)
                updateState = .failed(sub.lastError ?? "")
                let log = SubscriptionUpdateLog(
                    subscriptionID: sub.id,
                    finishedAt: Date(),
                    requestedURL: actualURL,
                    httpStatus: httpStatus,
                    success: false,
                    fetchedCount: parsed.validNodes.count,
                    errorMessage: sub.lastError
                )
                return (sub, existingNodes, log)
            }

            updateState = .deduplicating
            let normalized = parsed.validNodes.map { node -> ProxyNode in
                var copy = node
                copy.subscriptionID = sub.id
                copy.sourceName = sub.name
                CountryResolver.applyNameHeuristics(to: &copy)
                copy.nodeFingerprint = NodeFingerprint.make(from: copy)
                KeychainStore.storeNodeCredentials(&copy)
                return copy
            }

            updateState = .merging
            let oldNodes = existingNodes.filter { $0.subscriptionID == sub.id }
            let otherNodes = existingNodes.filter { $0.subscriptionID != sub.id }
            let plan = SubscriptionMerger.buildPlan(
                mode: sub.updateMode,
                oldNodes: oldNodes,
                newNodes: normalized,
                missingLimit: sub.smartMergeMissingLimit,
                preserveNodeIDs: preserveNodeIDs
            )

            let resulting = otherNodes + plan.resultingNodes
            sub.contentHash = newHash
            sub.etag = etag
            sub.lastModified = lastModified
            sub.resolvedURL = actualURL
            sub.lastResolvedURL = actualURL
            sub.lastSuccessAt = Date()
            sub.lastHTTPStatus = httpStatus
            sub.lastError = nil
            sub.nodeCount = plan.resultingNodes.count
            sub.nextUpdateAt = computeNextUpdateAt(for: sub)
            clearFailureRetry(for: &sub)
            if usedFallback {
                sub.statusMessage = "今日订阅尚未发布，当前使用：\(resolvedDateText ?? "")"
            } else {
                sub.statusMessage = "更新成功"
            }

            let log = SubscriptionUpdateLog(
                subscriptionID: sub.id,
                finishedAt: Date(),
                requestedURL: actualURL,
                httpStatus: httpStatus,
                success: true,
                fetchedCount: parsed.validNodes.count,
                addedCount: plan.addedCount,
                updatedCount: plan.updatedCount,
                removedCount: plan.removedCount,
                duplicateCount: plan.duplicateCount,
                invalidCount: parsed.invalidCount,
                contentHash: newHash,
                usedFallbackDate: usedFallback,
                resolvedDateText: resolvedDateText
            )

            updateState = .completed
            logger.info(
                "订阅 \(sub.name) 更新成功：+\(plan.addedCount) ~\(plan.updatedCount) -\(plan.removedCount)",
                category: .subscription
            )
            return (sub, resulting, log)
        } catch {
            sub.lastError = error.localizedDescription
            sub.statusMessage = "更新失败，仍使用上次成功数据"
            scheduleFailureRetry(for: &sub)
            updateState = .failed(error.localizedDescription)
            let log = SubscriptionUpdateLog(
                subscriptionID: sub.id,
                finishedAt: Date(),
                requestedURL: actualURL,
                httpStatus: httpStatus,
                success: false,
                errorMessage: error.localizedDescription
            )
            return (sub, existingNodes, log)
        }
    }

    func importShareLinks(
        _ text: String,
        sourceName: String = "手动导入",
        subscriptionID: UUID? = nil
    ) -> [ProxyNode] {
        let parsed = NodeLinkParser.parseLines(text)
        return parsed.validNodes.map { node in
            var copy = node
            copy.sourceName = sourceName
            copy.subscriptionID = subscriptionID
            CountryResolver.applyNameHeuristics(to: &copy)
            copy.nodeFingerprint = NodeFingerprint.make(from: copy)
            KeychainStore.storeNodeCredentials(&copy)
            return copy
        }
    }

    private func updateShareLinksBundle(
        _ subscription: Subscription,
        existingNodes: [ProxyNode],
        preserveNodeIDs: Set<UUID>
    ) async -> (Subscription, [ProxyNode], SubscriptionUpdateLog) {
        var sub = subscription
        sub.lastAttemptAt = Date()
        updateState = .parsing
        logger.info("解析节点分享链接：\(sub.name)", category: .subscription)

        let text = sub.shareLinksText ?? ""
        let parsed = NodeLinkParser.parseLines(text)
        guard !parsed.validNodes.isEmpty else {
            sub.lastError = "未解析到有效节点（ss/vless/vmess/trojan）"
            sub.statusMessage = sub.lastError
            scheduleFailureRetry(for: &sub)
            updateState = .failed(sub.lastError ?? "")
            let log = SubscriptionUpdateLog(
                subscriptionID: sub.id,
                requestedURL: "share://links",
                success: false,
                invalidCount: parsed.invalidCount,
                errorMessage: sub.lastError
            )
            return (sub, existingNodes, log)
        }

        let imported = parsed.validNodes.map { node -> ProxyNode in
            var copy = node
            copy.subscriptionID = sub.id
            copy.sourceName = sub.name
            CountryResolver.applyNameHeuristics(to: &copy)
            copy.nodeFingerprint = NodeFingerprint.make(from: copy)
            KeychainStore.storeNodeCredentials(&copy)
            return copy
        }

        updateState = .merging
        let others = existingNodes.filter { $0.subscriptionID != sub.id }
        let oldForSub = existingNodes.filter { $0.subscriptionID == sub.id }
        let plan = SubscriptionMerger.buildPlan(
            mode: sub.updateMode,
            oldNodes: oldForSub,
            newNodes: imported,
            missingLimit: sub.smartMergeMissingLimit,
            preserveNodeIDs: preserveNodeIDs
        )
        let merged = others + plan.resultingNodes
        sub.nodeCount = plan.resultingNodes.filter { !$0.pendingRemoval }.count
        sub.lastSuccessAt = Date()
        sub.lastError = nil
        clearFailureRetry(for: &sub)
        sub.lastHTTPStatus = nil
        sub.statusMessage = "已导入 \(parsed.validNodes.count) 个分享节点"
        sub.contentHash = String(text.hashValue)
        sub.nextUpdateAt = nil
        sub.autoUpdate = false

        let log = SubscriptionUpdateLog(
            subscriptionID: sub.id,
            finishedAt: Date(),
            requestedURL: "share://links",
            success: true,
            fetchedCount: parsed.validNodes.count,
            addedCount: plan.addedCount,
            updatedCount: plan.updatedCount,
            removedCount: plan.removedCount,
            duplicateCount: plan.duplicateCount,
            invalidCount: parsed.invalidCount,
            contentHash: sub.contentHash
        )
        updateState = .completed
        return (sub, merged, log)
    }

    private func formatDate(_ date: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
