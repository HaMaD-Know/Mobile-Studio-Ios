import SwiftUI
import WebKit
import StudioCore

/// Settings (port of ui/SettingsDialog.kt + ui/AccountUi.kt): Roblox account, Open Cloud key,
/// editor preferences, about.
struct SettingsView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var account = AccountStore.shared
    @ObservedObject var theme = ThemeStore.shared
    @State private var keyDraft = ""
    @State private var showSignIn = false
    @State private var showAbout = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(StudioTheme.builtIn) { t in ThemeTile(theme: t, selected: theme.current == t) { theme.current = t } }
                        }
                        .padding(.vertical, 4)
                    }
                } header: { Text("Appearance") }
                Section("Camera") {
                    Picker("Fly speed", selection: $store.flyMul) {
                        ForEach(FlySpeeds.steps, id: \.self) { Text(FlySpeeds.label($0)).tag($0) }
                    }
                }
                Section {
                    if account.isSignedIn {
                        LabeledContent("Signed in as", value: account.userName ?? "Roblox user")
                        Button("Sign Out", role: .destructive) {
                            Task { await RobloxWeb.logout(); account.signOut() }
                        }
                    } else {
                        Button("Sign In to Roblox…", systemImage: "person.crop.circle") { showSignIn = true }
                    }
                } header: { Text("Account") } footer: {
                    Text("Signing in lets the app download assets that need an account and list your experiences.")
                }
                Section {
                    SecureField("Open Cloud API key", text: $keyDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("Save Key") { account.setApiKey(keyDraft) }.disabled(keyDraft.isEmpty)
                        Spacer()
                        if account.apiKey != nil { Button("Remove", role: .destructive) { account.setApiKey(nil); keyDraft = "" } }
                    }
                } header: { Text("Open Cloud") } footer: {
                    Text(account.apiKey == nil ? "Needed to save or publish places to Roblox. Create one at create.roblox.com → Open Cloud → API Keys with the universe-places write and asset read permissions."
                                               : "An API key is saved on this device (in the Keychain).")
                }
                Section("Play") {
                    Toggle("Use My Roblox Avatar", isOn: Binding(
                        get: { AvatarLoader.mode == .account },
                        set: { AvatarLoader.mode = $0 ? .account : .classic }))
                        .disabled(!account.isSignedIn)
                }
                Section("Editor") {
                    Toggle("Snap to Grid", isOn: $store.snapEnabled)
                    Picker("Move Snap", selection: $store.moveSnap) {
                        ForEach([0.1, 0.25, 0.5, 1, 2, 4] as [Float], id: \.self) { Text("\(String(format: "%g", $0)) studs").tag($0) }
                    }
                    Picker("Rotate Snap", selection: $store.rotSnapDegrees) {
                        ForEach([1, 5, 15, 45, 90] as [Float], id: \.self) { Text("\(Int($0))°").tag($0) }
                    }
                    Toggle("Select Inside Models", isOn: $store.selectInsideModels)
                }
                Section("Storage") {
                    Button("Clear Downloaded Assets", role: .destructive) { AssetCache.shared.clear(); store.showToast("Asset cache cleared") }
                }
                Section {
                    Button("About Mobile Studio") { showAbout = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Th.panel)
            .navigationTitle("Studio Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showSignIn) { SignInView() }
            .alert("Mobile Studio", isPresented: $showAbout) { Button("OK") {} } message: {
                Text("An iOS port of the Mobile Studio Android app. Scripting runs on the open-source Luau VM.")
            }
        }
    }
}

/// Roblox sign-in in a web view; the session cookie is read from the web view's cookie store
/// (AccountUi.kt's WebView flow). The user types their own credentials on roblox.com.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Sign in on roblox.com, then you'll return here automatically."

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(status).font(.footnote).foregroundStyle(.secondary).padding(8)
                RobloxLoginWebView { cookie in
                    status = "Signed in, finishing…"
                    AccountStore.shared.setSession(cookie: cookie, userName: nil, userId: nil)
                    Task {
                        if let u = try? await RobloxWeb.currentUser() {
                            AccountStore.shared.setSession(cookie: cookie, userName: u.name, userId: u.id)
                        }
                        dismiss()
                    }
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct RobloxLoginWebView: UIViewRepresentable {
    let onCookie: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookie) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: URL(string: "https://www.roblox.com/login")!))
        return wv
    }
    func updateUIView(_ v: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCookie: (String) -> Void
        var done = false
        init(_ f: @escaping (String) -> Void) { onCookie = f }
        func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
            wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done, let c = cookies.first(where: { $0.name == ".ROBLOSECURITY" && $0.domain.contains("roblox.com") }) else { return }
                self.done = true
                DispatchQueue.main.async { self.onCookie(c.value) }
            }
        }
    }
}

