import SwiftUI
import UIKit

/// AI Assistant dock window (port of ui/AssistantPanel.kt): set up an Anthropic API key, then chat
/// with Claude, which builds and scripts in the open place.
struct AssistantPanel: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var ai: Assistant
    @ObservedObject var account = AccountStore.shared
    var onClose: () -> Void
    @State private var input = ""
    @State private var keyDraft = ""
    @State private var checking = false
    @State private var keyError: String?
    @State private var confirmUndo = false

    init(store: StudioStore, onClose: @escaping () -> Void) {
        self.store = store
        self.ai = store.assistant
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(icon: "sparkles", tint: Color(argb: -6596097), title: "Assistant", onClose: onClose) {
                if account.anthropicKey != nil {
                    PanelIconButton(icon: "square.and.pencil") { ai.newChat() }
                    menu
                }
            }
            if account.anthropicKey == nil { setup } else { chat }
        }
        .background(Th.panel)
        .confirmationDialog("Undo AI changes", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Undo AI changes", role: .destructive) { ai.undoAIChanges() }
        } message: {
            Text("Put the place back the way it was before the last AI request? Edits you made since then are undone too.")
        }
    }

    private var menu: some View {
        Menu {
            Picker("Model", selection: $ai.model) { ForEach(Assistant.models, id: \.0) { Text($0.1).tag($0.0) } }
            Picker("Effort", selection: $ai.effort) { ForEach(Assistant.efforts, id: \.0) { Text($0.1).tag($0.0) } }
            Button("Undo AI changes", systemImage: "arrow.uturn.backward") { confirmUndo = true }.disabled(ai.snapshot == nil)
            Button("Remove key", systemImage: "key.slash", role: .destructive) { ai.newChat(); account.setAnthropicKey(nil) }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(Th.text).frame(width: 28, height: 28)
        }
    }

    // MARK: setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Build with Claude").font(.system(size: 20, weight: .bold)).foregroundStyle(Th.text)
                Text("Describe what you want and Claude builds it in your place.").font(.system(size: 14)).foregroundStyle(Th.text)
                step(1, "Get an Anthropic API key", "Make a new secret key in the Anthropic Console and copy it.")
                Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                    Label("Open Anthropic Console", systemImage: "safari").font(.system(size: 15))
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .background(Th.hover, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Th.text)
                }
                step(2, "Paste key", "Come back and paste it. The key is checked (free) and saved only on this device.")
                SecureField("", text: $keyDraft, prompt: Text("sk-ant-…").foregroundStyle(Th.dim))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .studioField()
                HStack(spacing: 8) {
                    Chip(label: "Paste from clipboard") {
                        if let s = UIPasteboard.general.string { keyDraft = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                        else { keyError = "No key on the clipboard. Copy it in the Anthropic Console first." }
                    }
                    Spacer()
                    Button { save() } label: {
                        HStack(spacing: 6) {
                            if checking { ProgressView().tint(.white) }
                            Text(checking ? "Checking your key…" : "Save")
                        }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(Th.accent, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(checking || keyDraft.isEmpty)
                }
                if let keyError { Text(keyError).font(.system(size: 13)).foregroundStyle(Th.error) }
                Text("What you send, and the parts of your place Claude reads, go to Anthropic to get a reply. Your Roblox sign-in is never shared.")
                    .font(.system(size: 12)).foregroundStyle(Th.dim)
            }
            .padding(14)
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Th.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Th.text)
                Text(detail).font(.system(size: 13)).foregroundStyle(Th.dim)
            }
        }
    }

    private func save() {
        let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.hasPrefix("sk-ant-") else { keyError = "That doesn't look like an Anthropic key (it starts with sk-ant-)"; return }
        checking = true
        keyError = nil
        Task {
            let err = await Assistant.checkKey(k)
            checking = false
            if let err { keyError = err } else { account.setAnthropicKey(k); keyDraft = "" }
        }
    }

    // MARK: chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if ai.items.isEmpty { empty }
                        ForEach(ai.items) { item in bubble(item).id(item.id) }
                        if ai.busy {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text(ai.status).font(.system(size: 13)).foregroundStyle(Th.dim)
                            }
                            .id("status")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: ai.items.count) { _, _ in
                    if let id = ai.items.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            HStack(spacing: 6) {
                TextField("", text: $input, prompt: Text("Ask Claude to build or script something…").foregroundStyle(Th.dim), axis: .vertical)
                    .lineLimit(1...4)
                    .studioField()
                    .onSubmit(send)
                if ai.busy {
                    Button("Stop") { ai.stop() }.font(.system(size: 14, weight: .semibold)).foregroundStyle(Th.error)
                } else {
                    PanelIconButton(icon: "paperplane.fill", tint: Th.info, action: send)
                }
            }
            .padding(6)
            .background(Th.header)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type what you want below, or try:").font(.system(size: 14)).foregroundStyle(Th.text)
            ForEach(Assistant.suggestions, id: \.self) { s in
                Button { input = s; send() } label: {
                    Text(s).font(.system(size: 13)).foregroundStyle(Th.text).multilineTextAlignment(.leading)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Th.card, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func bubble(_ item: Assistant.Item) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(item.text).font(.system(size: 14)).foregroundStyle(.white).textSelection(.enabled)
                    .padding(10).background(Th.accent, in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            Text((try? AttributedString(markdown: item.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(item.text))
                .font(.system(size: 14)).foregroundStyle(Th.text).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Th.card, in: RoundedRectangle(cornerRadius: 10))
        case .tool:
            Label(item.text, systemImage: "wrench.and.screwdriver").font(.system(size: 12)).foregroundStyle(Th.dim)
        case .notice:
            Label(item.text, systemImage: "info.circle").font(.system(size: 13)).foregroundStyle(Th.info)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Th.error)
        }
    }

    private func send() {
        let t = input
        input = ""
        ai.send(t)
    }
}
