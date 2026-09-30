import SwiftUI
import WebKit

struct InAppBrowserWorkspace: View {
    let initialURL: URL
    let onClose: () -> Void
    let onTitleChange: (String) -> Void
    @StateObject private var controller = InAppBrowserController()
    @State private var address = ""
    @State private var pageTitle = "网页"
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            ResearchGlassContainer {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        navigationTools
                        addressBar.frame(minWidth: 160)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        navigationTools
                        addressBar
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            EmbeddedWebBrowser(
                initialURL: initialURL,
                controller: controller,
                address: $address,
                title: $pageTitle,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $isLoading
            )
        }
        .background(ResearchPalette.window)
        .navigationTitle(pageTitle)
        .onChange(of: pageTitle) { _, newValue in
            onTitleChange(newValue)
        }
    }

    private var navigationTools: some View {
        HStack(spacing: 3) {
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .keyboardShortcut(.cancelAction)
            .help("关闭网页，返回文稿")
            .accessibilityLabel("关闭网页")
            Divider().frame(height: 16).padding(.horizontal, 3)
            Button { controller.goBack() } label: {
                Image(systemName: "chevron.backward").frame(width: 28, height: 28)
            }
            .disabled(!canGoBack)
            .help("后退")
            .accessibilityLabel("后退")
            Button { controller.goForward() } label: {
                Image(systemName: "chevron.forward").frame(width: 28, height: 28)
            }
            .disabled(!canGoForward)
            .help("前进")
            .accessibilityLabel("前进")
            Button { controller.reload() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }
            .help("刷新网页")
            .accessibilityLabel("刷新网页")
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.borderless)
        .padding(5)
        .researchGlassSurface()
        .fixedSize()
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("输入网址", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("网页地址")
                .onSubmit { openAddress() }
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .opacity(isLoading ? 1 : 0)
                .accessibilityHidden(!isLoading)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .researchGlassSurface()
    }

    private func openAddress() {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        controller.load(url)
    }
}

@MainActor
final class InAppBrowserController: ObservableObject {
    weak var webView: WKWebView?
    func attach(_ webView: WKWebView) { self.webView = webView }
    func load(_ url: URL) { webView?.load(URLRequest(url: url)) }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

private struct EmbeddedWebBrowser: NSViewRepresentable {
    let initialURL: URL
    let controller: InAppBrowserController
    @Binding var address: String
    @Binding var title: String
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        controller.attach(webView)
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller.attach(webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: EmbeddedWebBrowser
        init(parent: EmbeddedWebBrowser) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            updateState(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            updateState(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            updateState(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            updateState(webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            decisionHandler(["http", "https", "about"].contains(scheme) ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func updateState(_ webView: WKWebView) {
            parent.address = webView.url?.absoluteString ?? ""
            parent.title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? "网页")
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }
    }
}
