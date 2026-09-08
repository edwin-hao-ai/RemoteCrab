import SwiftUI

/// Custom menu-bar icon — `ImageRenderer` would have been easier but
/// we want pixel-perfect control at small sizes.
struct MenuBarIcon: View {
    let state: ReceiverSession.State

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
    }

    private var iconName: String {
        switch state {
        case .searching:    return "iphone.gen3.slash"
        case .connecting:   return "iphone.gen3"
        case .streaming:    return "iphone.gen3.radiowaves.left.and.right"
        case .error:        return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch state {
        case .searching, .connecting: return .secondary
        case .streaming:              return .accentColor
        case .error:                  return .red
        }
    }
}

/// The dropdown that appears when the menu-bar icon is clicked.
struct MenuBarMenu: View {
    @ObservedObject var session: ReceiverSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(session.state.message) { } .disabled(true)
        Divider()
        Button("Open Preview Window") { openWindow(id: "preview") }
        Button("Open Control Panel") { openWindow(id: "controls") }
        Divider()
        Button("Quit iBridge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}