import SwiftUI

/// Toolbox dock window (interim: wraps the existing Creator Store search in a dock panel).
struct ToolboxPanel: View {
    @ObservedObject var store: StudioStore
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(icon: "briefcase.fill", tint: Th.error, title: "Toolbox", onClose: onClose)
            ToolboxView(store: store)
        }
        .background(Th.panel)
    }
}

/// App icon tile used on the start page and About.
struct AppBadge: View {
    var size: CGFloat = 36
    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}
