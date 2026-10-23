import SwiftUI

@main
struct KubaControlApp: App {
    @StateObject private var bluetooth: BluetoothManager
    @StateObject private var profiles: ProfileStore
    @StateObject private var controller: HeadsetController

    init() {
        let bt = BluetoothManager()
        let store = ProfileStore()
        _bluetooth = StateObject(wrappedValue: bt)
        _profiles = StateObject(wrappedValue: store)
        _controller = StateObject(wrappedValue: HeadsetController(bluetooth: bt, profiles: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bluetooth)
                .environmentObject(profiles)
                .environmentObject(controller)
                .tint(.orange)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Fone", systemImage: "earbuds") }
            EqualizerView()
                .tabItem { Label("Equalizador", systemImage: "slider.vertical.3") }
            TouchControlsView()
                .tabItem { Label("Toques", systemImage: "hand.tap") }
            FirmwareView()
                .tabItem { Label("Firmware", systemImage: "cpu") }
            AdvancedView()
                .tabItem { Label("Avançado", systemImage: "wrench.and.screwdriver") }
        }
    }
}
