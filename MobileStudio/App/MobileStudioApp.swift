import SwiftUI
import UniformTypeIdentifiers
import StudioCore

@main
struct MobileStudioApp: App {
    @StateObject private var store = StudioStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .onOpenURL { store.open($0) }
        }
    }
}

/// Switches between the start page and the editor, and re-renders everything when the theme changes.
struct RootView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var theme = ThemeStore.shared

    var body: some View {
        Group {
            if store.hasDocument && !store.showStart {
                EditorView(store: store)
            } else {
                StartScreen(store: store)
            }
        }
        .id(theme.current.name)
        .preferredColorScheme(theme.current.light ? .light : .dark)
        .tint(Th.accent)
    }
}

/// Start page (port of ui/StartScreen.kt): header with account chip, Home / Recent / My Games
/// tabs, a greeting card, template cards, recent files and a tip.
struct StartScreen: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var account = AccountStore.shared
    @State private var tab = "Home"
    @State private var showImporter = false
    @State private var recents: [URL] = []
    @State private var sheet: StartSheet?

    enum StartSheet: String, Identifiable { case settings, signIn, about; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            Th.border.frame(height: 1)
            Group {
                switch tab {
                case "Recent": ScrollView { recentList(limit: nil).padding(16) }
                case "My Games": CloudPlacesView(store: store, mode: .open)
                default: home
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Th.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let t = store.toast { ToastView(text: t).padding(.bottom, 24) }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .settings: SettingsView(store: store)
            case .signIn: SignInView()
            case .about: AboutView()
            }
        }
        .onAppear { recents = Recents.all() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: UTType.robloxFiles) { r in
            if case .success(let url) = r { store.open(url) }
        }
    }

    // MARK: header & tabs

    private var header: some View {
        HStack(spacing: 10) {
            AppBadge(size: 36)
            Text("Mobile Studio").font(.system(size: 20, weight: .bold)).foregroundStyle(Th.text).lineLimit(1)
            Text("v2.0").font(.system(size: 12)).foregroundStyle(Th.dim)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Th.hover, in: Capsule())
            Spacer(minLength: 4)
            PanelIconButton(icon: "info.circle.fill", tint: Th.info) { sheet = .about }
            PanelIconButton(icon: "gearshape.fill") { sheet = .settings }
            Menu {
                if account.isSignedIn {
                    Text(account.userName ?? "Roblox user")
                    Button("Sign Out", role: .destructive) { Task { await RobloxWeb.logout(); account.signOut() } }
                } else {
                    Button("Sign in with Roblox", systemImage: "person.crop.circle") { sheet = .signIn }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 22))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Th.info)
                    Text(account.isSignedIn ? (account.userName ?? "Account") : "Guest")
                        .font(.system(size: 15)).foregroundStyle(Th.text).lineLimit(1)
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8)).foregroundStyle(Th.dim)
                }
                .padding(.horizontal, 10).frame(height: 36)
                .background(Th.hover, in: Capsule())
            }
        }
        .padding(.horizontal, 12).frame(height: 54)
        .background(Th.topbar.ignoresSafeArea(edges: [.top, .horizontal]))
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tabButton("Home", "house.fill")
                tabButton("Recent", "clock")
                tabButton("My Games", "person.crop.circle.fill")
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 50)
        .background(Th.topbar)
    }

    private func tabButton(_ name: String, _ icon: String) -> some View {
        let on = tab == name
        return Button { tab = name } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(on ? Th.info : Th.text)
                Text(name).font(.system(size: 16, weight: on ? .semibold : .regular)).foregroundStyle(Th.text)
            }
            .padding(.horizontal, 14).frame(height: 38)
            .background(on ? Th.accent.opacity(0.3) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                ForEach(templateSections, id: \.0) { title, items in
                    section(title) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(items) { t in templateCard(t) }
                            }
                        }
                    }
                }
                section("Recent", trailing: recents.isEmpty ? nil : AnyView(
                    Button { tab = "Recent" } label: {
                        Text("See all ›").font(.system(size: 15)).foregroundStyle(Th.info)
                    }.buttonStyle(.plain))) {
                    recentList(limit: 4)
                }
                HStack(spacing: 12) {
                    Image(systemName: "info.circle.fill").font(.system(size: 20)).foregroundStyle(Th.info)
                    Text("Tip: Avatar → Character lets you play as R6 or R15, and Settings → Use My Roblox Avatar plays as your own avatar.")
                        .font(.system(size: 14)).foregroundStyle(Th.text)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Th.card, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning!" : h < 18 ? "Good afternoon!" : "Good evening!"
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 56))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, Th.info)
                    .overlay(Circle().stroke(Th.hover, lineWidth: 3))
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.isSignedIn ? "\(greeting.dropLast()), \(account.userName ?? "")!" : greeting)
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    Text(account.isSignedIn ? "Open one of your Roblox games, or start something new below."
                                            : "Sign in to open your Roblox games, or start something new below.")
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                }
            }
            FlowRow(spacing: 10) {
                if store.hasDocument {
                    pill("Back to place", icon: "arrow.uturn.backward", primary: true) { store.showStart = false }
                }
                pill("New Baseplate", icon: "cube.fill", primary: !store.hasDocument) { store.newPlace(.baseplate) }
                pill("Open File", icon: "folder.fill", primary: false) { showImporter = true }
                if !account.isSignedIn {
                    pill("Sign in", icon: "person.crop.circle.fill", primary: false) { sheet = .signIn }
                } else {
                    pill("My Games", icon: "gamecontroller.fill", primary: false) { tab = "My Games" }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color(argb: -14535287), Color(argb: -12898746)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private func pill(_ title: String, icon: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(primary ? .white : Th.warn)
                Text(title).foregroundStyle(.white)
            }
            .font(.system(size: 16))
            .padding(.horizontal, 18).frame(height: 42)
            .background(primary ? Th.accent : Color.black.opacity(0.3), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func section<C: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Th.text)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }

    private var templateSections: [(String, [PlaceFactory.Template])] {
        let order = [("All Templates", "Start creating"), ("Gameplay", "Gameplay"), ("Theme", "Theme")]
        return order.map { cat, title in
            (title, PlaceFactory.Template.allCases.filter { $0.category == cat })
        }
    }

    private func templateCard(_ t: PlaceFactory.Template) -> some View {
        let look: (Int32, Int32, String) = {
            switch t {
            case .baseplate: return (-11764775, -13874857, "cube.fill")
            case .classic: return (-11625902, -13667502, "dice.fill")
            case .flatTerrain: return (-10580934, -12953048, "mountain.2.fill")
            case .empty: return (-7704623, -11254976, "square.dashed")
            case .obby: return (-2534577, -6933465, "flag.fill")
            case .arena: return (-2061778, -6854116, "shield.lefthalf.filled")
            case .island: return (-13660235, -15118744, "water.waves")
            case .village: return (-7574971, -10996177, "house.fill")
            }
        }()
        return Button { store.newPlace(t) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    LinearGradient(colors: [Color(argb: look.0), Color(argb: look.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: look.2).font(.system(size: 56)).foregroundStyle(Color(white: 0.82))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                }
                .frame(width: 184, height: 150)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Th.text).lineLimit(1)
                    Text(t.subtitle).font(.system(size: 13)).foregroundStyle(Th.dim).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(width: 184, alignment: .leading)
                .background(Th.card)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func recentList(limit: Int?) -> some View {
        let list = limit.map { Array(recents.prefix($0)) } ?? recents
        if list.isEmpty {
            Text("Places and files you open show up here, so you can jump right back in.")
                .font(.system(size: 16)).foregroundStyle(Th.text)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Th.card, in: RoundedRectangle(cornerRadius: 12))
        } else {
            VStack(spacing: 8) {
                ForEach(list, id: \.self) { url in
                    Button { store.open(url) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.fill").foregroundStyle(Color(argb: -11751600)).font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 16)).foregroundStyle(Th.text)
                                Text("On this device").font(.system(size: 13)).foregroundStyle(Th.dim)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(Th.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Wrapping row of buttons (ui/FlowLayout.kt).
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
