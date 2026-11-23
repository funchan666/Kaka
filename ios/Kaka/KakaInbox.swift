import SwiftUI

@MainActor
struct KakaInbox: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var rows: [KakaRoomChat.InboxRow] = []
    @State private var visitedOffsets = Set<Int64>()
    @State private var nextOffset: Int64?
    @State private var opening: String?
    @State private var openingTask: Task<Void, Never>?
    @State private var selected: KakaRoomChat.InboxRecipient?
    @State private var loading = false
    @State private var ready = false
    @State private var feedback = ""

    var body: some View {
        KakaRoomSheet(title: "Messages", locked: false) {
            if !feedback.isEmpty {
                Text(feedback)
                    .font(.subheadline)
                    .foregroundStyle(KakaTheme.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if ready && !loading && rows.isEmpty && nextOffset == nil && feedback.isEmpty {
                Text("No messages yet.")
                    .foregroundStyle(KakaTheme.muted)
                    .padding(.vertical, 12)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in conversation(row) }
            }
            if loading { KakaRhythmProgress(title: "Loading messages") }
            if let nextOffset {
                KakaRoomButton(title: "Load more messages") { Task { await load(offset: nextOffset) } }
                    .disabled(loading || opening != nil)
            }
            KakaRoomButton(title: "Refresh messages") { Task { await load() } }
                .disabled(loading || opening != nil)
        }
        .task { await load() }
        .refreshable { await load() }
        .onDisappear {
            openingTask?.cancel()
            openingTask = nil
        }
        .sheet(item: $selected, onDismiss: { Task { await load() } }) { recipient in
            KakaDirectChatSheet(recipient: recipient)
        }
    }

    private func conversation(_ row: KakaRoomChat.InboxRow) -> some View {
        Button {
            guard openingTask == nil else { return }
            openingTask = Task { await open(row) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                if let portrait = row.portrait, !textSize.isAccessibilitySize {
                    AsyncImage(url: portrait) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.body.weight(.semibold)).foregroundStyle(KakaTheme.ink)
                    if !row.preview.isEmpty {
                        Text(row.preview).font(.subheadline).foregroundStyle(KakaTheme.muted).lineLimit(2)
                    }
                    if let date = row.updated {
                        Text(date, style: .relative).font(.caption).foregroundStyle(KakaTheme.muted)
                    }
                    if row.unread > 0 {
                        Text(row.unread > 999 ? "999+ unread" : "\(row.unread) unread")
                            .font(.caption.weight(.semibold)).foregroundStyle(KakaTheme.accent)
                    }
                }
                Spacer(minLength: 6)
                if opening == row.id {
                    Text("Opening…").font(.caption).foregroundStyle(KakaTheme.muted)
                        .accessibilityLabel("Opening conversation")
                }
            }
            .frame(minHeight: 48, alignment: .leading)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(opening != nil)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func load(offset: Int64 = 0) async {
        guard !loading, let session = store.session?.token else { return }
        loading = true
        feedback = ""
        defer { loading = false }
        do {
            let page = try await KakaRoomChat.inboxPage(offset: offset, session: session)
            guard !Task.isCancelled, store.session?.token == session else { return }
            if offset == 0 {
                visitedOffsets = []
                rows = []
            }
            visitedOffsets.insert(offset)
            var ids = Set(rows.map(\.id))
            rows += page.rows.filter { ids.insert($0.id).inserted }
            nextOffset = page.nextOffset.flatMap { visitedOffsets.contains($0) ? nil : $0 }
            ready = true
        } catch {
            guard !Task.isCancelled, store.session?.token == session else { return }
            store.expireIfNeeded(error)
            feedback = store.message(error)
        }
    }

    private func open(_ row: KakaRoomChat.InboxRow) async {
        defer {
            opening = nil
            openingTask = nil
        }
        guard let session = store.session?.token else { return }
        opening = row.id
        feedback = ""
        do {
            let recipient = try await KakaRoomChat.inboxRecipient(for: row.account, session: session)
            guard !Task.isCancelled, store.session?.token == session else { return }
            selected = recipient
        } catch {
            guard !Task.isCancelled, store.session?.token == session else { return }
            store.expireIfNeeded(error)
            feedback = store.message(error)
        }
    }
}

@MainActor
struct KakaDirectChatSheet: View {
    let recipient: KakaRoomChat.InboxRecipient

    var body: some View {
        KakaRoomSheet(title: recipient.name, locked: false) {
            KakaNativeChatView(recipient: recipient)
        }
    }
}
