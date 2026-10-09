import AppKit
import SwiftUI

struct RunningApplicationPicker: View {
    let selectedPaths: Set<String>
    let onSelect: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var entries: [ApplicationPickerEntry] = []
    @FocusState private var searchFocused: Bool

    private var results: [ApplicationPickerEntry] { entries.filter { $0.matches(query) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索运行中的应用", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索应用名称、标识或路径")
                    .onSubmit {
                        if let first = results.first(where: { !selectedPaths.contains($0.id) }) { select(first) }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        searchFocused = true
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("清空搜索")
                    .accessibilityLabel("清空搜索")
                }
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("刷新运行中的应用")
                    .accessibilityLabel("刷新运行中的应用")
            }
            .padding(12)
            Divider()
            ScrollView {
                if results.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.title2)
                        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无运行中的应用" : "未找到匹配的运行中应用")
                        Text("可使用「添加应用 / 可执行文件…」选择未启动的应用。")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .padding(.horizontal, 12)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { entry in
                            Button { select(entry) } label: {
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                                        .resizable().renderingMode(.original)
                                        .scaledToFit().frame(width: 24, height: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).foregroundStyle(.primary)
                                        Text(entry.url.path).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 4)
                                    if selectedPaths.contains(entry.id) {
                                        Label("已添加", systemImage: "checkmark")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: "plus").foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedPaths.contains(entry.id))
                            .help(entry.url.path)
                            .accessibilityLabel("\(entry.name)，\(selectedPaths.contains(entry.id) ? "已添加" : "添加到代理应用")")
                        }
                    }
                    .padding(6)
                }
            }
            .frame(height: 300)
            Divider()
            HStack {
                Text("\(results.count) 个匹配应用 / 共 \(entries.count) 个")
                Spacer()
                Text("回车添加首个结果 · Esc 关闭")
            }
            .font(.caption2).foregroundStyle(.secondary).padding(10)
        }
        .frame(width: 440)
        .onAppear { reload() }
        .task { searchFocused = true }
        .onExitCommand { dismiss() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in reload() }
    }

    private func select(_ entry: ApplicationPickerEntry) {
        guard !selectedPaths.contains(entry.id) else { return }
        onSelect(entry.url)
        dismiss()
    }

    private func reload() {
        var seen = Set<String>()
        entries = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let url = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL,
                  seen.insert(url.path).inserted else { return nil }
            return ApplicationPickerEntry(url: url,
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: app.bundleIdentifier ?? "")
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
