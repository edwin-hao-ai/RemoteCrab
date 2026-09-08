import SwiftUI

@main
struct iBridgeReceiverApp: App {

    @StateObject private var session = ReceiverSession()

    var body: some Scene {
        // Main preview window — hidden by default, shown from the menu bar.
        Window("iBridge Preview", id: "preview") {
            PreviewWindow()
                .environmentObject(session)
                .frame(minWidth: 640, minHeight: 400)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 800, height: 600)

        // Floating control panel that can stay above other windows.
        Window("iBridge Controls", id: "controls") {
            ControlPanelView()
                .environmentObject(session)
                .frame(width: 320, height: 380)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)

        // Menu bar icon + dropdown.
        MenuBarExtra {
            MenuBarMenu(session: session)
        } label: {
            MenuBarIcon(state: session.state)
        }
        .menuBarExtraStyle(.window)
    }
}