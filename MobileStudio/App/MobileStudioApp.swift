import SwiftUI
import UniformTypeIdentifiers
import StudioCore

@main
struct MobileStudioApp: App {
    @StateObject private var store = StudioStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if store.hasDocument {
                    EditorView(store: store)
                } else {
                    StartView(store: store)
                }
            }
            .onOpenURL { store.open($0) }
        }
    }
}

/// Start screen (port of ui/StartScreen.kt): templates, open a file, recent files.
struct StartView: View {
    @ObservedObject var store: StudioStore
    @State private var showImporter = false
    @State private var recents: [URL] = []

    var body: some View {
        List {
            Section("New") {
                ForEach(PlaceFactory.Template.allCases) { t in
                    Button { store.newPlace(t) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: t == .empty ? "square.dashed" : "square.grid.3x3.fill")
                                .font(.title2).frame(width: 44, height: 44)
                                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading) {
                                Text(t.title).font(.headline)
                                Text(t.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            Section {
                Button("Open File…", systemImage: "folder") { showImporter = true }
            } footer: {
                Text("Opens .rbxl / .rbxlx places and .rbxm / .rbxmx models from Files.")
            }
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { url in
                        Button { store.open(url) } label: {
                            Label(url.lastPathComponent, systemImage: "clock")
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .navigationTitle("Mobile Studio")
        .onAppear { recents = Recents.all() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: UTType.robloxFiles) { r in
            if case .success(let url) = r { store.open(url) }
        }
    }
}
