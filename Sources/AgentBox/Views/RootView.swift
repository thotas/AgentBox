import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: MissionControlViewModel

    var body: some View {
        TabView {
            MissionControlView(viewModel: viewModel)
                .tabItem {
                    Label("Mission Control", systemImage: "dot.radiowaves.left.and.right")
                }

            SettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .background(Color.black)
    }
}
