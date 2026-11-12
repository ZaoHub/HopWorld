import SwiftUI
import Charts
import AppKit

struct CodexTokenStatisticsView: View {
    let fiveHourResetsAt: Double?
    let weeklyResetsAt: Double?
    var availableHeight: CGFloat = 640
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var period: Period = .fiveHour
    @State private var quotaPeriods: [CodexQuotaPeriod] = []
    @State private var selectedPeriodID: Date?
    @State private var referenceDate = Date()
    @State private var history: CodexTokenHistorySnapshot?
    @State private var updatedAt: Date?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedBucket: String?
    @State private var selectedModelID: String?
    @State private var detailMode: DetailMode = .quota
    @State private var chartStyle: ChartStyle = .bars
    /// nil shows both series. A name shows only that series so its own magnitude sets the axis.
    @State private var isolatedSeries: String?

    private enum DetailMode { case time, quota, models }
    private enum ChartStyle: String, CaseIterable {
        case bars = "柱状图", lines = "折线图"
        var symbol: String { self == .bars ? "chart.bar.xaxis" : "chart.line.uptrend.xyaxis" }
    }
    private var chartHeight: CGFloat { min(240, max(140, availableHeight * 0.24)) }
    private var showsModels: Bool { detailMode == .models }

    private enum Period: String, CaseIterable {
        case fiveHour = "5 小时", weekly = "一周"
        var duration: TimeInterval { self == .fiveHour ? 18_000 : 604_800 }
        var bucketDuration: TimeInterval { self == .fiveHour ? 1_800 : 18_000 }
    }

    private var periodIndex: Int {
        selectedPeriodID.flatMap { id in quotaPeriods.firstIndex { $0.id == id } } ?? max(0, quotaPeriods.count - 1)
    }

    private var quotaPeriod: CodexQuotaPeriod? { quotaPeriods.indices.contains(periodIndex) ? quotaPeriods[periodIndex] : nil }

    private var interval: DateInterval {
        quotaPeriod?.interval ?? DateInterval(start: referenceDate.addingTimeInterval(-period.duration), end: referenceDate)
    }

    private var buckets: [CodexTokenBucket] {
        history?.buckets(in: interval, bucketDuration: period.bucketDuration, modelID: selectedModelID,
                         accountID: quotaPeriod?.accountID) ?? []
    }

    private var models: [CodexTokenModelUsage] { history?.models(in: interval, accountID: quotaPeriod?.accountID) ?? [] }

    private var canGoBack: Bool {
        periodIndex > 0
    }

    private var outputColor: Color {
        colorScheme == .dark ? .orange : Color(nsColor: NSColor.systemOrange.blended(withFraction: 0.40, of: .black) ?? .systemOrange)
    }

    private var windowExplanation: String {
        guard let quotaPeriod else { return "尚未读取额度重置记录。" }
        var text = "本期统计：" + dateRange(interval) + "。重置边界只计入下一期，不重复计入前一期。"
        if quotaPeriod.start.kind == .inferredStart {
            text += "上次实际重置时间未记录，起点按额度窗口长度推算。"
        }
        if quotaPeriod.end.kind == .unavailable {
            text += "下次重置时间尚未获取，统计截止上次刷新。"
        } else if quotaPeriod.end.kind == .inferredStart {
            text += "结束分界由新额度窗口推算，实际提前重置时刻未记录。"
        }
        for boundary in [quotaPeriod.start, quotaPeriod.end] {
            if let range = boundary.observedBetween {
                text += "窗口变更发生于 " + dateRange(range) + " 之间，暂按首次观测时间分期，不认定为手动重置。"
            }
        }
        if let scheduled = quotaPeriod.scheduledResetAt, scheduled != quotaPeriod.end.date {
            text += "该期原定重置时间：" + fullDate(scheduled) + "。"
        }
        text += quotaPeriod.accountID == nil ? "账号未识别，统计包含本机该时段记录。" : "仅统计对应账号的记录，缺少账号标识的记录不混入。"
        return text
    }

