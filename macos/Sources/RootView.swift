import SwiftUI
import WebKit

/// The whole window: the library, or a scene in the editor. The editor's web
/// view stays mounted underneath the library so the page keeps running.
struct RootView: View {
    @ObservedObject var ws: Workspace
    let webView: WKWebView

    var body: some View {
        let editing = ws.openSceneId != nil
        ZStack {
            EditorView(ws: ws, webView: webView)
                .opacity(editing ? 1 : 0)
                .allowsHitTesting(editing)
            if !editing {
                LibraryView(ws: ws)
                    .contentShape(.rect)
                    .transition(.opacity)
            }
        }
        .animation(Chrome.panelSlide, value: editing)
        .background {
            if ws.presenting { Color.black } else { WindowGlass() }
        }
        .buttonBorderShape(.capsule)
        .frame(minWidth: 760, minHeight: 480)
    }
}
