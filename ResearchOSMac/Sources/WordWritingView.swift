import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WordDocumentWorkspace: View {
    @ObservedObject var store: ResearchStore
    let documentID: UUID
    let onOpenURL: (URL) -> Void
    @State private var displayMode: MarkdownDisplayMode = .preview
    @State private var showsRename = false
    @StateObject private var controller = RichTextEditorController()

    private var document: MarkdownDocument? {
        store.markdownDocuments.first { $0.id == documentID }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { document?.title ?? "" },
            set: { store.updateMarkdown(documentID, title: $0) }
        )
    }

    var body: some View {
        if let document {
            VStack(spacing: 0) {
                documentBar(document)
                if displayMode == .edit {
                    RichTextFormattingBar(controller: controller)
                }
                RichTextEditor(
                    rtfData: document.richTextData,
                    fallbackText: document.content,
                    isEditable: displayMode == .edit,
                    controller: controller,
                    onOpenURL: onOpenURL
                ) { data, plainText in
                    store.updateRichText(documentID, data: data, plainText: plainText)
                }
            }
            .background(ResearchPalette.window)
            .navigationTitle(document.title)
            .onChange(of: documentID) { _, _ in displayMode = .preview }
            .sheet(isPresented: $showsRename) {
                WritingNameSheet(title: "重命名文稿", initialValue: document.title, prompt: "文稿名称") { name in
                    store.renameWritingDocument(documentID, to: name)
                }
            }
        } else {
            ContentUnavailableView("文稿不存在", systemImage: "doc.badge.ellipsis")
        }
    }

    private func documentBar(_ document: MarkdownDocument) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                documentIdentity(document)
                    .frame(minWidth: 160)
                documentControls(document, compact: false)
            }
            VStack(spacing: 8) {
                documentIdentity(document)
                HStack {
                    Spacer(minLength: 0)
                    documentControls(document, compact: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            // Keep one keyboard shortcut outside the adaptive alternatives.
            Button("保存文稿") { store.saveWritingDocument(documentID) }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private func documentIdentity(_ document: MarkdownDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: document.resolvedKind.symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if displayMode == .edit {
                    TextField("文稿标题", text: titleBinding)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("文稿标题")
                } else {
                    Text(document.title.isEmpty ? "未命名文稿" : document.title)
                        .help(document.title)
                }
                Text("Word")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 34)
    }

    private func documentControls(_ document: MarkdownDocument, compact: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                store.saveWritingDocument(documentID)
            } label: {
                if compact {
                    Image(systemName: "tray.and.arrow.down")
                        .frame(width: 28, height: 28)
                } else {
                    Label("保存", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 4)
                        .frame(height: 28)
                }
            }
            .accessibilityLabel("保存文稿")
            .help("保存到 ResearchOS（⌘S）；编辑内容也会自动保存到本应用")
            .fixedSize()

            if compact {
                Menu {
                    Picker("显示方式", selection: $displayMode) {
                        Text("阅读").tag(MarkdownDisplayMode.preview)
                        Text("编辑").tag(MarkdownDisplayMode.edit)
                    }
                } label: {
                    Text(displayMode.title)
                        .frame(minWidth: 34, minHeight: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("显示方式：\(displayMode == .edit ? "编辑" : "阅读")")
                .accessibilityLabel("显示方式")
            } else {
                Picker("显示方式", selection: $displayMode) {
                    Text("阅读").tag(MarkdownDisplayMode.preview)
                    Text("编辑").tag(MarkdownDisplayMode.edit)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 126)
            }

            Menu {
                Button("重命名文稿…", systemImage: "pencil") { showsRename = true }
                Button("导出 Word…", systemImage: "square.and.arrow.up") { export(document) }
                Divider()
                Button("切换全屏", systemImage: "arrow.up.left.and.arrow.down.right") {
                    controller.toggleFullScreen()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多文稿操作")
            .accessibilityLabel("更多文稿操作")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(5)
        .researchGlassSurface()
        .fixedSize()
    }

    private func export(_ document: MarkdownDocument) {
        let panel = NSSavePanel()
        panel.title = "导出 Word 文档"
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = "\(document.title.isEmpty ? "未命名论文" : document.title).docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributed: NSAttributedString
            if let data = document.richTextData {
                attributed = try NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
            } else {
                attributed = NSAttributedString(string: document.content)
            }
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
            try data.write(to: url, options: .atomic)
            store.operationMessage = "已导出 \(url.lastPathComponent)"
        } catch {
            store.operationMessage = "Word 导出失败：\(error.localizedDescription)"
        }
    }
}

@MainActor
final class RichTextEditorController: ObservableObject {
    weak var textView: NSTextView?

    func attach(_ textView: NSTextView) { self.textView = textView }
    func undo() { focus(); textView?.undoManager?.undo() }
    func redo() { focus(); textView?.undoManager?.redo() }
    func bold() { toggleFontTrait(.boldFontMask) }
    func italic() { toggleFontTrait(.italicFontMask) }

    func underline() {
        guard let textView else { return }
        focus()
        let range = textView.selectedRange()
        if range.length == 0 {
            let current = (textView.typingAttributes[.underlineStyle] as? Int) ?? 0
            textView.typingAttributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            return
        }
        let current = (textView.textStorage?.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int) ?? 0
        textView.textStorage?.addAttribute(.underlineStyle, value: current == 0 ? NSUnderlineStyle.single.rawValue : 0, range: range)
        textView.didChangeText()
    }

    func setFontSize(_ size: CGFloat) {
        guard let textView else { return }
        focus()
        let range = textView.selectedRange()
        if range.length == 0 {
            let font = (textView.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 13)
            textView.typingAttributes[.font] = NSFont(descriptor: font.fontDescriptor, size: size) ?? .systemFont(ofSize: size)
            return
        }
        textView.textStorage?.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? .systemFont(ofSize: 13)
            let resized = NSFont(descriptor: font.fontDescriptor, size: size) ?? .systemFont(ofSize: size)
            textView.textStorage?.addAttribute(.font, value: resized, range: subrange)
        }
        textView.didChangeText()
    }

    func alignLeft() { focus(); textView?.alignLeft(nil) }
    func alignCenter() { focus(); textView?.alignCenter(nil) }
    func alignRight() { focus(); textView?.alignRight(nil) }
    func bullet() { prefixSelectedLines("• ") }
    func numbered() { prefixSelectedLines("1. ") }
    func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        focus()
        let manager = NSFontManager.shared
        let range = textView.selectedRange()
        if range.length == 0 {
            let font = (textView.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 13)
            let hasTrait = manager.traits(of: font).contains(trait)
            textView.typingAttributes[.font] = hasTrait
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            return
        }
        var allHaveTrait = true
        textView.textStorage?.enumerateAttribute(.font, in: range) { value, _, stop in
            let font = (value as? NSFont) ?? .systemFont(ofSize: 13)
            if !manager.traits(of: font).contains(trait) { allHaveTrait = false; stop.pointee = true }
        }
        textView.textStorage?.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? .systemFont(ofSize: 13)
            let converted = allHaveTrait
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            textView.textStorage?.addAttribute(.font, value: converted, range: subrange)
        }
        textView.didChangeText()
    }

    private func prefixSelectedLines(_ prefix: String) {
        guard let textView else { return }
        focus()
        let source = textView.string as NSString
        let range = source.lineRange(for: textView.selectedRange())
        let original = source.substring(with: range)
        let replacement = original.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : prefix + $0 }
            .joined(separator: "\n")
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: replacement.utf16.count))
    }

    private func focus() {
        if let textView { textView.window?.makeFirstResponder(textView) }
    }
}

