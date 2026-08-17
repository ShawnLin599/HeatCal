import SwiftUI

@main
struct HeatCalMockApp: App {
    @StateObject private var store = AppStore.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
