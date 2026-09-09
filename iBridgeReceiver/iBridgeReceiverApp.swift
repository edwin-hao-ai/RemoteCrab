import SwiftUI

@main
struct iBridgeReceiverApp: App {

    @StateObject private var session = ReceiverSession()

    var body: some Scene {
        // Preview window — full live feed.
        Window("iBridge Preview", id: "preview") {
            PreviewWindow()
                .environmentObject(session)
                .frame(minWidth: 640, minHeight: 400)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 800, height: 600)

        // Floating control panel.
        Window("iBridge Control Panel", id: "controls") {
            ControlPanelView()
                .environmentObject(session)
                .frame(width: 380, height: 580)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)
        .windowStyle(.hiddenTitleBar)

        // Menu bar popover — the polished V0.2 design.
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(session)
                .frame(width: 320)
        } label: {
            MenuBarIcon()
                .environmentObject(session)
                .frame(width: 22, height: 18)
        }
        .menuBarExtraStyle(.window)
    }
}