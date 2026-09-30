import AppKit
import Combine
import PDFKit

struct PDFTextExcerpt: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let locator: String
}

struct PDFReadingPosition: Codable {
    let pageIndex: Int
    let pointX: Double
    let pointY: Double
    let scaleFactor: Double
    var showsThumbnails: Bool
    var navigatorMode: String?
}

final class PDFReadingPositionStore: ObservableObject {
    private let defaultsKey = "ResearchOS.PDFReadingPositions.v1"
    private let defaults: UserDefaults
    private var positions: [String: PDFReadingPosition]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: PDFReadingPosition].self, from: data) {
            positions = decoded
        } else {
            positions = [:]
        }
    }

    func position(for paperID: UUID) -> PDFReadingPosition? { positions[paperID.uuidString] }

    func setPosition(pageIndex: Int, point: CGPoint, scaleFactor: CGFloat, for paperID: UUID) {
        guard pageIndex >= 0, point.x.isFinite, point.y.isFinite,
              scaleFactor.isFinite, scaleFactor > 0 else { return }
        let existing = positions[paperID.uuidString]
        positions[paperID.uuidString] = PDFReadingPosition(
            pageIndex: pageIndex, pointX: point.x, pointY: point.y, scaleFactor: scaleFactor,
            showsThumbnails: existing?.showsThumbnails ?? true, navigatorMode: existing?.navigatorMode
        )
        persist()
    }

    func showsThumbnails(for paperID: UUID) -> Bool { position(for: paperID)?.showsThumbnails ?? true }

    func setShowsThumbnails(_ visible: Bool, for paperID: UUID) {
        var position = position(for: paperID) ?? PDFReadingPosition(
            pageIndex: 0, pointX: 0, pointY: 0, scaleFactor: 0,
            showsThumbnails: visible, navigatorMode: nil
        )
        position.showsThumbnails = visible
        positions[paperID.uuidString] = position
        persist()
    }

    func setNavigatorMode(_ mode: PDFNavigatorMode, for paperID: UUID) {
        var position = position(for: paperID) ?? PDFReadingPosition(
            pageIndex: 0, pointX: 0, pointY: 0, scaleFactor: 0,
            showsThumbnails: true, navigatorMode: nil
        )
        position.navigatorMode = mode.rawValue
        positions[paperID.uuidString] = position
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(positions) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

enum PDFNavigatorMode: String, CaseIterable, Identifiable {
    case outline, thumbnails
    var id: String { rawValue }
    var title: String { self == .outline ? "目录" : "缩略图" }
}

enum PDFZoomMode { case custom, fitWidth, fitPage }

/// One document and one native view per reader. Navigation controls never reload the attachment.
@MainActor
final class PDFReaderController: NSObject, ObservableObject, @preconcurrency PDFViewDelegate {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?
    @Published private(set) var isLocked = false
    @Published private(set) var passwordError: String?
    @Published private(set) var pageCount = 0
    @Published private(set) var currentPage = 1
    @Published private(set) var scaleFactor: CGFloat = 1
    @Published private(set) var zoomMode: PDFZoomMode = .fitWidth
    @Published private(set) var selectedExcerpt: PDFTextExcerpt?
    @Published private(set) var showsNavigator = true
    @Published private(set) var navigatorMode: PDFNavigatorMode = .thumbnails
    @Published private(set) var matchCount = 0
    @Published private(set) var selectedMatchIndex: Int?
    @Published private(set) var isSearching = false
    @Published private(set) var searchQuery = ""

    private(set) weak var pdfView: PDFView?
    var onOpenURL: (URL) -> Void = { _ in }
    private var paperID: UUID?
    private var sourceURL: URL?
    private var readingPositionStore: PDFReadingPositionStore?
    private var loadGeneration = UUID()
    private var pendingSave: DispatchWorkItem?
    private var pendingSearch: DispatchWorkItem?
    private var pendingMatchPublication: DispatchWorkItem?
    private var searchSession: PDFReaderSearchSession?
    private var matches: [PDFSelection] = []
    private var isRestoringPosition = false
    private var isApplyingZoom = false
    private var observerTokens: [NSObjectProtocol] = []

    var canNavigate: Bool { document != nil && !isLocked && pageCount > 0 }
    var canSearch: Bool { canNavigate && document?.allowsCopying == true }
    var hasOutline: Bool { canNavigate && (document?.outlineRoot?.numberOfChildren ?? 0) > 0 }

    func attach(_ view: PDFView) {
        guard pdfView !== view else { return }
        removeObservers()
        pdfView = view
        view.delegate = self
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysAsBook = false
        view.displaysPageBreaks = true
        view.autoScales = false
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        view.backgroundColor = .underPageBackgroundColor
        if let document { view.document = document }
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewVisiblePagesChanged, .PDFViewScaleChanged] {
            observerTokens.append(center.addObserver(forName: name, object: view, queue: .main) { [weak self] notification in
                Task { @MainActor in self?.readingPositionDidChange(notification) }
            })
        }
        observerTokens.append(center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateSelection() }
        })
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.pdfView === view else { return }
            if let clipView = self.findScrollView(in: view)?.contentView {
                clipView.postsBoundsChangedNotifications = true
                self.observerTokens.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.capturePosition() }
                })
            }
            if self.document != nil { self.restorePosition() }
        }
    }

    func detach(_ view: PDFView) {
        guard pdfView === view else { return }
        capturePosition(immediately: true)
        cancelSearch(clearQuery: false)
        removeObservers()
        view.delegate = nil
        pdfView = nil
    }

    func open(url: URL?, paperID: UUID, positionStore: PDFReadingPositionStore) async {
        if self.paperID == paperID, sourceURL == url, document != nil { return }
        capturePosition(immediately: true)
        cancelSearch(clearQuery: true)
        let generation = UUID()
        loadGeneration = generation
        self.paperID = paperID
        sourceURL = url
        readingPositionStore = positionStore
        showsNavigator = positionStore.showsThumbnails(for: paperID)
        navigatorMode = PDFNavigatorMode(rawValue: positionStore.position(for: paperID)?.navigatorMode ?? "") ?? .thumbnails
        isRestoringPosition = true
        pdfView?.document = nil
        document = nil
        selectedExcerpt = nil
        pageCount = 0
        currentPage = 1
        loadError = nil
        passwordError = nil
        isLocked = false
        isLoading = true
        guard let url, url.isFileURL else {
            loadError = "这篇文献尚未关联可读取的 PDF 附件。"
            isLoading = false
            isRestoringPosition = false
            return
        }
        // Opening a large attachment happens once, away from the UI thread.
        let loadedDocument = await Task.detached(priority: .userInitiated) { PDFDocument(url: url) }.value
        guard !Task.isCancelled, loadGeneration == generation else { return }
        isLoading = false
        guard let loadedDocument else {
            loadError = "附件路径已失效，或文件不是有效的 PDF。"
            isRestoringPosition = false
            return
        }
        document = loadedDocument
        pdfView?.document = loadedDocument
        // PDFKit can inherit a document's preferred spread after assignment.
        // Reassert the reader's vertical single-page layout so adjacent pages
        // never appear as an unintended two-page spread.
        pdfView?.displayMode = .singlePageContinuous
        pdfView?.displayDirection = .vertical
        pdfView?.displaysAsBook = false
        refreshDocumentState()
        if !isLocked { restorePosition() } else { isRestoringPosition = false }
    }

    func unlock(password: String) -> Bool {
        guard let document, document.isLocked else { return false }
        guard document.unlock(withPassword: password) else {
            passwordError = "密码不正确，请重试。"
            return false
        }
        passwordError = nil
        refreshDocumentState()
        restorePosition()
        return true
    }

    private func refreshDocumentState() {
        isLocked = document?.isLocked ?? false
        pageCount = isLocked ? 0 : (document?.pageCount ?? 0)
        if !isLocked && pageCount == 0 { loadError = "这份 PDF 没有可显示的页面。" }
    }

    func toggleNavigator() {
        showsNavigator.toggle()
        if let paperID { readingPositionStore?.setShowsThumbnails(showsNavigator, for: paperID) }
    }

    func setNavigatorMode(_ mode: PDFNavigatorMode) {
        navigatorMode = mode
        if let paperID { readingPositionStore?.setNavigatorMode(mode, for: paperID) }
    }

    @discardableResult
    func goToPage(_ value: String) -> Bool {
        guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              canNavigate, (1...pageCount).contains(number),
              let page = document?.page(at: number - 1), let pdfView else { return false }
        pdfView.go(to: page)
        currentPage = number
        if zoomMode != .custom { applyFittingZoom() }
        capturePosition()
        return true
    }

    func movePage(by amount: Int) { _ = goToPage(String(currentPage + amount)) }

    func go(to outline: PDFOutline) {
        guard canNavigate else { return }
        if let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination {
            pdfView?.go(to: destination)
        } else if let action = outline.action as? PDFActionURL, let url = action.url {
            openLink(url)
        }
    }

    func setZoom(_ factor: CGFloat) {
        guard canNavigate, factor.isFinite, let pdfView else { return }
        zoomMode = .custom
        isApplyingZoom = true
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(factor, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        scaleFactor = pdfView.scaleFactor
        isApplyingZoom = false
        capturePosition()
    }

    func fit(_ mode: PDFZoomMode) {
        guard canNavigate else { return }
        zoomMode = mode
        applyFittingZoom()
    }

    func viewportDidResize() {
        guard !isRestoringPosition, zoomMode != .custom else { return }
        applyFittingZoom()
    }

    private func applyFittingZoom() {
        guard canNavigate, let pdfView, let page = pdfView.currentPage ?? document?.page(at: 0),
              pdfView.bounds.width > 0, pdfView.bounds.height > 0 else { return }
        let available = findScrollView(in: pdfView)?.contentView.bounds.size ?? pdfView.bounds.size
        let rendered = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page).size
        let oldScale = max(pdfView.scaleFactor, 0.001)
        let pageWidth = abs(rendered.width) / oldScale
        let pageHeight = abs(rendered.height) / oldScale
        guard pageWidth > 0, pageHeight > 0 else { return }
        let widthScale = max(available.width - 24, 1) / pageWidth
        let heightScale = max(available.height - 24, 1) / pageHeight
        let desired = zoomMode == .fitPage ? min(widthScale, heightScale) : widthScale
        let factor = min(max(desired, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        isApplyingZoom = true
        pdfView.autoScales = false
        if abs(pdfView.scaleFactor - factor) > 0.002 { pdfView.scaleFactor = factor }
        scaleFactor = pdfView.scaleFactor
        isApplyingZoom = false
    }

    func search(_ query: String) {
        cancelSearch(clearQuery: false)
        searchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSearch else { return }
        isSearching = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.searchQuery == query, let document = self.document, self.canSearch else { return }
            let session = PDFReaderSearchSession(owner: self)
            self.searchSession = session
            document.delegate = session
            document.beginFindString(trimmed, withOptions: [.caseInsensitive])
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    func cancelSearch(clearQuery: Bool = true) {
        pendingSearch?.cancel()
        pendingSearch = nil
        pendingMatchPublication?.cancel()
        pendingMatchPublication = nil
        searchSession = nil
        document?.delegate = nil
        document?.cancelFindString()
        matches.removeAll()
        matchCount = 0
        selectedMatchIndex = nil
        isSearching = false
        pdfView?.highlightedSelections = nil
        if clearQuery { searchQuery = "" }
    }

    fileprivate func found(_ match: PDFSelection, session: PDFReaderSearchSession) {
        guard searchSession === session, let document,
              match.pages.first?.document === document else { return }
        matches.append(match)
        // Publish at most ten times per second, even for a term with thousands of matches.
        if pendingMatchPublication == nil {
            let work = DispatchWorkItem { [weak self, weak session] in
                guard let self, let session, self.searchSession === session else { return }
                self.pendingMatchPublication = nil
                self.matchCount = self.matches.count
            }
            pendingMatchPublication = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
    }

    fileprivate func searchFinished(session: PDFReaderSearchSession) {
        guard searchSession === session else { return }
        pendingMatchPublication?.cancel()
        pendingMatchPublication = nil
        matchCount = matches.count
        isSearching = false
        if selectedMatchIndex == nil, !matches.isEmpty { revealMatch(at: 0) }
    }

    func moveMatch(by amount: Int) {
        guard !matches.isEmpty else { return }
        let previous = selectedMatchIndex ?? (amount >= 0 ? -1 : 0)
        let next = (previous + amount % matches.count + matches.count) % matches.count
        revealMatch(at: next)
    }

    private func revealMatch(at index: Int) {
        guard matches.indices.contains(index), let pdfView else { return }
        selectedMatchIndex = index
        let match = matches[index]
        match.color = .systemYellow.withAlphaComponent(0.5)
        // Highlighting does not replace a manually selected evidence excerpt.
        pdfView.highlightedSelections = [match]
        pdfView.go(to: match)
    }

    private func restorePosition() {
        guard canNavigate, let pdfView else { isRestoringPosition = false; return }
        isRestoringPosition = true
        let generation = loadGeneration
        // PDFKit needs a layout pass before destination restoration is reliable.
        DispatchQueue.main.async { [weak self, weak pdfView] in
            guard let self, let pdfView, self.pdfView === pdfView, self.loadGeneration == generation else { return }
            pdfView.layoutSubtreeIfNeeded()
            if let paperID = self.paperID, let position = self.readingPositionStore?.position(for: paperID),
               position.scaleFactor.isFinite, position.scaleFactor > 0,
               position.pointX.isFinite, position.pointY.isFinite,
               (0..<self.pageCount).contains(position.pageIndex),
               let page = self.document?.page(at: position.pageIndex) {
                self.zoomMode = .custom
                pdfView.scaleFactor = min(max(position.scaleFactor, pdfView.minScaleFactor), pdfView.maxScaleFactor)
                pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: position.pointX, y: position.pointY)))
                self.currentPage = position.pageIndex + 1
            } else {
                self.zoomMode = .fitWidth
                self.applyFittingZoom()
            }
            self.scaleFactor = pdfView.scaleFactor
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.isRestoringPosition = false
            }
        }
    }

    func capturePosition(immediately: Bool = false) {
        guard !isRestoringPosition, canNavigate else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pdfView = self.pdfView, let document = self.document,
                  let paperID = self.paperID, let destination = pdfView.currentDestination,
                  let page = destination.page else { return }
            let index = document.index(for: page)
            guard (0..<document.pageCount).contains(index) else { return }
            self.readingPositionStore?.setPosition(pageIndex: index, point: destination.point, scaleFactor: pdfView.scaleFactor, for: paperID)
        }
        pendingSave = work
        if immediately { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work) }
    }

    private func readingPositionDidChange(_ notification: Notification) {
        guard let pdfView, let document, canNavigate else { return }
        if let page = pdfView.currentPage {
            let index = document.index(for: page)
            if (0..<pageCount).contains(index) { currentPage = index + 1 }
        }
        if notification.name == .PDFViewScaleChanged, !isApplyingZoom, !isRestoringPosition,
           abs(scaleFactor - pdfView.scaleFactor) > 0.002 { zoomMode = .custom }
        scaleFactor = pdfView.scaleFactor
        capturePosition()
    }

    private func updateSelection() {
        guard let selection = pdfView?.currentSelection, let document, document.allowsCopying else {
            selectedExcerpt = nil
            return
        }
        let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { selectedExcerpt = nil; return }
        let pages = selection.pages.map { document.index(for: $0) }.filter { (0..<pageCount).contains($0) }.sorted()
        guard let first = pages.first, let last = pages.last else { selectedExcerpt = nil; return }
        let locator = first == last ? "第 \(first + 1) 页" : "第 \(first + 1)–\(last + 1) 页"
        selectedExcerpt = PDFTextExcerpt(text: text, locator: locator)
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews { if let found = findScrollView(in: child) { return found } }
        return nil
    }

    private func removeObservers() {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens.removeAll()
        pendingSave?.cancel()
        pendingSave = nil
    }

    private func openLink(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        onOpenURL(url)
    }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { openLink(url) }
}

@MainActor
private final class PDFReaderSearchSession: NSObject, @preconcurrency PDFDocumentDelegate {
    private weak var owner: PDFReaderController?
    init(owner: PDFReaderController) { self.owner = owner }
    func didMatchString(_ instance: PDFSelection) { owner?.found(instance, session: self) }
    func documentDidEndDocumentFind(_ notification: Notification) { owner?.searchFinished(session: self) }
}