    private var boundaryTitle: String {
        guard let quotaPeriod else { return dateRange(interval) }
        let startLabel: String
        switch quotaPeriod.start.kind {
        case .reportedReset: startLabel = "上次重置"
        case .observedChange: startLabel = "变更观测"
        default: startLabel = "起点推算"
        }
        let endLabel: String
        switch quotaPeriod.end.kind {
        case .observedChange: endLabel = "变更观测"
        case .inferredStart: endLabel = "分界推算"
        default: endLabel = quotaPeriod.end.date > referenceDate ? "下次重置" : "结束重置"
        }
        let end = quotaPeriod.end.kind == .unavailable ? "下次重置未获取" : endLabel + " " + boundaryDate(quotaPeriod.end.date)
        return startLabel + " " + boundaryDate(quotaPeriod.start.date) + " → " + end
    }

    private var detailHint: String {
        if detailMode == .quota { return selectedModelID == nil ? "观测区间对齐 · 点=百分点" : "观测对齐 · 混用不归因" }
        if showsModels { return "点击模型筛选图表" }
        if let selected = buckets.first(where: { key($0) == selectedBucket }) {
            return "\(bucketRange(selected)) · 输入 \(exact(selected.inputTokens)) · 输出 \(exact(selected.outputTokens))"
        }
        return "点击图表或明细查看时段数值"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Codex Token 统计").font(.title2.weight(.semibold))
                Text("本机记录 · 输入与输出").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 16) {
                Picker("统计周期", selection: $period) {
                    ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Spacer()
                Button { changePeriod(-1) } label: { Image(systemName: "chevron.left") }
                    .help("上一个" + period.rawValue)
                    .accessibilityLabel("上一个" + period.rawValue)
                    .disabled(!canGoBack || isLoading)
                Button("当前") {
                    referenceDate = Date()
                    selectedPeriodID = nil
                    selectedBucket = nil
                    updatePeriods()
                }.disabled(periodIndex == quotaPeriods.count - 1)
                Button { changePeriod(1) } label: { Image(systemName: "chevron.right") }
                    .help("下一个" + period.rawValue)
                    .accessibilityLabel("下一个" + period.rawValue)
                    .disabled(periodIndex >= quotaPeriods.count - 1 || isLoading)
            }
            .controlSize(.small)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(boundaryTitle).font(.headline).monospacedDigit()
                    .lineLimit(1).layoutPriority(1)
                    .help(windowExplanation)
                TokenStatisticsHelpButton(title: "统计区间说明", detail: windowExplanation)
                Spacer(minLength: 0)
                Picker("使用模型", selection: $selectedModelID) {
                    Text(models.count == 1 ? "全部：" + models[0].displayName : "全部模型（\(models.count) 种）")
                        .tag(String?.none)
                    ForEach(models) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 260)
                .disabled(history == nil || models.isEmpty)
            }

