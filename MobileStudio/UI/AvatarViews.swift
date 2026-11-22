import SwiftUI
import StudioCore
import StudioScript

/// Avatar tab dialogs (port of ui/AvatarUi.kt): Rig Builder, Game Settings — Avatar,
/// Playtest Avatar, and Custom Character chooser.

// MARK: - Rig Builder

struct RigBuilderView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var account = AccountStore.shared
    @Environment(\.dismiss) private var dismiss

    private var avatarLabel: String? { AvatarLoader.activeAvatarLabel }

    var body: some View {
        NavigationStack {
            List {
                if store.play != nil {
                    Text("Stop the playtest to insert a rig.")
                        .foregroundStyle(Th.dim)
                } else {
                    Section("Block Rigs") {
                        row("R6 — Block Rig", subtitle: "Classic 6-part Roblox rig", icon: "figure.stand", tint: Th.play) {
                            store.insertRig(r15: false, useAvatar: false)
                            dismiss()
                        }
                        row("R15 — Block Rig", subtitle: "15-part jointed Roblox rig", icon: "figure.walk", tint: Th.play) {
                            store.insertRig(r15: true, useAvatar: false)
                            dismiss()
                        }
                    }
                    if let label = avatarLabel {
                        Section("My Avatar (\(label))") {
                            row("R6 — My Avatar (\(label))", subtitle: "Your avatar's colours, clothing and accessories on an R6 rig",
                                icon: "person.crop.circle.fill", tint: Th.info) {
                                store.insertRig(r15: false, useAvatar: true)
                                dismiss()
                            }
                            row("R15 — My Avatar (\(label))", subtitle: "Your avatar's colours, clothing and accessories on an R15 rig",
                                icon: "person.crop.circle.fill", tint: Th.info) {
                                store.insertRig(r15: true, useAvatar: true)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Th.panel)
            .navigationTitle("Rig Builder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func row(_ title: String, subtitle: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Th.text)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Th.dim)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Game Settings — Avatar

struct GameSettingsView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var account = AccountStore.shared
    @Environment(\.dismiss) private var dismiss

    static let scaleDefs: [(key: String, apiKey: String, label: String, def: NumberRange)] = [
        ("Height", "height", "Height", NumberRange(0.9, 1.05)),
        ("Width", "width", "Width", NumberRange(0.7, 1.0)),
        ("Head", "head", "Head", NumberRange(0.95, 1.0)),
        ("BodyType", "bodyType", "Body type", NumberRange(0.0, 1.0)),
        ("Proportion", "proportion", "Proportions", NumberRange(0.0, 1.0)),
    ]

    @State private var avatarType = 2
    @State private var collision = 0
    @State private var loadAppearance = true
    @State private var minStr: [String: String] = [:]
    @State private var maxStr: [String: String] = [:]
    @State private var syncToRoblox = true
    @State private var saving = false
    @State private var cloudError: String?

    private var canSyncCloud: Bool {
        store.cloudPlace != nil && store.cloudPlace?.0 != 0 && account.isSignedIn
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.play != nil {
                    Text("Stop the playtest to change Game Settings.").foregroundStyle(Th.dim)
                } else {
                    Section {
                        Picker("Avatar Type", selection: $avatarType) {
                            Text("R6").tag(0)
                            Text("R15").tag(1)
                            Text("Player Choice").tag(2)
                        }
                        .pickerStyle(.segmented)
                    } header: { Text("Avatar Type") } footer: {
                        Text("Which body players get in this place. Player Choice uses each player's own setting.")
                    }

                    if avatarType != 0 {
                        Section("Collision") {
                            Picker("Collision", selection: $collision) {
                                Text("Outer Box").tag(0)
                                Text("Inner Box").tag(1)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    Section("Player appearance") {
                        Toggle("Load each player's avatar (clothing, accessories, body)", isOn: $loadAppearance)
                    }

                    Section {
                        ForEach(Self.scaleDefs, id: \.key) { s in
                            HStack(spacing: 8) {
                                Text(s.label).font(.system(size: 14)).foregroundStyle(Th.text)
                                Spacer()
                                TextField("min", text: binding(for: s.key, isMin: true))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 68)
                                    .studioField()
                                Text("–").foregroundStyle(Th.dim)
                                TextField("max", text: binding(for: s.key, isMin: false))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 68)
                                    .studioField()
                            }
                        }
                    } header: { Text("Body scales (R15)") } footer: {
                        Text("Players' body scales are kept between these values.")
                    }

                    if canSyncCloud {
                        Section {
                            Toggle("Also save to \"\(store.fileName)\" on Roblox", isOn: $syncToRoblox)
                        } footer: {
                            Text("Saved in the place (StarterPlayer), so playtests here use it. Roblox games keep these settings on the game itself, so they're synced when you open it.")
                        }
                    } else {
                        Section {
                            EmptyView()
                        } footer: {
                            Text("Saved in the place (StarterPlayer), so playtests here use it.")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Th.panel)
            .navigationTitle("Game Settings — Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }.disabled(store.play != nil)
                    }
                }
            }
            .onAppear(perform: loadCurrent)
            .alert("Saved in the place only", isPresented: Binding(get: { cloudError != nil }, set: { if !$0 { cloudError = nil; dismiss() } })) {
                Button("OK") { cloudError = nil; dismiss() }
            } message: {
                Text(cloudError ?? "")
            }
        }
    }

    private func binding(for key: String, isMin: Bool) -> Binding<String> {
        Binding(
            get: { (isMin ? minStr[key] : maxStr[key]) ?? "" },
            set: { if isMin { minStr[key] = $0 } else { maxStr[key] = $0 } }
        )
    }

    private func fmt(_ f: Float) -> String {
        let s = String(format: "%.3f", f)
        var t = s
        while t.contains(".") && (t.hasSuffix("0") || t.hasSuffix(".")) { t.removeLast() }
        return t
    }

    private func loadCurrent() {
        let sp = store.model.findService("StarterPlayer")
        avatarType = Int(sp?.get("GameSettingsAvatar")?.asEnum ?? 2)
        collision = Int(sp?.get("GameSettingsR15Collision")?.asEnum ?? 0)
        loadAppearance = sp?.get("LoadCharacterAppearance")?.asBool != false
        for s in Self.scaleDefs {
            let nr: NumberRange
            if case .numberRange(let r)? = sp?.get("GameSettingsScaleRange\(s.key)") { nr = r } else { nr = s.def }
            minStr[s.key] = fmt(nr.min)
            maxStr[s.key] = fmt(nr.max)
        }
    }

    private func save() {
        guard let sp = store.model.findService("StarterPlayer") else {
            store.showToast("No StarterPlayer in this place")
            dismiss()
            return
        }
        var ranges: [String: NumberRange] = [:]
        var minMap: [String: Float] = [:], maxMap: [String: Float] = [:]
        for s in Self.scaleDefs {
            let a = Float((minStr[s.key] ?? "").replacingOccurrences(of: ",", with: ".")) ?? s.def.min
            let b = Float((maxStr[s.key] ?? "").replacingOccurrences(of: ",", with: ".")) ?? s.def.max
            let lo = min(5, max(0, min(a, b)))
            let hi = min(5, max(0, max(a, b)))
            ranges[s.key] = NumberRange(lo, hi)
            minMap[s.apiKey] = lo
            maxMap[s.apiKey] = hi
        }
        store.session.undo.begin("Game Settings: Avatar")
        store.session.setProp(sp, "GameSettingsAvatar", .enumValue(EnumValue(UInt32(avatarType))))
        store.session.setProp(sp, "GameSettingsR15Collision", .enumValue(EnumValue(UInt32(collision))))
        store.session.setProp(sp, "LoadCharacterAppearance", .bool(loadAppearance))
        for (k, r) in ranges {
            store.session.setProp(sp, "GameSettingsScaleRange\(k)", .numberRange(r))
        }
        store.session.undo.commit()
        store.dirty = true
        let typeName = ["R6", "R15", "Player Choice"][min(2, max(0, avatarType))]
        store.log("Game Settings: avatar type \(typeName)")

        if canSyncCloud && syncToRoblox, let universe = store.cloudPlace?.0 {
            saving = true
            let payload = RobloxWeb.AvatarSettings(type: avatarType, collision: collision, min: minMap, max: maxMap)
            Task {
                do {
                    try await RobloxWeb.setAvatarSettings(universe: universe, payload)
                    saving = false
                    store.showToast("Avatar settings saved (\(typeName))")
                    dismiss()
                } catch {
                    saving = false
                    store.log("Couldn't save avatar settings to Roblox: \(error.localizedDescription)", .warn)
                    cloudError = "The place now uses \(typeName), but Roblox didn't accept the change for the game:\n\n\(error.localizedDescription)"
                }
            }
        } else {
            store.showToast("Avatar type: \(typeName)")
            dismiss()
        }
    }
}

// MARK: - Playtest Avatar

struct PlaytestAvatarView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var account = AccountStore.shared
    var onOpenGameSettings: () -> Void
    var onOpenCustomCharacter: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var mode = AvatarLoader.mode
    @State private var showUserPrompt = false
    @State private var userDraft = AvatarLoader.otherUserName
    @State private var lookingUp = false
    @State private var lookupError: String?
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    optionRow(
                        icon: "person.crop.circle.fill", tint: Th.info,
                        title: "My Roblox avatar",
                        subtitle: account.isSignedIn ? "@\(account.userName ?? "Account"), as it looks on Roblox"
                                                     : "Sign in first to wear your avatar",
                        selected: mode == .account
                    ) {
                        if !account.isSignedIn {
                            showSignIn = true
                        } else {
                            AvatarLoader.mode = .account
                            mode = .account
                            store.showToast("Using your avatar")
                            dismiss()
                        }
                    }

                    let other = AvatarLoader.otherUserName
                    optionRow(
                        icon: "person.2.fill", tint: Th.info,
                        title: "Another user's avatar…",
                        subtitle: other.isEmpty ? "Wear any Roblox user's avatar" : "Now: @\(other)",
                        selected: mode == .user
                    ) {
                        userDraft = AvatarLoader.otherUserName
                        lookupError = nil
                        showUserPrompt = true
                    }

                    optionRow(
                        icon: "cube.fill", tint: Th.warn,
                        title: "Classic",
                        subtitle: "The yellow, blue and green blocky avatar",
                        selected: mode == .classic
                    ) {
                        AvatarLoader.mode = .classic
                        mode = .classic
                        store.showToast("Using the classic avatar")
                        dismiss()
                    }

                    let charSub: String = {
                        if AvatarLoader.hasCharacter {
                            let n = AvatarLoader.characterName.isEmpty ? "Saved model" : AvatarLoader.characterName
                            return "\"\(n)\" — you spawn as it in every place"
                        }
                        return "Play as any model or part, in every place you edit"
                    }()
                    optionRow(
                        icon: "cube.transparent.fill", tint: Th.play,
                        title: "Custom character (model or part)…",
                        subtitle: charSub,
                        selected: mode == .character
                    ) {
                        dismiss()
                        onOpenCustomCharacter()
                    }
                } footer: {
                    Text("Whether your avatar is R6 or R15 in a playtest follows each place's Game Settings → Avatar, like on Roblox.")
                }

                Section {
                    Button {
                        dismiss()
                        onOpenGameSettings()
                    } label: {
                        Label("Game Settings…", systemImage: "gearshape.fill")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Th.panel)
            .navigationTitle("Playtest Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .alert("Roblox username", isPresented: $showUserPrompt) {
                TextField("Username", text: $userDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Look up") { lookupUser() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(lookupError ?? "Enter any Roblox username to wear their avatar in playtests.")
            }
            .overlay {
                if lookingUp {
                    ProgressView("Looking up @\(userDraft)…")
                        .padding(20)
                        .background(Th.card, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(isPresented: $showSignIn, onDismiss: {
                if account.isSignedIn {
                    AvatarLoader.mode = .account
                    mode = .account
                    store.showToast("Using your avatar")
                    dismiss()
                }
            }) { SignInView() }
        }
    }

    private func optionRow(icon: String, tint: Color, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 24)).foregroundStyle(tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Th.text)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Th.dim)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Th.accent)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func lookupUser() {
        let name = userDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        lookingUp = true
        Task {
            do {
                guard let u = try await RobloxWeb.userByName(name) else {
                    lookingUp = false
                    lookupError = "No Roblox user named \"\(name)\"."
                    showUserPrompt = true
                    return
                }
                AvatarLoader.otherUserId = u.id
                AvatarLoader.otherUserName = u.name
                AvatarLoader.mode = .user
                mode = .user
                lookingUp = false
                store.showToast("Wearing @\(u.name)'s avatar")
                dismiss()
            } catch {
                lookingUp = false
                lookupError = error.localizedDescription
                showUserPrompt = true
            }
        }
    }
}

// MARK: - Custom Character Chooser

struct CustomCharacterView: View {
    @ObservedObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss

    private var selectedTarget: Instance? {
        store.selection.first { ($0.isA("Model") || $0.isA("BasePart")) && !$0.isService }
    }

    private var workspaceCandidates: [Instance] {
        var out: [Instance] = []
        func visit(_ parent: Instance, _ depth: Int) {
            for c in parent.children {
                if out.count >= 200 { return }
                if c.className == "Terrain" || c.className == "Camera" { continue }
                if c.isA("Model") || c.isA("BasePart") {
                    out.append(c)
                } else if c.className == "Folder" && depth < 2 {
                    visit(c, depth + 1)
                }
            }
        }
        visit(store.model.workspace, 0)
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                if let sel = selectedTarget {
                    Section("Selection") {
                        Button {
                            store.saveCustomCharacter(sel)
                            dismiss()
                        } label: {
                            Label("Use the selection (\(sel.name))", systemImage: "checkmark.circle.fill")
                        }
                    }
                }

                if AvatarLoader.hasCharacter {
                    let savedName = AvatarLoader.characterName.isEmpty ? "saved model" : AvatarLoader.characterName
                    Section("Saved character") {
                        if AvatarLoader.mode != .character {
                            Button {
                                AvatarLoader.mode = .character
                                store.showToast("Playing as \(savedName)")
                                dismiss()
                            } label: {
                                Label("Use \"\(savedName)\" again", systemImage: "person.fill.checkmark")
                            }
                        }
                        Button(role: .destructive) {
                            AvatarLoader.clearCharacter()
                            store.showToast("Back to your avatar")
                            dismiss()
                        } label: {
                            Label("Stop using \"\(savedName)\"", systemImage: "trash")
                        }
                    }
                }

                let list = workspaceCandidates
                Section("Pick from Workspace") {
                    if list.isEmpty {
                        Text("Workspace has no models or parts.").foregroundStyle(Th.dim)
                    } else {
                        ForEach(Array(list.enumerated()), id: \.offset) { _, inst in
                            Button {
                                store.saveCustomCharacter(inst)
                                dismiss()
                            } label: {
                                Label(inst.name, systemImage: inst.isA("BasePart") ? "cube.fill" : "shippingbox.fill")
                                    .foregroundStyle(Th.text)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Th.panel)
            .navigationTitle("Custom character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
