import SwiftUI
import AppKit

@main
struct AgentBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = MissionControlViewModel()

    var body: some Scene {
        WindowGroup("AgentBox") {
            RootView(viewModel: viewModel)
                .preferredColorScheme(.dark)
                .task {
                    await viewModel.bootstrapIfNeeded()
                }
        }
        .windowResizability(.contentMinSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
