import SwiftUI

@MainActor
struct KakaPrivateCallHistoryScreen: View {
    @EnvironmentObject private var store: KakaNativeStore
    @State private var records: [Record] = []
    @State private var loadedSession: UUID?
    @State private var loading = false
    @State private var nextPage = 1
    @State private var total: Int64?
    @State private var canLoadMore = false
    @State private var error: String?
    @State private var revision = UUID()
    private let pageSize = 20

    private var showsEmptyHistory: Bool {
        loadedSession == store.session?.token && records.isEmpty && !loading && error == nil
    }

    var body: some View {
        KakaRoomSheet(title: "Video calls", locked: false) {
            KakaPrivateCallCover {
                VStack(alignment: .leading, spacing: 7) {
                    KakaNativeImage(asset: "room-watch.png")
                        .scaledToFit()
                        .frame(width: 35, height: 35)
                        .accessibilityHidden(true)
                    Text(showsEmptyHistory ? "No video calls yet" : "Recent calls")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    if showsEmptyHistory {
                        Text("Completed and missed calls appear here.")
                            .font(.subheadline)
                            .foregroundStyle(KakaTheme.muted)
                    } else if loadedSession == store.session?.token, let total, !records.isEmpty {
                        Text("\(records.count) of \(total) calls")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(KakaTheme.muted)
                    }
                }
            }
            if loadedSession != store.session?.token || (loading && records.isEmpty) {
                KakaRhythmProgress(title: "Loading calls")
                    .padding(.vertical, 12)
            } else {
                if !records.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            recordRow(record)
                            if record.id != records.last?.id { Divider().overlay(KakaTheme.line) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if loading {
                    KakaRhythmProgress(title: "Loading calls")
                } else if let error {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Couldn’t load calls").font(.headline).accessibilityAddTraits(.isHeader)
                        Text(error).font(.subheadline).foregroundStyle(KakaTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(15)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    KakaCallAction(title: "Try again", artwork: "action-forward.png") { Task { await load() } }
                } else if canLoadMore {
                    KakaCallAction(title: "Load earlier calls", artwork: "action-forward.png") {
                        Task { await load() }
                    }
                }
            }
        }
        .task(id: store.session?.token) { await load(reset: true) }
        .refreshable { await load(reset: true) }
    }

    private func recordRow(_ record: Record) -> some View {
        HStack(alignment: .top, spacing: 11) {
            KakaNativeImage(asset: "member-mark.jpg", remote: record.portrait)
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(record.status)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(record.completed ? KakaTheme.voiceAccent : KakaTheme.liveAccent)
                if let date = record.date {
                    Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(KakaTheme.muted)
                }
                if let duration = record.duration {
                    Text("Duration \(duration)")
                        .font(.footnote.monospacedDigit()).foregroundStyle(KakaTheme.muted)
                }
                if let rate = record.rate {
                    Text("\(rate) diamonds per minute")
                        .font(.footnote).foregroundStyle(KakaTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private func load(reset: Bool = false) async {
        guard let session = store.session?.token else { return }
        guard reset || !loading else { return }
        if loadedSession != session {
            loadedSession = session
            records = []
            nextPage = 1
            total = nil
            canLoadMore = false
        }
        if reset { nextPage = 1 }
        let page = nextPage
        let attempt = UUID()
        revision = attempt
        loading = true
        error = nil
        defer { if revision == attempt { loading = false } }
        do {
            let body = try KakaRemoteClient.json(["stagePage": page, "folioScale": pageSize])
            let data = try await KakaAccountStore.shared.call(path: "/voyager/archive", body: body, session: session)
            guard revision == attempt, store.session?.token == session, !Task.isCancelled else { return }
            let value = try KakaRemoteClient.object(data)
            let reportedTotal = KakaRemoteClient.userID(value["cosmicSum"]).flatMap { $0 >= 0 ? $0 : nil }
            guard let pageRows = value["gridBands"] as? [[String: Any]] ?? value["rows"] as? [[String: Any]]
                    ?? (reportedTotal == 0 ? [] : nil) else { throw KakaRemoteClient.Fault.response }
            let pageRecords = pageRows.prefix(pageSize).compactMap(Record.init)
            guard pageRows.isEmpty || !pageRecords.isEmpty else { throw KakaRemoteClient.Fault.response }
            if page == 1 { records = [] }
            var seen = Set(records.map(\.id))
            let additions = pageRecords.filter { seen.insert($0.id).inserted }
            records += additions
            total = reportedTotal.flatMap { $0 >= Int64(records.count) ? $0 : nil }
            canLoadMore = !additions.isEmpty && (total.map { Int64(page * pageSize) < $0 } ?? (pageRows.count >= pageSize))
            nextPage = page + 1
        } catch {
            guard revision == attempt, store.session?.token == session, !Task.isCancelled else { return }
            store.expireIfNeeded(error)
            self.error = store.message(error)
        }
    }

    private struct Record: Identifiable {
        let id: String
        let name: String
        let portrait: URL?
        let completed: Bool
        let status: String
        let date: Date?
        let duration: String?
        let rate: Int64?

        init?(_ row: [String: Any]) {
            guard let kind = KakaRemoteClient.userID(row["signalKind"]), (1...2).contains(kind) else { return nil }
            let channel = KakaRoomFields.text(row, "venueKey")
            let peerID = KakaRoomFields.id(row, keys: ["voyagerBadge"])
            let timestamp = KakaRoomFields.id(row, keys: ["debutTime"])
            if !channel.isEmpty, channel.utf8.count <= 128 {
                id = channel
            } else if let peerID, let timestamp {
                id = "\(peerID):\(timestamp):\(kind)"
            } else { return nil }
            let nickname = KakaRoomFields.text(row, "nickname").trimmingCharacters(in: .whitespacesAndNewlines)
            name = nickname.isEmpty ? "Kaka member" : String(nickname.prefix(100))
            portrait = KakaRoomFields.url(KakaRoomFields.text(row, "cometGlyph"))
            completed = kind == 1
            if completed {
                status = "Completed"
            } else {
                switch KakaRemoteClient.userID(row["encoreCause"]) {
                case 2: status = "No answer"
                case 3: status = "Canceled"
                case 7: status = "Declined"
                default: status = "Missed"
                }
            }
            date = timestamp.flatMap { time in
                let seconds = time > 10_000_000_000 ? Double(time) / 1_000 : Double(time)
                return seconds > 0 && seconds < 253_402_300_800 ? Date(timeIntervalSince1970: seconds) : nil
            }
            duration = completed ? KakaRemoteClient.userID(row["showcaseSpan"]).flatMap { seconds in
                guard (0...86_400).contains(seconds) else { return nil }
                return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
            } : nil
            rate = KakaRoomFields.id(row, keys: ["holoFare"])
        }
    }
}
