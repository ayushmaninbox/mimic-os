import SwiftUI

@main
struct MimicOSApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("MimicOS", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .task { await model.onAppear() }
                .onDisappear { model.onDisappear() }
        }
        .windowResizability(.contentMinSize)
    }
}