/// Toolbox (port of ui/ToolboxPanel.kt): search the Creator Store and insert models, decals, meshes, audio.
struct ToolboxView: View {
    @ObservedObject var store: StudioStore
    @State private var query = ""
    @State private var category: RobloxWeb.Category = .models
    @State private var items: [RobloxWeb.Item] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?
    @State private var freeOnly = false
    @State private var needsAuth = false
    @State private var showSignIn = false
    @State private var statusBanner: String?
    @State private var audioSearchTrigger = 0
    @Environment(\.dismiss) private var dismiss

    @State private var section = "Creator Store"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["Creator Store", "Parts"], id: \.self) { t in
                    Button { section = t } label: {
                        Text(t).font(.system(size: 15)).foregroundStyle(section == t ? Th.text : Th.dim)
                            .padding(.horizontal, 12).frame(height: 38)
                            .background(section == t ? Th.panel : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .background(Th.header)
            if section == "Parts" { partsGrid } else { store_ }
        }
        .background(Th.panel)
        .sheet(isPresented: $showSignIn) { SignInView() }
        .task { await load(more: false) }
    }

    private var partsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                partTile("Block", "cube.fill") { store.insertPart(shape: 1) }
                partTile("Sphere", "circle.fill") { store.insertPart(shape: 0) }
                partTile("Cylinder", "cylinder.fill") { store.insertPart(shape: 2) }
                partTile("Wedge", "triangle.fill") { store.insertPart(shape: 3) }
                partTile("Corner", "pyramid.fill") { store.insertPart(shape: 4) }
                partTile("Truss", "square.grid.3x3") { store.insertObject("TrussPart") }
                partTile("Spawn", "flag.fill") { store.insertObject("SpawnLocation") }
                partTile("MeshPart", "cube.transparent.fill") { store.insertObject("MeshPart") }
            }
            .padding(10)
        }
    }

    private func partTile(_ name: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 34)).foregroundStyle(Color(white: 0.8)).frame(height: 56)
                Text(name).font(.system(size: 13)).foregroundStyle(Th.text)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Th.card, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var store_: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("", text: $query, prompt: Text(category == .audio ? "Search audio" : "Search the Creator Store").foregroundStyle(Th.dim))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit {
                        if category == .audio { audioSearchTrigger += 1 }
                        else { Task { await load(more: false) } }
                    }
                    .studioField()
                PanelIconButton(icon: "magnifyingglass") {
                    if category == .audio { audioSearchTrigger += 1 }
                    else { Task { await load(more: false) } }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(RobloxWeb.Category.allCases) { c in
                        Chip(label: c == .decals ? "Images" : c.label, selected: category == c) {
                            category = c
                            if c != .audio {
                                store.audio.stopPreview()
                                Task { await load(more: false) }
                            }
                        }
                    }
                    if category != .audio {
                        Divider().frame(height: 18)
                        Chip(label: "Free", selected: freeOnly) {
                            freeOnly.toggle()
                            Task { await load(more: false) }
                        }
                    }
                }
            }
            if category == .audio {
                AudioBrowserView(store: store, query: $query, searchTrigger: audioSearchTrigger) { item, parent in
                    let target = parent ?? store.selection.first ?? store.model.workspace
                    let s = store.session.insertObject("Sound", into: target)
                    s.name = item.title.isEmpty ? item.name : item.title
                    s.set("SoundId", .string("rbxassetid://\(item.id)"))
                    statusBanner = "Inserted \(s.name)"
                    store.showToast("Inserted \(s.name)")
                }
            } else {
                if let statusBanner {
                    Text(statusBanner)
                        .font(.system(size: 12))
                        .foregroundStyle(Th.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error {
                    HStack(spacing: 8) {
                        Text(error).font(.system(size: 12)).foregroundStyle(Th.error)
                        if needsAuth {
                            Button("Sign In") { showSignIn = true }
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Spacer()
                    }
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                        ForEach(items) { it in
                            Button { insert(it) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    AsyncImage(url: it.thumbnail) { img in img.resizable().scaledToFit() } placeholder: { Th.hover }
                                        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                                        .background(Th.card)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(it.name).font(.system(size: 12)).foregroundStyle(Th.text).lineLimit(2)
                                    HStack(spacing: 3) {
                                        Text(it.creator).font(.system(size: 11)).foregroundStyle(Th.dim).lineLimit(1)
                                        if it.verified {
                                            Image(systemName: "checkmark.seal.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(Th.accent)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if cursor != nil && !loading {
                            Chip(label: "More") { Task { await load(more: true) } }
                        }
                    }
                    if loading { ProgressView().padding() }
                }
            }
        }
        .padding(8)
    }

    private func load(more: Bool) async {
        loading = true; error = nil; needsAuth = false
        defer { loading = false }
        do {
            let (found, next) = try await RobloxWeb.search(query, category, cursor: more ? cursor : nil, freeOnly: freeOnly)
            items = more ? items + found : found
            cursor = next
        } catch { self.error = error.localizedDescription }
    }

    private func insert(_ it: RobloxWeb.Item) {
        error = nil; needsAuth = false
        func handleAuthError(_ err: Error) {
            statusBanner = nil
            switch err {
            case AssetCache.AssetError.authRequired,
                 AssetCache.AssetError.http(401),
                 AssetCache.AssetError.http(403):
                self.error = "Sign in to Roblox to insert \(it.name)."
                self.needsAuth = true
            default:
                self.error = "Couldn't insert \(it.name): \(err.localizedDescription)"
            }
        }
        switch category {
        case .models:
            statusBanner = "Downloading \(it.name)…"
            store.showToast("Downloading \(it.name)…")
            Task {
                do {
                    let data = try await AssetCache.shared.download(it.id)
                    let doc = try RbxFile.read(data)
                    store.session.insertDocument(doc)
                    let ws = store.model.workspace
                    let wsParts = doc.roots.filter { $0.isDescendant(of: ws) }
                        .flatMap { [$0] + $0.descendants() }
                        .filter { $0.isA("BasePart") }
                    if !wsParts.isEmpty { ModelMathApp.moveTo(wsParts, store.spawnPoint()) }
                    statusBanner = "Inserted \(it.name)"
                    store.showToast("Inserted \(it.name)")
                } catch { handleAuthError(error) }
            }
        case .decals:
            let texUri = "rbxassetid://\(it.id)"
            if let target = store.selection.first(where: { $0.isA("BasePart") }) {
                let d = store.session.insertObject("Decal", into: target)
                d.set("Texture", .string(texUri))
                d.name = it.name
            } else {
                store.session.undo.begin("Insert Decal")
                let host = store.session.insertObject("Part", into: store.model.workspace, at: store.spawnPoint() + Vector3(0, 3, 0))
                host.name = it.name
                host.set("size", .vector3(Vector3(6, 6, 0.4)))
                host.set("Anchored", .bool(true))
                let d = store.session.insertObject("Decal", into: host)
                d.set("Texture", .string(texUri))
                d.name = it.name
                store.session.select([host])
                store.session.undo.commit()
            }
            statusBanner = "Inserted \(it.name)"
            store.showToast("Inserted \(it.name)")
        case .meshes:
            statusBanner = "Downloading \(it.name)…"
            store.showToast("Downloading \(it.name)…")
            Task {
                do {
                    let data = try await AssetCache.shared.download(it.id)
                    if let doc = try? RbxFile.read(data), !doc.roots.isEmpty {
                        store.session.insertDocument(doc)
                        let ws = store.model.workspace
                        let wsParts = doc.roots.filter { $0.isDescendant(of: ws) }
                            .flatMap { [$0] + $0.descendants() }
                            .filter { $0.isA("BasePart") }
                        if !wsParts.isEmpty { ModelMathApp.moveTo(wsParts, store.spawnPoint()) }
                    } else {
                        let parsed = try? MeshFile.parse(data)
                        let size: Vector3
                        if let m = parsed, m.max.count >= 3, m.min.count >= 3 {
                            size = Vector3(
                                max(0.2, min(100, m.max[0] - m.min[0])),
                                max(0.2, min(100, m.max[1] - m.min[1])),
                                max(0.2, min(100, m.max[2] - m.min[2]))
                            )
                        } else {
                            size = Vector3(4, 4, 4)
                        }
                        store.session.undo.begin("Insert Mesh")
                        let mp = store.session.insertObject("MeshPart", into: store.model.workspace, at: store.spawnPoint() + Vector3(0, size.y / 2, 0))
                        mp.name = it.name
                        mp.set("size", .vector3(size))
                        mp.set("Anchored", .bool(true))
                        mp.set("MeshId", .string("rbxassetid://\(it.id)"))
                        store.session.undo.commit()
                    }
                    statusBanner = "Inserted \(it.name)"
                    store.showToast("Inserted \(it.name)")
                } catch { handleAuthError(error) }
            }
        case .audio:
            let s = store.session.insertObject("Sound", into: store.model.workspace)
            s.name = it.name
            s.set("SoundId", .string("rbxassetid://\(it.id)"))
            statusBanner = "Inserted \(it.name)"
            store.showToast("Inserted \(it.name)")
        }
    }
}

/// Move a set of parts so their bottom-centre lands on `p`.
enum ModelMathApp {
    static func moveTo(_ parts: [Instance], _ p: Vector3) {
        var lo = Vector3(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude), hi = -lo
        for q in parts {
            let cf = PartData.cframe(q), h = PartData.size(q) * 0.5
            let ext = Vector3(
                abs(cf.r00) * h.x + abs(cf.r01) * h.y + abs(cf.r02) * h.z,
                abs(cf.r10) * h.x + abs(cf.r11) * h.y + abs(cf.r12) * h.z,
                abs(cf.r20) * h.x + abs(cf.r21) * h.y + abs(cf.r22) * h.z
            )
            lo = lo.min(cf.position - ext); hi = hi.max(cf.position + ext)
        }
        let delta = Vector3(p.x - (lo.x + hi.x) / 2, (p.y + 0.2) - lo.y, p.z - (lo.z + hi.z) / 2)
        for q in parts { PartData.setCFrame(q, PartData.cframe(q) + delta) }
        var shiftedModels = Set<ObjectIdentifier>()
        for q in parts {
            var cur = q.parent
            while let m = cur {
                if m.isA("Model"), shiftedModels.insert(ObjectIdentifier(m)).inserted {
                    if case .optionalCFrame(let opt)? = m.props["WorldPivotData"], let wp = opt.value {
                        m.set("WorldPivotData", .optionalCFrame(OptionalCFrame(wp + delta)))
                    }
                }
                cur = m.parent
            }
        }
    }
}

/// Open a place from the user's Roblox experiences, or publish the current place to one
/// (port of the cloud parts of ui/StartScreen.kt + core/Studio publishing).
struct CloudPlacesView: View {
    enum Mode { case open, publish }
    @ObservedObject var store: StudioStore
    let mode: Mode
    @State private var games: [RobloxWeb.Game] = []
    @State private var places: [Int64: [RobloxWeb.Place]] = [:]
    @State private var placeIdText = ""
    @State private var busy = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Place ID", text: $placeIdText).keyboardType(.numberPad)
                        Button(mode == .open ? "Open" : "Publish") {
                            if let id = Int64(placeIdText) { act(universe: 0, place: id, name: "Place \(id)") }
                        }
                        .disabled(Int64(placeIdText) == nil || busy)
                    }
                } footer: { Text("Or pick one of your experiences below.") }
                if let message { Section { Text(message).font(.footnote) } }
                Section("Your Experiences") {
                    if !AccountStore.shared.isSignedIn { Text("Sign in (Settings → Account) to list your experiences.").foregroundStyle(.secondary) }
                    ForEach(games) { g in
                        DisclosureGroup(g.name) {
                            ForEach(places[g.id] ?? []) { p in
                                Button(p.name) { act(universe: g.id, place: p.id, name: p.name) }.disabled(busy)
                            }
                        }
                        .task { if places[g.id] == nil { places[g.id] = (try? await RobloxWeb.places(g.id)) ?? [] } }
                    }
                }
            }
            .overlay { if busy { ProgressView() } }
            .task {
                guard AccountStore.shared.isSignedIn else { return }
                do { games = try await RobloxWeb.userGames() } catch { message = error.localizedDescription }
            }
            .navigationTitle(mode == .open ? "Open from Roblox" : "Publish to Roblox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func act(universe: Int64, place: Int64, name: String) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .open:
                    let data = try await RobloxWeb.downloadPlace(place)
                    store.openData(data, name: name, cloud: (universe, place))
                    dismiss()
                case .publish:
                    let v = try await RobloxWeb.publish(universe: universe, place: place, bytes: store.placeData(), publish: true)
                    store.cloudPlace = (universe, place)
                    store.showToast("Published (\(v))")
                    dismiss()
                }
            } catch { message = error.localizedDescription }
        }
    }
}

/// Mini preview of a theme (SettingsDialog's theme cards).
struct ThemeTile: View {
    let theme: StudioTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    Color(argb: theme.bg)
                    VStack(alignment: .leading, spacing: 0) {
                        Color(argb: theme.topbar).frame(height: 12)
                            .overlay(alignment: .leading) { Color(argb: theme.accent).frame(width: 16, height: 5).padding(.leading, 6) }
                        HStack(alignment: .top) {
                            Spacer()
                            VStack(alignment: .leading, spacing: 4) {
                                Color(argb: theme.select).frame(width: 34, height: 8)
                                Color(argb: theme.text).frame(width: 22, height: 3)
                                Color(argb: theme.text).frame(width: 18, height: 3)
                            }
                            .padding(.top, 12).padding(.trailing, 6)
                        }
                    }
                }
                .frame(width: 110, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Th.accent : Color.clear, lineWidth: 2.5).padding(-4))
                Text(theme.name).font(.system(size: 13)).foregroundStyle(Th.text)
            }
            .padding(4)
        }
        .buttonStyle(.plain)
    }
}