struct RichTextEditor: NSViewRepresentable {
    let rtfData: Data?
    let fallbackText: String
    let isEditable: Bool
    let controller: RichTextEditorController
    let onOpenURL: (URL) -> Void
    let onChange: (Data, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.usesRuler = true
        textView.usesFontPanel = true
        textView.textContainerInset = NSSize(width: 68, height: 52)
        // A Word document is a sheet of paper, not application chrome. Keeping
        // the canvas white preserves imported black text when macOS switches
        // the surrounding ResearchOS interface to Dark Mode.
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textColor = .black
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        textView.isEditable = isEditable
        textView.isSelectable = true
        context.coordinator.load(rtfData: rtfData, fallbackText: fallbackText, into: textView)
        controller.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        textView.drawsBackground = true
        textView.backgroundColor = .white
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        controller.attach(textView)
        if context.coordinator.lastData != rtfData {
            context.coordinator.load(rtfData: rtfData, fallbackText: fallbackText, into: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastData: Data?
        private var isLoading = false

        init(parent: RichTextEditor) { self.parent = parent }

        func load(rtfData: Data?, fallbackText: String, into textView: NSTextView) {
            isLoading = true
            defer { isLoading = false }
            let attributed: NSAttributedString
            if let rtfData,
               let decoded = try? NSAttributedString(
                    data: rtfData,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
               ) {
                attributed = decoded
            } else {
                attributed = NSAttributedString(
                    string: fallbackText,
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]
                )
            }
            textView.textStorage?.setAttributedString(attributed)
            lastData = rtfData
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let textView = notification.object as? NSTextView,
                  let data = try? textView.attributedString().data(
                    from: NSRange(location: 0, length: textView.attributedString().length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                  ) else { return }
            lastData = data
            parent.onChange(data, textView.string)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let directURL = link as? URL {
                url = directURL
            } else if let value = link as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
            parent.onOpenURL(url)
            return true
        }
    }
}

struct RichTextFormattingBar: View {
    @ObservedObject var controller: RichTextEditorController

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                primaryTools
                Divider().frame(height: 20)
                tool("项目列表", "list.bullet", controller.bullet)
                tool("编号列表", "list.number", controller.numbered)
                tool("左对齐", "text.alignleft", controller.alignLeft)
                tool("居中", "text.aligncenter", controller.alignCenter)
                tool("右对齐", "text.alignright", controller.alignRight)
                Divider().frame(height: 20)
                tool("全屏", "arrow.up.left.and.arrow.down.right", controller.toggleFullScreen)
            }
            .fixedSize()

            HStack(spacing: 5) {
                primaryTools
                Divider().frame(height: 20)
                Menu {
                    Button("项目列表", systemImage: "list.bullet", action: controller.bullet)
                    Button("编号列表", systemImage: "list.number", action: controller.numbered)
                    Divider()
                    Button("左对齐", systemImage: "text.alignleft", action: controller.alignLeft)
                    Button("居中", systemImage: "text.aligncenter", action: controller.alignCenter)
                    Button("右对齐", systemImage: "text.alignright", action: controller.alignRight)
                    Divider()
                    Button("切换全屏", systemImage: "arrow.up.left.and.arrow.down.right", action: controller.toggleFullScreen)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("更多格式")
                .accessibilityLabel("更多格式")
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .researchGlassSurface(cornerRadius: 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var primaryTools: some View {
        Group {
            tool("撤销", "arrow.uturn.backward", controller.undo)
            tool("重做", "arrow.uturn.forward", controller.redo)
            Divider().frame(height: 20)
            Menu {
                Button("标题") { controller.setFontSize(26); controller.bold() }
                Button("一级标题") { controller.setFontSize(20); controller.bold() }
                Button("二级标题") { controller.setFontSize(16); controller.bold() }
                Button("正文") { controller.setFontSize(13) }
            } label: {
                Label("样式", systemImage: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("文字样式")
            tool("粗体", "bold", controller.bold)
            tool("斜体", "italic", controller.italic)
            tool("下划线", "underline", controller.underline)
        }
    }

    private func tool(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}