            if isLoading && history == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取本机会话统计…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history == nil {
                UnavailablePlaceholder(
                    "暂时无法读取统计",
                    systemImage: "chart.bar.xaxis",
                    description: {
                        Text(errorMessage ?? "请使用 Codex 产生本机会话记录后刷新。")
                    },
                    actions: {
                        Button("重试") { Task { await refresh() } }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                statisticsContent
            }

            VStack(alignment: .leading, spacing: 5) {
                if let errorMessage, history != nil {
                    Label(errorMessage + "，保留上次统计。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(outputColor)
                }
                if history?.isPartial == true {
                    Label("部分文件或记录未能读取，当前统计可能不完整。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(outputColor)
                }
                HStack(spacing: 6) {
                    if isLoading { ProgressView().controlSize(.mini) }
                    if let updatedAt {
                        Text("更新于 " + updatedAt.formatted(date: .omitted, time: .standard))
                    }
                    TokenStatisticsHelpButton(title: "统计范围说明", detail: "仅统计本机保存的 Codex 会话，含归档与子代理；有账号标识时按对应额度账号分期。输入包含缓存命中，输出包含推理 Token；不等同于订阅额度或账单。")
                    Spacer()
                    Text("时区：" + TimeZone.current.identifier)
                }
                .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(24)
        .frame(width: 712, height: max(360, availableHeight))
        .task { await refresh() }
        .task(id: quotaPeriods.last?.scheduledResetAt) {
            guard let reset = quotaPeriods.last?.scheduledResetAt, reset > Date() else { return }
            do {
                try await Task.sleep(for: .seconds(reset.timeIntervalSinceNow + 1))
                try Task.checkCancellation()
                await refresh()
            } catch is CancellationError {
            } catch {}
        }
        .onChange(of: period) { _ in
            referenceDate = Date()
            selectedPeriodID = nil
            selectedBucket = nil
            selectedModelID = nil
            updatePeriods()
        }
        .onChange(of: fiveHourResetsAt) { _ in referenceDate = Date(); updatePeriods() }
        .onChange(of: weeklyResetsAt) { _ in referenceDate = Date(); updatePeriods() }
        .onChange(of: selectedModelID) { _ in selectedBucket = nil }
        .onChange(of: models.map(\.id)) { ids in
            if let selectedModelID, !ids.contains(selectedModelID) { self.selectedModelID = nil }
        }
    }

    private var statisticsContent: some View {
        let input = buckets.reduce(Int64(0)) { $0 + $1.inputTokens }
        let output = buckets.reduce(Int64(0)) { $0 + $1.outputTokens }
        let cached = buckets.reduce(Int64(0)) { $0 + $1.cachedInputTokens }
        return ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if period == .weekly { resetSummary }
            HStack(spacing: 12) {
                metric("输入 Token", value: input, note: "含缓存 " + compact(cached), color: .blue)
                metric("输出 Token", value: output, note: "含推理 Token", color: outputColor)
                metric("合计 Token", value: input + output, note: "输入 + 输出", color: .primary)
            }

            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    seriesButton("输入", color: .blue)
                    seriesButton("输出", color: outputColor)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(ChartStyle.allCases, id: \.self) { style in
                            Button { chartStyle = style } label: {
                                Image(systemName: style.symbol)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(chartStyle == style ? Color.accentColor : Color.secondary)
                            .background(chartStyle == style ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .help(style.rawValue)
                            .accessibilityLabel(style.rawValue)
                            .accessibilityAddTraits(chartStyle == style ? .isSelected : [])
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)

            if input == 0 && output == 0 {
                VStack(spacing: 5) {
                    Label("此区间没有已记录的 Token 消耗", systemImage: "chart.bar.xaxis")
                    Text("未保存、已删除或其他设备的会话不会出现在这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: chartHeight)
            } else {
                Chart(buckets) { bucket in
                    if chartStyle == .bars {
                        if showsSeries("输入") {
                            BarMark(x: .value("时段", key(bucket)), y: .value("Token", bucket.inputTokens))
                                .foregroundStyle(by: .value("类型", "输入"))
                                .position(by: .value("类型", "输入"))
                                .accessibilityLabel(bucketRange(bucket) + "，输入")
                                .accessibilityValue(exact(bucket.inputTokens) + " Token")
                        }
                        if showsSeries("输出") {
                            BarMark(x: .value("时段", key(bucket)), y: .value("Token", bucket.outputTokens))
                                .foregroundStyle(by: .value("类型", "输出"))
                                .position(by: .value("类型", "输出"))
                                .accessibilityLabel(bucketRange(bucket) + "，输出")
                                .accessibilityValue(exact(bucket.outputTokens) + " Token")
                        }
                    } else if bucket.start <= (updatedAt ?? referenceDate) {
                        if showsSeries("输入") {
                            LineMark(x: .value("时段", key(bucket)), y: .value("Token", bucket.inputTokens))
                                .foregroundStyle(by: .value("类型", "输入"))
                                .symbol(by: .value("类型", "输入"))
                                .accessibilityLabel(bucketRange(bucket) + "，输入")
                                .accessibilityValue(exact(bucket.inputTokens) + " Token")
                        }
                        if showsSeries("输出") {
                            LineMark(x: .value("时段", key(bucket)), y: .value("Token", bucket.outputTokens))
                                .foregroundStyle(by: .value("类型", "输出"))
                                .symbol(by: .value("类型", "输出"))
                                .accessibilityLabel(bucketRange(bucket) + "，输出")
                                .accessibilityValue(exact(bucket.outputTokens) + " Token")
                        }
                    }
                }
                .chartForegroundStyleScale(domain: ["输入", "输出"], range: [Color.blue, outputColor])
                .chartSymbolScale(domain: ["输入", "输出"], range: [BasicChartSymbolShape.circle, .square])
                .chartXScale(domain: buckets.map { key($0) })
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let value = value.as(String.self),
                               let index = buckets.firstIndex(where: { key($0) == value }),
                               index % (period == .weekly ? max(1, Int(ceil(Double(buckets.count) / 6))) : 1) == 0 {
                                VStack(spacing: 2) {
                                    if period == .weekly {
                                        Text(buckets[index].start.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                                    }
                                    Text(shortDate(buckets[index].start))
                                }
                                .font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let count = value.as(Double.self) {
                                Text(count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: chartHeight)
            }
            }

            HStack(spacing: 12) {
                Picker("明细类型", selection: $detailMode) {
                    Text(period == .fiveHour ? "每 30 分钟明细" : "每 5 小时明细").tag(DetailMode.time)
                    Text("额度下降").tag(DetailMode.quota)
                    Text("模型消耗").tag(DetailMode.models)
                }
                .pickerStyle(.segmented).controlSize(.small).labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                Text(detailHint)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .help(detailHint)
                Text(detailMode == .quota ? "Token／百分点" : "单位：Token")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                    .layoutPriority(1)
            }
            if detailMode == .quota {
                quotaComparisonTable
            } else {
            VStack(spacing: 0) {
                HStack {
                    Text(showsModels ? "模型 · 推理档位" : "时段").frame(maxWidth: .infinity, alignment: .leading)
                    Text("输入").frame(width: 110, alignment: .trailing)
                    Text("输出").frame(width: 100, alignment: .trailing)
                    HStack(spacing: 3) {
                        Text("缓存输入")
                        TokenStatisticsHelpButton(title: "缓存输入说明", detail: "缓存输入已包含在输入中，不重复计入合计。— 表示时段尚未开始。")
                    }
                    .frame(width: 110, alignment: .trailing)
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 6)
                Divider()
                LazyVStack(spacing: 0) {
                    if showsModels {
                        ForEach(models) { model in modelRow(model) }
                    } else {
                        ForEach(buckets) { bucket in
                            bucketRow(bucket)
                        }
                    }
                }
            }
            }
          }
          .padding(.trailing, 4)
        }
        .frame(maxHeight: .infinity)
    }

    private var quotaComparisonTable: some View {
        let rows = history?.quotaComparisons(in: interval, bucketDuration: period.bucketDuration,
            minutes: period == .fiveHour ? 300 : 10080, accountID: quotaPeriod?.accountID, modelID: selectedModelID) ?? []
        return VStack(spacing: 0) {
            HStack {
                Text("观测时段").frame(maxWidth: .infinity, alignment: .leading)
                Text("未缓存输入").frame(width: 90, alignment: .trailing)
                Text("输出").frame(width: 80, alignment: .trailing)
                Text("缓存输入").frame(width: 90, alignment: .trailing)
                HStack(spacing: 3) {
                    Text(period == .fiveHour ? "5h 额度下降" : "周额度下降")
                    TokenStatisticsHelpButton(title: "额度下降说明", detail: "显示账户剩余额度在首末观测之间下降的百分点，例如 80% 到 70% 为下降 10 点。带 * 表示中间读数曾回退后恢复，下降量按首末观测的净变化计算。Token 仅统计同一观测区间，不代表整个时段均有记录。跨重置、观测冲突或模型混用时不强行计算；其他设备也可能影响账户额度。")
                }
                .frame(width: 95, alignment: .trailing)
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 6)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in quotaComparisonRow(row) }
            }
        }
    }

    private func quotaComparisonRow(_ row: CodexQuotaComparison) -> some View {
        let future = row.start > (updatedAt ?? referenceDate)
        let sampled = row.sampledInterval != nil && !future
        let detail = quotaComparisonDetail(row)
        return Button { selectedBucket = String(row.start.timeIntervalSince1970) } label: {
            HStack {
                Text(quotaComparisonRange(row)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(sampled ? exact(row.uncachedInputTokens) : "—").frame(width: 90, alignment: .trailing)
                Text(sampled ? exact(row.outputTokens) : "—").frame(width: 80, alignment: .trailing)
                Text(sampled ? exact(row.cachedInputTokens) : "—").frame(width: 90, alignment: .trailing)
                Text(quotaComparisonValue(row)).frame(width: 95, alignment: .trailing)
                    .foregroundStyle(row.decline == nil ? Color.secondary : Color.primary)
            }
            .font(.caption).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selectedBucket == String(row.start.timeIntervalSince1970) ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(future)
        .help(detail)
        .accessibilityLabel(detail)
    }

    private func quotaComparisonValue(_ row: CodexQuotaComparison) -> String {
        if row.start > (updatedAt ?? referenceDate) { return "未开始" }
        if let decline = row.decline {
            return decline.formatted(.number.precision(.fractionLength(0...1))) + " 点" + (row.transientRollbackCount > 0 ? "*" : "")
        }
        switch row.status {
        case .unknownAccount: return "账号缺失"
        case .resetChanged: return "跨重置"
        case .conflicting: return "观测冲突"
        case .mixedModels: return "混合模型"
        case .noSelectedModel: return "无该模型"
        case .capped: return "达到上限"
        default: return "数据不足"
        }
    }

    private func quotaComparisonRange(_ row: CodexQuotaComparison) -> String {
        let range = row.sampledInterval ?? DateInterval(start: row.start, end: row.end)
        if period == .weekly || !Calendar.current.isDate(range.start, inSameDayAs: range.end) {
            return boundaryDate(range.start) + " – " + boundaryDate(range.end)
        }
        let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        if row.sampledInterval != nil && range.duration < 60 {
            return range.start.formatted(style) + " – " + range.end.formatted(style)
        }
        return shortDate(range.start) + " – " + shortDate(range.end)
    }

    private func quotaComparisonDetail(_ row: CodexQuotaComparison) -> String {
        var text = quotaComparisonRange(row) + "，" + quotaComparisonValue(row) + "。"
        if let range = row.sampledInterval {
            text += "首末观测：" + fullDate(range.start) + " – " + fullDate(range.end) + "，\(row.observationCount) 次观测。"
            text += "未缓存输入 \(exact(row.uncachedInputTokens))、缓存输入 \(exact(row.cachedInputTokens))、输出 \(exact(row.outputTokens)) Token。"
        }
        switch row.status {
        case .observed:
            if let from = row.fromPercent, let to = row.toPercent {
                text += "账户剩余额度 \((100 - from).formatted())% → \((100 - to).formatted())%。"
            }
            text += "Token 与额度差值使用同一观测区间，起始观测已包含的 Token 不重复计算。"
            if row.transientRollbackCount > 0 {
                text += "中间有 \(row.transientRollbackCount) 次额度读数回退后恢复，下降量按首末观测的净变化计算。"
            }
        case .mixedModels: text += "该区间同时使用多个模型或档位，不能把账户额度变化全部归给所选模型。"
        case .noSelectedModel: text += "该观测区间没有所选模型的本机记录。"
        case .resetChanged: text += "额度窗口发生变化，不能跨重置直接作差。"
        case .conflicting: text += "额度读数超出首末范围，或存在同刻冲突记录，暂不提供下降数值。"
        case .capped: text += "观测已达到 100% 上限，不能反映该区间全部 Token 的消耗。"
        case .unknownAccount: text += "缺少额度账号标识，不能合并不同账号观测。"
        case .insufficient: text += "至少需要同一窗口内两个不同时刻的有效观测，未记录不等于 0。"
        }
        return text
    }

    private var resetSummary: some View {
        let observations = (history?.resetObservations ?? []).filter { quotaPeriod?.accountID == nil || $0.accountID == quotaPeriod?.accountID }
        let summary = CodexResetHistory.summarize(observations, in: interval)
        let natural = summary.observationCount > 0 || summary.naturalResets > 0 ? "至少 \(summary.naturalResets) 次" : (summary.unknownAccountObservations > 0 ? "无法确认" : "未记录")
        let unknownAccount = summary.unknownAccountObservations > 0 ? "账号标识不全，次数仅供参考。" : ""
        let changes = summary.unattributedChanges > 0 ? "另有 \(summary.unattributedChanges) 次变化无法归因。" : ""
        return HStack(spacing: 12) {
            Text("5 小时额度重置").font(.subheadline.weight(.semibold))
            TokenStatisticsHelpButton(title: "重置统计说明", detail: "按本机额度记录观测，可能遗漏自然重置；接口未提供完整手动重置历史，未记录不等于 0 次。" + unknownAccount + changes)
            Spacer()
            Text("自然：" + natural).monospacedDigit()
            Text("手动：无法确认")
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func modelRow(_ model: CodexTokenModelUsage) -> some View {
        Button { selectedModelID = selectedModelID == model.id ? nil : model.id } label: {
            HStack {
                Text(model.displayName).frame(maxWidth: .infinity, alignment: .leading)
                Text(exact(model.inputTokens)).frame(width: 110, alignment: .trailing)
                Text(exact(model.outputTokens)).frame(width: 100, alignment: .trailing)
                Text(exact(model.cachedInputTokens)).frame(width: 110, alignment: .trailing)
            }
            .font(.caption).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selectedModelID == model.id ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.displayName)，输入 \(exact(model.inputTokens))，输出 \(exact(model.outputTokens))，其中缓存输入 \(exact(model.cachedInputTokens))")
        .accessibilityAddTraits(selectedModelID == model.id ? .isSelected : [])
    }

    private func bucketRow(_ bucket: CodexTokenBucket) -> some View {
        let isFuture = bucket.start > (updatedAt ?? referenceDate)
        let label = isFuture ? bucketRange(bucket) + "，时段尚未开始" : "\(bucketRange(bucket))，输入 \(exact(bucket.inputTokens))，输出 \(exact(bucket.outputTokens))，其中缓存输入 \(exact(bucket.cachedInputTokens))"
        return Button { selectedBucket = key(bucket) } label: {
            HStack {
                Text(bucketRange(bucket)).frame(maxWidth: .infinity, alignment: .leading)
                Text(isFuture ? "—" : exact(bucket.inputTokens)).frame(width: 110, alignment: .trailing)
                Text(isFuture ? "—" : exact(bucket.outputTokens)).frame(width: 100, alignment: .trailing)
                Text(isFuture ? "—" : exact(bucket.cachedInputTokens)).frame(width: 110, alignment: .trailing)
            }
            .font(.caption).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selectedBucket == key(bucket) ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(label)
    }

    private func showsSeries(_ name: String) -> Bool { isolatedSeries == nil || isolatedSeries == name }

    private func seriesButton(_ title: String, color: Color) -> some View {
        let isolated = isolatedSeries == title
        return Button { isolatedSeries = isolated ? nil : title } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isolated ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(isolatedSeries != nil && !isolated ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .help(isolated ? "同时显示输入与输出" : "只显示" + title)
        .accessibilityLabel(isolated ? title + "，已单独显示" : "只显示" + title)
        .accessibilityAddTraits(isolated ? .isSelected : [])
    }

    private func metric(_ title: String, value: Int64, note: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(compact(value)).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                .help(exact(value) + " Token")
                .accessibilityLabel(title + " " + exact(value))
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    @MainActor private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let read = Task.detached(priority: .utility) { try CodexTokenHistoryReader.read() }
            let result = try await withTaskCancellationHandler {
                try await read.value
            } onCancel: {
                read.cancel()
            }
            guard !Task.isCancelled else { return }
            history = result
            let now = Date()
            updatedAt = now
            referenceDate = now
            updatePeriods()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "读取失败，请检查本机会话目录的访问权限后重试"
        }
    }

    private func updatePeriods() {
        let value = period == .fiveHour ? fiveHourResetsAt : weeklyResetsAt
        let deadline = value.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        quotaPeriods = CodexResetHistory.periods(history?.resetObservations ?? [],
            minutes: period == .fiveHour ? 300 : 10080, now: referenceDate, latestResetsAt: deadline)
        if let selectedPeriodID, !quotaPeriods.contains(where: { $0.id == selectedPeriodID }) { self.selectedPeriodID = nil }
    }
    private func changePeriod(_ delta: Int) {
        let index = periodIndex + delta
        guard quotaPeriods.indices.contains(index) else { return }
        selectedPeriodID = index == quotaPeriods.count - 1 ? nil : quotaPeriods[index].id
        selectedBucket = nil
    }
    private func key(_ bucket: CodexTokenBucket) -> String { String(bucket.start.timeIntervalSince1970) }
    private func compact(_ value: Int64) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    private func exact(_ value: Int64) -> String { value.formatted(.number) }
    private func boundaryDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
    private func fullDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
    private func dateRange(_ range: DateInterval) -> String {
        let style = Date.FormatStyle.dateTime.year().month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return range.start.formatted(style) + " – " + range.end.formatted(style)
    }
    private func bucketRange(_ bucket: CodexTokenBucket) -> String {
        let style = Date.FormatStyle.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        if period == .weekly { return bucket.start.formatted(style) + " – " + bucket.end.formatted(style) }
        let sameDay = Calendar.current.isDate(bucket.start, inSameDayAs: bucket.end)
        return shortDate(bucket.start) + " – " + (sameDay ? shortDate(bucket.end) : bucket.end.formatted(style))
    }
}

private struct TokenStatisticsHelpButton: View {
    let title: String
    let detail: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Label(title, systemImage: "info.circle").labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .font(.caption).foregroundStyle(.secondary)
        .help(detail)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(detail).font(.callout)
            }
            .padding(16).frame(width: 320)
        }
    }
}
