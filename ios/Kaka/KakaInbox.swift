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
            inboxCover
            if !feedback.isEmpty {
                Text(feedback)
                    .font(.subheadline)
                    .foregroundStyle(KakaTheme.muted)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if !rows.isEmpty {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in conversation(row) }
                }
            }
            if loading { KakaRhythmProgress(title: "Loading messages") }
            KakaRoomActionGroup {
                if let nextOffset {
                    KakaRoomButton(title: "Load more messages") { Task { await load(offset: nextOffset) } }
                        .disabled(loading || opening != nil)
                }
                KakaRoomButton(title: "Refresh messages") { Task { await load() } }
                    .disabled(loading || opening != nil)
            }
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

    private var inboxCover: some View {
        let unread = rows.filter { $0.unread > 0 }.count
        let title = ready && !loading && rows.isEmpty && nextOffset == nil && feedback.isEmpty
            ? "No messages yet" : "Recent conversations"
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if unread > 0 {
                Text(unread == 1 ? "1 unread conversation" : "\(unread.formatted()) unread conversations")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(KakaTheme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .background {
            GeometryReader { artwork in
                KakaNativeImage(asset: "room-chat-cover.jpg")
                    .scaledToFill()
                    .frame(width: artwork.size.width, height: artwork.size.height, alignment: .trailing)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [KakaTheme.base, KakaTheme.base.opacity(0.64), KakaTheme.base.opacity(0.18)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
    }

    private func conversation(_ row: KakaRoomChat.InboxRow) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return Button {
            guard openingTask == nil else { return }
            openingTask = Task { await open(row) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                if !textSize.isAccessibilitySize {
                    KakaNativeImage(asset: "member-mark.jpg", remote: row.portrait)
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(KakaTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !row.preview.isEmpty {
                        Text(row.preview).font(.subheadline).foregroundStyle(KakaTheme.muted).lineLimit(2)
                    }
                    if textSize.isAccessibilitySize, let date = row.updated {
                        Text(date, style: .relative).font(.caption).foregroundStyle(KakaTheme.muted)
                    }
                    if textSize.isAccessibilitySize, row.unread > 0 {
                        Text(row.unread > 999 ? "999+ unread" : "\(row.unread) unread")
                            .font(.caption.weight(.semibold)).foregroundStyle(KakaTheme.accent)
                    }
                    if opening == row.id {
                        Text("Opening…").font(.caption).foregroundStyle(KakaTheme.muted)
                    }
                }
                Spacer(minLength: 3)
                if !textSize.isAccessibilitySize {
                    VStack(alignment: .trailing, spacing: 6) {
                        if let date = row.updated {
                            Text(date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(KakaTheme.muted)
                                .lineLimit(1)
                        }
                        if row.unread > 0 {
                            Text(row.unread > 999 ? "999+" : row.unread.formatted())
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(KakaTheme.base)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(KakaTheme.accent, in: Capsule())
                                .accessibilityLabel(row.unread > 999 ? "More than 999 unread" : "\(row.unread) unread")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 51, alignment: .leading)
            .padding(9)
            .background(KakaTheme.surface, in: shape)
            .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(opening != nil)
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
        KakaRoomSheet(title: recipient.name, locked: false, scrolls: false) {
            KakaNativeChatView(recipient: recipient)
        }
    }
}
