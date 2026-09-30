import AppKit
import SwiftUI

final class ResearchOSAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let iconURL = Bundle.main.url(forResource: "ResearchOS", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

@main
struct ResearchOSApp: App {
    @NSApplicationDelegateAdaptor(ResearchOSAppDelegate.self) private var appDelegate
    @StateObject private var store = ResearchStore()

    var body: some Scene {
        WindowGroup("ResearchOS") {
            ResearchRootView(store: store)
                .frame(minWidth: 900, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 820)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))

        Settings {
            ResearchSettingsView(store: store)
        }
    }
}
