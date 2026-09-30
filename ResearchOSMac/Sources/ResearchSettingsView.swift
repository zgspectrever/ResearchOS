import SwiftUI
import AppKit

struct ResearchSettingsView: View {
    @ObservedObject var store: ResearchStore
    @AppStorage("ResearchOS.isWorkspaceListHidden") private var hideList = false
    @AppStorage("ResearchOS.listDensity") private var listDensity = "comfortable"
    @AppStorage("ResearchOS.showsListPreview") private var showsPreview = true
    @AppStorage("ResearchOS.readingFontSize") private var fontSize = 17.0
    @AppStorage("ResearchOS.readingLineHeight") private var lineHeight = 1.72
    @AppStorage("ResearchOS.readingPageWidth") private var pageWidth = 790.0
    @State private var status: String?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("通用", systemImage: "gearshape") }
            readingTab.tabItem { Label("阅读", systemImage: "book") }
            dataTab.tabItem { Label("数据与同步", systemImage: "externaldrive") }
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 430)
        .padding(20)
    }

    private var generalTab: some View {
        Form {
            Section("界面") {
                Toggle("默认隐藏文档列表", isOn: $hideList)
                Toggle("显示文档摘要", isOn: $showsPreview)
                Picker("列表密度", selection: $listDensity) {
                    Text("舒适").tag("comfortable")
                    Text("紧凑").tag("compact")
                }
            }
            Section("外部文件") {
                Text("打开应用时会检查已导入的 Markdown、Word 与文件夹来源，并同步外部修改。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var readingTab: some View {
        Form {
            Section("Markdown 阅读") {
                Stepper("字号  (Int(fontSize))", value: $fontSize, in: 14...24, step: 1)
                Picker("行距", selection: $lineHeight) {
                    Text("紧凑").tag(1.5); Text("适中").tag(1.72); Text("宽松").tag(2.0)
                }
                Picker("正文宽度", selection: $pageWidth) {
                    Text("窄").tag(660.0); Text("适中").tag(790.0); Text("宽").tag(980.0)
                }
                Button("恢复阅读默认值") { fontSize = 17; lineHeight = 1.72; pageWidth = 790 }
            }
        }
        .formStyle(.grouped)
    }

    private var dataTab: some View {
        Form {
            Section("本地资料") {
                LabeledContent("当前项目") { Text("\(store.questions.count) 个") }
                LabeledContent("论文") { Text("\(store.papers.count) 篇") }
                LabeledContent("写作文档") { Text("\(store.markdownDocuments.count) 篇") }
            }
            Section("备份与恢复") {
                Text("备份只包含 ResearchOS 的索引、笔记和写作内容，不会复制原始 PDF 或 Word 文件。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("立即备份") { _ = store.createBackup(); status = "备份已创建" }
                    Button("导出备份…") { exportBackup() }
                    Button("从备份恢复…") { importBackup() }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("安全提示") {
                Text("恢复前会自动保留当前版本。建议在大规模整理资料前先手动备份。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("文档版本历史") {
                if store.writingDocumentVersions.isEmpty {
                    Text("编辑文稿后，旧版本会自动保留在这里（每篇最多 20 个版本）。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.writingDocumentVersions.prefix(8)) { version in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.title.isEmpty ? "未命名文稿" : version.title)
                                    .lineLimit(1)
                                Text(version.createdAt, style: .date)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("恢复") { store.restoreVersion(version.id) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            Section("同步冲突") {
                if store.writingSyncConflicts.isEmpty {
                    Text("当前没有待处理的同步冲突。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.writingSyncConflicts) { conflict in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conflict.title.isEmpty ? "未命名文稿" : conflict.title).lineLimit(1)
                                Text("应用与外部文件都发生了修改")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("保留应用") { store.resolveSyncConflict(conflict.id, keepExternal: false) }
                                .controlSize(.small)
                            Button("采用外部") { store.resolveSyncConflict(conflict.id, keepExternal: true) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            Section("文档健康检查") {
                if store.healthIssues.isEmpty {
                    Label("当前没有发现明显问题", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(Array(store.healthIssues.prefix(12).enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if store.healthIssues.count > 12 {
                        Text("还有 \(store.healthIssues.count - 12) 项问题未展开")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("标签概览") {
                if store.tagUsage.isEmpty {
                    Text("还没有标签。标签可以用于跨文件夹组织论文和写作稿件。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.tagUsage.prefix(12), id: \.0) { tag, count in
                        HStack { Text(tag); Spacer(); Text("\(count) 项").foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical.fill").font(.system(size: 42)).foregroundStyle(.blue)
            Text("ResearchOS").font(.title2.weight(.semibold))
            Text("把文献、阅读、写作和研究过程放在同一个工作台。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("本地优先 · 当前版本 0.3.1").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ResearchOS-backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportLibrary(to: url); status = "备份已导出" }
        catch { status = "导出失败：\(error.localizedDescription)" }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.importLibrary(from: url); status = "数据已恢复" }
        catch { status = "恢复失败：请选择有效的 ResearchOS JSON 备份" }
    }
}
