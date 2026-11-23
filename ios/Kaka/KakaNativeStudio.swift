import SwiftUI
import UIKit

private struct KakaStudioIssue: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private enum KakaStudioCopy {
    static let styles = ["freestyle": "Freestyle", "story": "Storytelling", "punch": "Punchlines"]
    static let cues = ["breathe": "Breathe at the end", "tight": "Keep phrases short", "pick-up": "Enter on beat one"]
    static let error = Color(red: 1, green: 0.71, blue: 0.78)

    static func text(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var remaining = limit
        return String(trimmed.prefix {
            remaining -= $0.utf16.count
            return remaining >= 0
        })
    }

    static func remoteURL(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

private struct KakaVerseScore: Equatable {
    struct Bar: Equatable {
        let section: String
        var text: String
        let rhyme: String
        let cue: String

        init?(_ row: [String: Any], serviceResponse: Bool = false) {
            guard let section = row["section"] as? String, ["verse", "hook"].contains(section),
                  let text = row["text"] as? String, (1...160).contains(text.utf16.count),
                  let rhyme = row["rhyme"] as? String, (1...4).contains(rhyme.utf16.count),
                  let cue = row["cue"] as? String, (1...24).contains(cue.utf16.count) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if serviceResponse {
                guard !trimmed.isEmpty, rhyme.range(of: "^[a-zA-Z]{1,4}$", options: .regularExpression) != nil,
                      KakaStudioCopy.cues[cue] != nil else { return nil }
            }
            self.section = section
            self.text = serviceResponse ? trimmed : text
            self.rhyme = rhyme
            self.cue = cue
        }
    }

    var id: String
    let topic: String
    let style: String
    let bpm: Int
    let scheme: String
    let roomID: String?
    var bars: [Bar]
    var createdAt: Double
    var updatedAt: Double

    init(topic: String, style: String, bpm: Int, scheme: String, roomID: String?, bars: [Bar]) {
        let now = Date().timeIntervalSince1970 * 1_000
        self.init(id: UUID().uuidString.lowercased(), topic: topic, style: style, bpm: bpm,
                  scheme: scheme, roomID: roomID, bars: bars, createdAt: now, updatedAt: now)
    }

    private init(id: String, topic: String, style: String, bpm: Int, scheme: String, roomID: String?,
                 bars: [Bar], createdAt: Double, updatedAt: Double) {
        self.id = id
        self.topic = topic
        self.style = style
        self.bpm = bpm
        self.scheme = scheme
        self.roomID = roomID
        self.bars = bars
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, let topic = row["topic"] as? String,
              let style = row["style"] as? String, KakaStudioCopy.styles[style] != nil,
              let bpm = row["bpm"] as? Int, (60...180).contains(bpm),
              let scheme = row["scheme"] as? String, ["AABB", "ABAB"].contains(scheme),
              let raw = row["bars"] as? [[String: Any]], [4, 8, 16].contains(raw.count),
              let createdAt = row["createdAt"] as? Double, let updatedAt = row["updatedAt"] as? Double else { return nil }
        let bars = raw.compactMap { Bar($0) }
        guard bars.count == raw.count else { return nil }
        self.init(id: id, topic: topic, style: style, bpm: bpm, scheme: scheme,
                  roomID: row["roomID"] as? String, bars: bars, createdAt: createdAt, updatedAt: updatedAt)
    }

    var record: [String: Any] {
        let rows: [[String: Any]] = bars.enumerated().map { index, bar in
            ["index": index + 1, "section": bar.section, "text": bar.text, "rhyme": bar.rhyme, "cue": bar.cue]
        }
        let source: Any = roomID.map { $0 as Any } ?? NSNull()
        return ["id": id, "topic": topic, "style": style, "bpm": bpm, "scheme": scheme,
                "roomID": source, "bars": rows, "createdAt": createdAt, "updatedAt": updatedAt]
    }

    var detail: String {
        "\(KakaStudioCopy.styles[style] ?? style) · \(bpm) BPM · \(bars.count) bars"
    }
}

private struct KakaStudioButton: View {
    let title: String
    var icon: String? = nil
    var emphasis = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    KakaNativeImage(asset: icon)
                        .scaledToFit()
                        .frame(width: 21, height: 21)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.subheadline.weight(emphasis ? .bold : .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(emphasis ? KakaTheme.ink : KakaTheme.muted)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44)
            .modifier(KakaGlass(interactive: true, radius: 17))
        }
        .buttonStyle(.plain)
    }
}

private struct KakaStudioIconButton: View {
    let title: String
    let image: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            KakaNativeImage(asset: image)
                .scaledToFit()
                .frame(width: 21, height: 21)
                .frame(width: 44, height: 44)
                .modifier(KakaGlass(interactive: true, radius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct KakaStudioSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text(title).font(.largeTitle.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 10)
                    KakaStudioIconButton(title: "Close", image: "action-close.png") { dismiss() }
                }
                content
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(KakaTheme.ink)
        .background(KakaTheme.base.ignoresSafeArea())
    }
}

private struct KakaStudioDecision {
    let title: String
    let detail: String
    let button: String
    let confirmed: () -> Void
}

private struct KakaStudioDecisionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let decision: KakaStudioDecision

    var body: some View {
        KakaStudioSheet(title: decision.title) {
            Text(decision.detail).foregroundStyle(KakaTheme.muted)
            KakaStudioButton(title: decision.button, emphasis: true) {
                dismiss()
                decision.confirmed()
            }
            KakaStudioButton(title: "Cancel") { dismiss() }
        }
    }
}

struct KakaNativeNotebookView: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
    @FocusState private var topicFocused: Bool
    @State private var topic = ""
    @State private var tempo = "92"
    @State private var length = 8
    @State private var style = "freestyle"
    @State private var scheme = "AABB"
    @State private var sourceRoomID: String?
    @State private var score: KakaVerseScore?
    @State private var saved: KakaVerseScore?
    @State private var generating: String?
    @State private var generation: UUID?
    @State private var saving = false
    @State private var error = ""
    @State private var settings = false
    @State private var choosingRoom = false
    @State private var decision: KakaStudioDecision?

    private static let starterTopics = ["The last train home", "A win nobody saw", "Back on the mic", "A promise to my crew"]
    private static let console = Color(red: 0.075, green: 0.063, blue: 0.119)
    private static let signal = Color(red: 0.69, green: 0.84, blue: 1)

    private var rooms: [KakaNativeRoom] {
        store.knownRooms.values.filter { !store.isHidden($0.id) }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var prompts: [KakaNativeRoom] {
        rooms.filter {
            !$0.topic.isEmpty && $0.topic.caseInsensitiveCompare($0.title) != .orderedSame
                && $0.topic.caseInsensitiveCompare($0.host?.name ?? "") != .orderedSame
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let gutter: CGFloat = geometry.size.width < 350 ? 16 : 20
            let contentWidth = max(1, min(560, geometry.size.width - gutter * 2))
            let stackActions = textSize.isAccessibilitySize || contentWidth < 290
            let hasOutput = generating != nil || score != nil
            let artworkHeight = min(174, max(124, contentWidth * 0.45))
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let generating {
                            signalPanel(artworkHeight: artworkHeight) {
                                generationStatus(generating)
                            }
                        } else if let score {
                            result(score, stacked: stackActions)
                        } else {
                            opening(artworkHeight: topicFocused && geometry.size.height < 430 ? 0 : artworkHeight,
                                    stacked: stackActions)
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, gutter)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .id("verse-top")
                }
                .onChange(of: score?.id) { _ in reader.scrollTo("verse-top", anchor: .top) }
                .onChange(of: generating) { _ in reader.scrollTo("verse-top", anchor: .top) }
                .onChange(of: topicFocused) { focused in
                    if focused && !hasOutput { reader.scrollTo("verse-top", anchor: .top) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if hasOutput {
                    composer(stacked: stackActions && geometry.size.height >= 310)
                        .background(Self.console, in: RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18).strokeBorder(KakaTheme.line)
                                .allowsHitTesting(false)
                        }
                        .frame(maxWidth: 560)
                        .padding(.horizontal, gutter)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(KakaTheme.ink)
        .onAppear(perform: consumeNavigation)
        .onChange(of: store.verseRoom?.id) { _ in consumeNavigation() }
        .onChange(of: store.verseDraftID) { _ in consumeNavigation() }
        .onChange(of: draftsInStorage) { ids in
            guard let saved, score?.id == saved.id, !ids.contains(saved.id), !saving else { return }
            if score == saved {
                score = nil
            } else {
                score?.id = UUID().uuidString.lowercased()
                score?.createdAt = Date().timeIntervalSince1970 * 1_000
            }
            self.saved = nil
        }
        .sheet(isPresented: $settings) { settingsSheet }
        .sheet(isPresented: $choosingRoom) { practiceSheet }
        .sheet(isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } })) {
            if let decision { KakaStudioDecisionSheet(decision: decision) }
        }
    }

    private var draftsInStorage: Set<String> {
        Set((store.record["scores"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    }

    private func opening(artworkHeight: CGFloat, stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            signalPanel(artworkHeight: artworkHeight) {
                composer(stacked: stacked)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Try a prompt")
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Self.starterTopics, id: \.self) { suggestion in
                        if suggestion != Self.starterTopics.first { trackDivider }
                        starterPromptButton(suggestion)
                    }
                }
                .background(Self.console, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(KakaTheme.line)
                        .allowsHitTesting(false)
                }
            }
            if !prompts.isEmpty {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("Room prompts").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                    ForEach(prompts) { room in
                        Button {
                            fill(from: room)
                            topicFocused = true
                        } label: {
                            HStack(spacing: 10) {
                                KakaNativeImage(asset: "notebook.jpg", remote: room.host?.portrait ?? room.cover)
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 11))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(room.topic).font(.subheadline.weight(.semibold))
                                    Text(room.title).font(.caption).foregroundStyle(KakaTheme.muted)
                                }
                                Spacer(minLength: 4)
                                KakaNativeImage(asset: "action-forward.png")
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                                    .accessibilityHidden(true)
                            }
                            .padding(8)
                            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func generationStatus(_ topic: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KakaRhythmProgress(title: "Drafting your verse").accessibilityHidden(true)
                Text("Drafting your verse…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Self.signal)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Text(topic)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(18)
    }

    private func signalPanel<Content: View>(artworkHeight: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if artworkHeight > 0 {
                GeometryReader { artwork in
                    Image("VerseSignalStudio")
                        .resizable()
                        .scaledToFill()
                        .frame(width: artwork.size.width, height: artwork.size.height)
                        .clipped()
                        .overlay {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0.55),
                                .init(color: Self.console, location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        }
                }
                .frame(height: artworkHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.console)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(KakaTheme.line)
                .allowsHitTesting(false)
        }
    }

    private var trackDivider: some View {
        KakaTheme.line.frame(height: 1)
            .accessibilityHidden(true)
    }

    private func starterPromptButton(_ suggestion: String) -> some View {
        let selected = topic == suggestion && sourceRoomID == nil
        return Button {
            topic = suggestion
            sourceRoomID = nil
            error = ""
        } label: {
            HStack(spacing: 8) {
                Text(suggestion)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                KakaNativeImage(asset: selected ? "action-check.png" : "action-forward.png")
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .opacity(selected ? 1 : 0.55)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(selected ? Self.signal : KakaTheme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(selected ? Self.signal.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use prompt: \(suggestion)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func result(_ current: KakaVerseScore, stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(current.topic)
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(current.detail) · 4/4 time · \(current.scheme)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Self.signal)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    topic = current.topic
                    topicFocused = true
                } label: {
                    Text("Reuse topic")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KakaTheme.accent)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reuse topic: \(current.topic)")
            }
            .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(current.bars.indices, id: \.self) { index in
                    let bar = current.bars[index]
                    if index == 0 || current.bars[index - 1].section != bar.section {
                        Text(bar.section == "hook" ? "Hook" : "Verse")
                            .font(.headline)
                            .foregroundStyle(Self.signal)
                            .padding(.top, 13)
                            .accessibilityAddTraits(.isHeader)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Self.signal)
                            .frame(minWidth: 24, alignment: .trailing)
                            .padding(.top, 10)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            TextEditor(text: Binding(
                                get: { score?.bars[safeStudio: index]?.text ?? "" },
                                set: { if score?.bars.indices.contains(index) == true {
                                    score?.bars[index].text = $0
                                }}
                            ))
                            .modifier(KakaStudioEditor())
                            .frame(minHeight: 66)
                            .accessibilityLabel("Lyrics for bar \(index + 1)")
                            Text("Rhyme · -\(bar.rhyme) · \(KakaStudioCopy.cues[bar.cue] ?? bar.cue)")
                                .font(.caption).foregroundStyle(KakaTheme.muted)
                        }
                    }
                    .padding(.vertical, 7)
                    if index < current.bars.count - 1 {
                        trackDivider
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .background(Self.console, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).strokeBorder(KakaTheme.line)
                    .allowsHitTesting(false)
            }
            if stacked {
                VStack(spacing: 8) { resultActions }
            } else {
                HStack(spacing: 8) { resultActions }
            }
        }
    }

    @ViewBuilder
    private var resultActions: some View {
        KakaStudioButton(title: saving ? "Saving…" : "Save draft", icon: "action-bookmark.png", emphasis: true) {
            Task { await save() }
        }
        .disabled(saving)
        KakaStudioButton(title: "Rehearse", icon: "room-listen.png") { choosingRoom = true }
    }

    private func composer(stacked: Bool) -> some View {
        let characterCount = topic.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        return VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Topic").font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text("\(characterCount)/32")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(characterCount > 32 ? KakaStudioCopy.error : KakaTheme.muted)
                        .accessibilityLabel("\(characterCount) of 32 topic characters")
                }
                TextField("Verse topic", text: $topic, prompt: Text("Give me a topic…").foregroundColor(KakaTheme.muted))
                    .font(.body)
                    .tint(Self.signal)
                    .submitLabel(.go)
                    .focused($topicFocused)
                    .onSubmit(submit)
                    .onChange(of: topic) { _ in error = "" }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minHeight: 46)
                    .background(KakaTheme.base, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(topicFocused ? Self.signal.opacity(0.68) : KakaTheme.line, lineWidth: 1)
                            .allowsHitTesting(false)
                    }

                if let sourceRoomID, let room = store.knownRooms[sourceRoomID] {
                    Text(room.title)
                        .font(.caption)
                        .foregroundStyle(KakaTheme.muted)
                        .lineLimit(1)
                        .accessibilityLabel("Source room: \(room.title)")
                }
            }
            if !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(KakaStudioCopy.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    verseSettingsButton
                    draftVerseButton
                }
            } else {
                HStack(spacing: 10) {
                    verseSettingsButton
                    draftVerseButton
                }
            }
        }
        .padding(15)
    }

    private var verseSettingsButton: some View {
        Button {
            topicFocused = false
            settings = true
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Verse settings").font(.caption.weight(.semibold))
                        .foregroundStyle(KakaTheme.muted)
                    Text("\(tempo) BPM · \(length) bars")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Self.signal)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                KakaNativeImage(asset: "action-forward.png")
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .opacity(0.65)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 44, minHeight: 48, alignment: .leading)
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Verse settings")
        .accessibilityValue("\(tempo) BPM, \(length) bars")
    }

    private var draftVerseButton: some View {
        let busy = generating != nil || saving
        return Button(action: submit) {
            Text(generating == nil ? "Draft verse" : "Drafting…")
                .font(.subheadline.weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(busy ? KakaTheme.muted : KakaTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .frame(minWidth: 44, minHeight: 48)
                .modifier(KakaGlass(interactive: !busy, radius: 24,
                                    tint: busy ? nil : KakaTheme.actionFill.opacity(0.68)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var settingsSheet: some View {
        KakaStudioSheet(title: "Verse settings") {
            Text("Tempo").font(.headline)
            TextField("60–180 BPM", text: $tempo)
                .keyboardType(.numberPad)
                .modifier(KakaStudioField())
                .accessibilityLabel("Tempo in BPM")
            choices("Style", values: ["freestyle", "story", "punch"], selection: $style) {
                KakaStudioCopy.styles[$0] ?? $0
            }
            choices("Rhyme scheme", values: ["AABB", "ABAB"], selection: $scheme) { $0 }
            choices("Length", values: [4, 8, 16], selection: $length) { "\($0) bars" }
        }
    }

    private func choices<T: Hashable>(_ title: String, values: [T], selection: Binding<T>,
                                      label: @escaping (T) -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(values, id: \.self) { value in
                KakaStudioButton(title: label(value),
                                 icon: value == selection.wrappedValue ? "action-check.png" : nil,
                                 emphasis: value == selection.wrappedValue) {
                    selection.wrappedValue = value
                }
                .accessibilityAddTraits(value == selection.wrappedValue ? .isSelected : [])
            }
        }
    }

    private var practiceSheet: some View {
        KakaStudioSheet(title: "Rehearse in a room") {
            let choices = rooms.filter { $0.kind == .voice }
            if choices.isEmpty {
                Text("No voice rooms are available right now.").foregroundStyle(KakaTheme.muted)
                KakaStudioButton(title: "Browse voice rooms") {
                    choosingRoom = false
                    store.select(.voice)
                }
            }
            ForEach(choices) { room in
                KakaStudioButton(title: room.title, icon: "room-listen.png") {
                    guard let score else { return }
                    choosingRoom = false
                    store.rehearse(score.record, in: room)
                }
            }
        }
    }

    private func fill(from room: KakaNativeRoom) {
        topic = KakaStudioCopy.text(room.topic, limit: 32)
        tempo = room.bpm.map { String($0) } ?? tempo
        style = KakaStudioCopy.styles[room.style] == nil ? "freestyle" : room.style
        scheme = "AABB"
        length = 8
        sourceRoomID = room.id
        error = ""
    }

    private func consumeNavigation() {
        if let room = store.verseRoom {
            store.verseRoom = nil
            fill(from: room)
        }
        guard let id = store.verseDraftID else { return }
        store.verseDraftID = nil
        let rows = store.record["scores"] as? [[String: Any]] ?? []
        guard let row = rows.first(where: { $0["id"] as? String == id }), let draft = KakaVerseScore(row) else {
            store.notify("This draft is no longer available.")
            return
        }
        if let score, score.id != draft.id, score != saved {
            decision = KakaStudioDecision(title: "Open another draft?",
                                          detail: "Opening another draft will discard your unsaved changes.",
                                          button: "Open draft") { open(draft) }
        } else {
            open(draft)
        }
    }

    private func open(_ draft: KakaVerseScore) {
        generation = nil
        generating = nil
        if score?.id != draft.id {
            score = draft
            saved = draft
        }
        tempo = String(draft.bpm)
        style = draft.style
        scheme = draft.scheme
        length = draft.bars.count
        sourceRoomID = draft.roomID
        topic = ""
        error = ""
    }

    private func submit() {
        guard generating == nil, !saving else { return }
        let title = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf16.count <= 32 else {
            error = "Enter a topic of up to 32 characters."
            topicFocused = true
            return
        }
        guard let bpm = Int(tempo), (60...180).contains(bpm) else {
            error = "Enter a whole number between 60 and 180 BPM."
            topicFocused = false
            settings = true
            return
        }
        topicFocused = false
        if let score, score != saved {
            decision = KakaStudioDecision(title: "Generate a new verse?",
                                          detail: "A new verse will replace your unsaved changes.",
                                          button: "Generate verse") { Task { await generate(title: title, bpm: bpm) } }
        } else {
            Task { await generate(title: title, bpm: bpm) }
        }
    }

    private func generate(title: String, bpm: Int) async {
        guard generating == nil, let token = store.session?.token else { return }
        let style = style
        let scheme = scheme
        let length = length
        let roomID = sourceRoomID
        let source: Any = roomID.map { $0 as Any } ?? NSNull()
        let request: [String: Any] = ["topic": title, "style": style, "bpm": bpm, "length": length,
                                     "scheme": scheme, "roomID": source]
        let attempt = UUID()
        generation = attempt
        generating = title
        error = ""
        defer {
            if generation == attempt {
                generation = nil
                generating = nil
            }
        }
        do {
            let response = try await store.request("verse.generate", request) as? [String: Any]
            guard store.session?.token == token, generation == attempt else { return }
            guard let rows = response?["bars"] as? [[String: Any]], rows.count == length else {
                throw KakaStudioIssue(text: "The service returned an incomplete verse. Try again.")
            }
            let bars = rows.compactMap { KakaVerseScore.Bar($0, serviceResponse: true) }
            guard bars.count == rows.count else {
                throw KakaStudioIssue(text: "The service returned a verse that could not be opened.")
            }
            score = KakaVerseScore(topic: title, style: style, bpm: bpm, scheme: scheme, roomID: roomID, bars: bars)
            saved = nil
            if topic.trimmingCharacters(in: .whitespacesAndNewlines) == title { topic = "" }
        } catch {
            if store.session?.token == token, generation == attempt { self.error = store.message(error) }
        }
    }

    private func save() async {
        guard let current = score, !saving else { return }
        var copy = current
        for index in copy.bars.indices {
            let text = copy.bars[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf16.count <= 160 else {
                error = "Use 1–160 characters for bar \(index + 1)."
                return
            }
            copy.bars[index].text = text
        }
        copy.updatedAt = Date().timeIntervalSince1970 * 1_000
        saving = true
        error = ""
        defer { saving = false }
        let toSave = copy
        do {
            try await store.updateRecord { record in
                var drafts = record["scores"] as? [[String: Any]] ?? []
                if let index = drafts.firstIndex(where: { $0["id"] as? String == toSave.id }) {
                    drafts[index] = toSave.record
                } else {
                    guard drafts.count < 40 else { throw KakaStudioIssue(text: "Your drafts are full. Delete one to save another.") }
                    drafts.append(toSave.record)
                }
                record["scores"] = drafts
            }
            if score?.id == toSave.id {
                saved = toSave
                if score == current { score = toSave }
            }
            store.notify("Verse saved to drafts.")
        } catch { self.error = store.message(error) }
    }
}

private extension Collection {
    subscript(safeStudio index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

private struct KakaStudioField: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(12)
            .frame(minHeight: 44)
            .background(KakaTheme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct KakaStudioEditor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content.colorScheme(.dark)
        }
    }
}

struct KakaNativeProfileView: View {
    private enum Panel: String, Identifiable {
        case edit, account, wallet, help
        var id: String { rawValue }
    }

    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var remoteName: String?
    @State private var remoteBio: String?
    @State private var portrait: URL?
    @State private var error = ""
    @State private var profileLoading = true
    @State private var panel: Panel?
    @State private var decision: KakaStudioDecision?
    @State private var changingRecords = false

    private static let signal = Color(red: 0.69, green: 0.84, blue: 1)

    private var localProfile: [String: String] { store.record["profile"] as? [String: String] ?? [:] }
    private var name: String { remoteName ?? localProfile["name"] ?? store.session?.name ?? "" }
    private var bio: String { remoteBio ?? localProfile["bio"] ?? "" }
    private var style: String { localProfile["style"] ?? "" }
    private var drafts: [KakaVerseScore] {
        (store.record["scores"] as? [[String: Any]] ?? []).compactMap(KakaVerseScore.init).sorted { $0.updatedAt > $1.updatedAt }
    }
    private var savedRoomIDs: [String] {
        let notes = (store.record["notes"] as? [[String: Any]] ?? []).compactMap { $0["roomID"] as? String }
        var seen = Set<String>()
        return ((store.record["favorites"] as? [String] ?? []) + notes).filter { seen.insert($0).inserted && !store.isHidden($0) }
    }
    private var reports: [String] {
        (store.record["reports"] as? [[String: Any]] ?? []).compactMap { $0["roomID"] as? String }
    }
    private var hosts: [KakaNativeHost] {
        if !store.following.isEmpty { return store.following }
        var seen = Set<Int64>()
        return Array(store.knownRooms.values.compactMap(\.host)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.id).inserted }.prefix(6))
    }

    var body: some View {
        GeometryReader { geometry in
            let gutter: CGFloat = geometry.size.width < 350 ? 16 : 20
            let contentWidth = max(1, min(600, geometry.size.width - gutter * 2))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    identity(width: contentWidth)
                    if !error.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(error).font(.subheadline).foregroundStyle(KakaStudioCopy.error)
                            Button { Task { await load() } } label: {
                                Text("Try again")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Self.signal)
                                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    library
                    if !hosts.isEmpty { people(width: contentWidth) }
                    accountLinks
                }
                .frame(maxWidth: 600)
                .padding(.horizontal, gutter)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(KakaTheme.ink)
        .task { await load() }
        .sheet(item: $panel) { destination in
            switch destination {
            case .edit:
                KakaStudioProfileEditor(name: name, style: style, bio: bio, portrait: portrait) { name, bio in
                    remoteName = name
                    remoteBio = bio
                    error = ""
                } photoChanged: { portrait in
                    self.portrait = portrait
                }
            case .account:
                KakaStudioAccountView()
            case .wallet:
                KakaStudioWalletView()
            case .help:
                KakaStudioHelpView()
            }
        }
        .sheet(isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } })) {
            if let decision { KakaStudioDecisionSheet(decision: decision) }
        }
    }

    private func identity(width: CGFloat) -> some View {
        let stacked = textSize.isAccessibilitySize || width < 280
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    profilePortrait
                    Spacer(minLength: 0)
                    if !stacked { editProfileLink }
                }
                if !name.isEmpty || !style.isEmpty { profileCredit }
                if stacked { editProfileLink }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: min(208, max(164, width * 0.48)), alignment: .bottomLeading)
            .background {
                GeometryReader { artwork in
                    Image("ProfileSignalCover")
                        .resizable()
                        .scaledToFill()
                        .frame(width: artwork.size.width, height: artwork.size.height, alignment: .trailing)
                        .clipped()
                        .overlay {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0.43),
                                .init(color: KakaTheme.base.opacity(0.55), location: 0.63),
                                .init(color: KakaTheme.base.opacity(0.91), location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        }
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }

            if !bio.isEmpty {
                rowDivider
                Text(bio)
                    .font(.subheadline)
                    .foregroundStyle(KakaTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
        }
        .background(KakaTheme.base)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(KakaTheme.line)
                .allowsHitTesting(false)
        }
    }

    private var profilePortrait: some View {
        KakaNativeImage(asset: "member-mark.jpg", remote: portrait)
            .scaledToFill()
            .frame(width: 60, height: 60)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Self.signal.opacity(0.56), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var profileCredit: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !name.isEmpty {
                Text(name)
                    .font(.largeTitle.weight(.bold))
                    .tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)
            }
            if !style.isEmpty { Text(style).font(.subheadline).foregroundStyle(Self.signal) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var editProfileLink: some View {
        Button { panel = .edit } label: {
            HStack(spacing: 6) {
                KakaNativeImage(asset: "action-edit.png")
                    .scaledToFit()
                    .frame(width: 19, height: 19)
                    .accessibilityHidden(true)
                Text("Edit profile")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(KakaTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 44, minHeight: 44)
            .modifier(KakaGlass(interactive: !profileLoading, radius: 22, tint: KakaTheme.base.opacity(0.36)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit profile")
        .disabled(profileLoading)
        .opacity(profileLoading ? 0.52 : 1)
    }

    private var library: some View {
        let scores = drafts
        let rooms = savedRoomIDs
        return VStack(alignment: .leading, spacing: 10) {
            Text("Your crate").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                if scores.isEmpty {
                    KakaStudioRow(title: "Verse drafts", detail: "Write a verse", icon: "room-write.png", grouped: true) {
                        store.select(.write)
                    }
                } else {
                    draftCollection(scores)
                }
                rowDivider
                if rooms.isEmpty {
                    KakaStudioRow(title: "Rooms & notes", detail: "Find a room", icon: "action-bookmark.png", grouped: true) {
                        store.select(.live)
                    }
                } else {
                    savedRoomCollection(rooms)
                }
            }
            .background(KakaTheme.surface.opacity(0.58), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(KakaTheme.line)
                    .allowsHitTesting(false)
            }
            if !reports.isEmpty { hiddenRooms }
        }
    }

    private var rowDivider: some View {
        KakaTheme.line.frame(height: 1).padding(.horizontal, 13).accessibilityHidden(true)
    }

    private func draftCollection(_ scores: [KakaVerseScore]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            collectionHeading("Verse drafts", count: scores.count, tint: Self.signal)
                .padding(.horizontal, 13)
                .padding(.top, 13)
            LazyVStack(spacing: 0) {
                ForEach(scores, id: \.id) { draft in
                    HStack(spacing: 2) {
                        KakaStudioRow(title: draft.topic, detail: draft.detail, icon: "room-write.png", grouped: true) {
                            store.openDraft(draft.id)
                        }
                        KakaStudioIconButton(title: "Delete draft \(draft.topic)", image: "action-delete.png") {
                            decision = KakaStudioDecision(title: "Delete this draft?",
                                                          detail: "This will permanently remove “\(draft.topic)” from your drafts.",
                                                          button: "Delete draft") { Task { await removeDraft(draft.id) } }
                        }
                        .padding(.trailing, 6)
                        .disabled(changingRecords)
                    }
                }
            }
        }
    }

    private func savedRoomCollection(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            collectionHeading("Rooms & notes", count: ids.count, tint: Self.signal)
                .padding(.horizontal, 13)
                .padding(.top, 13)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    let note = (store.record["notes"] as? [[String: Any]])?
                        .first(where: { $0["roomID"] as? String == id })?["text"] as? String
                    if let room = store.knownRooms[id] {
                        KakaStudioRow(title: room.title, detail: note, icon: room.kind.actionArt, grouped: true) {
                            store.open(.room(room))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Room unavailable").font(.subheadline.weight(.semibold))
                            if let note { Text(note).font(.subheadline).foregroundStyle(KakaTheme.muted) }
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func collectionHeading(_ title: LocalizedStringKey, count: Int, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityLabel(count == 1 ? "1 item" : "\(count) items")
        }
    }

    private var hiddenRooms: some View {
        VStack(alignment: .leading, spacing: 8) {
            collectionHeading("Hidden rooms", count: reports.count, tint: KakaTheme.muted)
            LazyVStack(spacing: 2) {
                ForEach(reports, id: \.self) { id in
                    KakaStudioRow(title: store.knownRooms[id]?.title ?? "Unavailable room", detail: "Restore room", icon: nil, grouped: true) {
                        Task { await restoreRoom(id) }
                    }
                    .disabled(changingRecords)
                }
            }
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func people(width: CGFloat) -> some View {
        let cardWidth = min(width, textSize.isAccessibilitySize ? 184 : min(148, max(104, (width - 18) / 2.8)))
        return VStack(alignment: .leading, spacing: 10) {
            Text(store.following.isEmpty ? "Meet the hosts" : "Following")
                .font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(hosts, id: \.id) { host in
                        Button { store.open(.host(host)) } label: {
                            hostPortrait(host, width: cardWidth)
                                .frame(width: cardWidth, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View \(host.name)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hostPortrait(_ host: KakaNativeHost, width: CGFloat) -> some View {
        let artwork = KakaNativeImage(asset: "member-mark.jpg", remote: host.portrait)
            .scaledToFill()
            .frame(width: width, height: width * 1.16)
            .clipped()
            .accessibilityHidden(true)
        let name = Text(host.name)
            .font(.footnote.weight(.semibold))
            .lineLimit(textSize.isAccessibilitySize ? 3 : 2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)

        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                artwork.clipShape(RoundedRectangle(cornerRadius: 12))
                name
            }
        } else {
            artwork
                .overlay(alignment: .bottom) {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: KakaTheme.base.opacity(0.78), location: 0.46),
                        .init(color: KakaTheme.base.opacity(0.96), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: width * 0.65)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .overlay(alignment: .bottomLeading) {
                    name.padding(9)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var accountLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account & support").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                rowDivider
                KakaStudioRow(title: "Account settings", icon: nil, grouped: true) { panel = .account }
                rowDivider
                KakaStudioRow(title: "Wallet & rewards", icon: nil, grouped: true) { panel = .wallet }
                rowDivider
                KakaStudioRow(title: "Help center", icon: nil, grouped: true) { panel = .help }
                rowDivider
            }
        }
    }

    private func load() async {
        guard let token = store.session?.token else { return }
        profileLoading = true
        error = ""
        defer { profileLoading = false }
        do {
            let value = try await store.request("profile.read") as? [String: Any]
            guard !Task.isCancelled, store.session?.token == token else { return }
            let name = (value?["nickname"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteName = name?.isEmpty == false ? name : nil
            remoteBio = value?["cipherSeal"] as? String
            portrait = KakaStudioCopy.remoteURL(value?["cometGlyph"])
        } catch {
            if !Task.isCancelled, store.session?.token == token { self.error = store.message(error) }
        }
    }

    private func removeDraft(_ id: String) async {
        guard !changingRecords else { return }
        changingRecords = true
        defer { changingRecords = false }
        do {
            try await store.updateRecord { value in
                let rows = value["scores"] as? [[String: Any]] ?? []
                value["scores"] = rows.filter { $0["id"] as? String != id }
            }
            store.notify("Draft deleted.")
        } catch { store.notify(store.message(error)) }
    }

    private func restoreRoom(_ id: String) async {
        guard !changingRecords else { return }
        changingRecords = true
        defer { changingRecords = false }
        do {
            try await store.updateRecord { value in
                let rows = value["reports"] as? [[String: Any]] ?? []
                value["reports"] = rows.filter { $0["roomID"] as? String != id }
            }
            store.notify("Room restored.")
        } catch { store.notify(store.message(error)) }
    }
}

private struct KakaStudioRow: View {
    let title: String
    var detail: String? = nil
    let icon: String?
    var grouped = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                if let icon {
                    KakaNativeImage(asset: icon).scaledToFit().frame(width: 24, height: 24).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(KakaTheme.muted).lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
                KakaNativeImage(asset: "action-forward.png")
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .background(grouped ? Color.clear : KakaTheme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private final class KakaStudioPresenter: ObservableObject {
    weak var anchor: UIViewController?

    var controller: UIViewController? {
        guard var owner = anchor, let window = owner.viewIfLoaded?.window else { return nil }
        while let parent = owner.parent, parent.viewIfLoaded?.window === window {
            owner = parent
        }
        return owner
    }
}

private struct KakaStudioPresenterAnchor: UIViewControllerRepresentable {
    let presenter: KakaStudioPresenter

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        presenter.anchor = controller
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

private struct KakaStudioProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KakaNativeStore
    @StateObject private var presenter = KakaStudioPresenter()
    @State private var name: String
    @State private var style: String
    @State private var bio: String
    @State private var portrait: URL?
    let changed: (String, String) -> Void
    let photoChanged: (URL) -> Void
    @State private var busy = false
    @State private var error = ""

    init(name: String, style: String, bio: String, portrait: URL?, changed: @escaping (String, String) -> Void,
         photoChanged: @escaping (URL) -> Void) {
        _name = State(initialValue: name)
        _style = State(initialValue: style)
        _bio = State(initialValue: bio)
        _portrait = State(initialValue: portrait)
        self.changed = changed
        self.photoChanged = photoChanged
    }

    var body: some View {
        KakaStudioSheet(title: "Edit profile") {
            HStack(spacing: 13) {
                KakaNativeImage(asset: "member-mark.jpg", remote: portrait)
                    .scaledToFill()
                    .frame(width: 66, height: 66)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                KakaStudioButton(title: "Change photo", icon: "action-edit.png") {
                    Task { await choosePhoto() }
                }
                .disabled(busy)
            }
            Text("Stage name").font(.headline)
            TextField("Stage name", text: $name).modifier(KakaStudioField())
            Text("Style").font(.headline)
            TextField("Style", text: $style).modifier(KakaStudioField())
            Text("Bio").font(.headline)
            TextEditor(text: $bio).modifier(KakaStudioEditor()).modifier(KakaStudioField())
                .frame(minHeight: 104).accessibilityLabel("Bio")
            if !error.isEmpty { Text(error).foregroundStyle(KakaStudioCopy.error) }
            KakaStudioButton(title: busy ? "Please wait…" : "Save changes", icon: "action-check.png", emphasis: true) {
                Task { await save() }
            }
            .disabled(busy)
        }
        .background(KakaStudioPresenterAnchor(presenter: presenter).allowsHitTesting(false).accessibilityHidden(true))
        .interactiveDismissDisabled(busy)
    }

    private func save() async {
        guard let token = store.session?.token, !busy else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...24).contains(name.utf16.count) else { error = "Use 1–24 characters for your stage name."; return }
        guard bio.utf16.count <= 120 else { error = "Use up to 120 characters for your bio."; return }
        guard style.utf16.count <= 20 else { error = "Use up to 20 characters for your style."; return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            _ = try await store.request("profile.update", ["nickname": name, "cipherSeal": bio])
            guard store.session?.token == token else { return }
            changed(name, bio)
            try await store.updateRecord { $0["profile"] = ["name": name, "bio": bio, "style": style] }
            guard store.session?.token == token else { return }
            store.notify("Profile saved.")
            dismiss()
        } catch {
            if store.session?.token == token { self.error = store.message(error) }
        }
    }

    private func choosePhoto() async {
        guard let token = store.session?.token, let controller = presenter.controller, !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let data = try await KakaAvatarUpload.shared.pick(from: controller, session: token)
            guard store.session?.token == token else { return }
            let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if value is NSNull { return }
            guard let photo = KakaStudioCopy.remoteURL((value as? [String: Any])?["portrait"]) else {
                throw KakaStudioIssue(text: "Couldn’t update the profile photo.")
            }
            portrait = photo
            photoChanged(photo)
            store.notify("Profile photo updated.")
        } catch {
            if store.session?.token == token { self.error = store.message(error) }
        }
    }
}

private struct KakaStudioAccountView: View {
    @EnvironmentObject private var store: KakaNativeStore
    @State private var selectedPolicy: KakaNativePolicy?
    @State private var decision: KakaStudioDecision?
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        KakaStudioSheet(title: "Account settings") {
            if let session = store.session {
                Text(session.email).font(.subheadline).foregroundStyle(KakaTheme.muted)
            }
            KakaStudioRow(title: "Terms of Use", icon: nil) { selectedPolicy = .terms }
            KakaStudioRow(title: "Privacy Policy", icon: nil) { selectedPolicy = .privacy }
            if !error.isEmpty { Text(error).foregroundStyle(KakaStudioCopy.error) }
            KakaStudioButton(title: "Sign out") {
                decision = KakaStudioDecision(title: "Sign out?", detail: "Your drafts will be available when you sign back in.",
                                              button: "Sign out") { Task { await leave(deleting: false) } }
            }
            .disabled(busy)
            KakaStudioButton(title: "Delete account", icon: "action-delete.png") {
                decision = KakaStudioDecision(title: "Delete your account?",
                                              detail: "Your profile and saved work are associated with this account.",
                                              button: "Delete account") { Task { await leave(deleting: true) } }
            }
            .disabled(busy)
            if busy { Text("Please wait…").foregroundStyle(KakaTheme.muted) }
        }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: Binding(get: { selectedPolicy != nil }, set: { if !$0 { selectedPolicy = nil } })) {
            if let selectedPolicy { KakaNativePolicyView(policy: selectedPolicy) }
        }
        .sheet(isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } })) {
            if let decision { KakaStudioDecisionSheet(decision: decision) }
        }
    }

    private func leave(deleting: Bool) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            try await store.signOut(deleting: deleting)
        } catch let failure as KakaAccountStore.Failure where deleting && failure == .unavailable {
            error = "Account deletion is currently unavailable."
        } catch {
            self.error = store.message(error)
        }
    }
}

private struct KakaStudioHelpView: View {
    private struct FAQ: Identifiable {
        let id: Int
        let title: String
        let answer: String
    }

    @EnvironmentObject private var store: KakaNativeStore
    @State private var questions: [FAQ] = []
    @State private var expanded = Set<Int>()
    @State private var status = "Loading help topics…"
    @State private var retry = false

    var body: some View {
        KakaStudioSheet(title: "Help center") {
            if !status.isEmpty { Text(status).foregroundStyle(KakaTheme.muted) }
            if retry { KakaStudioButton(title: "Try again") { Task { await load() } } }
            ForEach(questions) { faq in
                KakaStudioRow(title: faq.title, icon: nil) {
                    if !expanded.insert(faq.id).inserted { expanded.remove(faq.id) }
                }
                if expanded.contains(faq.id) {
                    Text(faq.answer).font(.subheadline).foregroundStyle(KakaTheme.muted).padding(.horizontal, 10)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        status = "Loading help topics…"
        retry = false
        do {
            let result = try await store.request("support.faq")
            let value = result as? [String: Any]
            let rows = result as? [[String: Any]] ?? ["gridBands", "records", "roster", "data"]
                .compactMap { value?[$0] as? [[String: Any]] }.first ?? []
            questions = rows.enumerated().compactMap { index, row in
                guard let title = row["anomalyHeader"] as? String, let answer = row["signalResponse"] as? String else { return nil }
                return FAQ(id: index, title: title, answer: answer)
            }
            status = questions.isEmpty ? "No help topics are available right now." : ""
        } catch {
            status = store.message(error)
            retry = true
        }
    }
}

private struct KakaStudioWalletView: View {
    private struct Pack: Identifiable {
        let id: String
        let diamonds: String
        let bonus: String
        let firstBonus: String
        let price: String
        let available: Bool

        init?(_ raw: [String: Any]) {
            guard let id = raw["id"] as? String, let diamonds = raw["diamonds"] as? String,
                  let price = raw["price"] as? String else { return nil }
            self.id = id
            self.diamonds = diamonds
            self.bonus = raw["bonus"] as? String ?? "0"
            self.firstBonus = raw["firstBonus"] as? String ?? "0"
            self.price = price
            self.available = raw["available"] as? Bool == true
        }

        var note: String {
            var parts: [String] = []
            if bonus != "0" { parts.append("+\(bonus) bonus") }
            if firstBonus != "0" { parts.append("+\(firstBonus) on your first purchase") }
            return parts.joined(separator: " · ")
        }
    }

    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var balance: String?
    @State private var walletError = ""
    @State private var packs: [Pack] = []
    @State private var packStatus = "Loading recharge packs…"
    @State private var level = ""
    @State private var reward = ""
    @State private var canClaim = false
    @State private var state = ""
    @State private var status = ""
    @State private var updating = false
    @State private var actionInProgress = false
    @State private var pollRevision = 0

    private static let displayStatus = [
        "apple": "Continue in the App Store purchase sheet.",
        "deferred": "Waiting for Apple approval.",
        "verifying": "Verifying your purchase…",
        "pending": "Your purchase is waiting for confirmation.",
        "complete": "Purchase confirmed.",
        "failed": "The App Store could not complete the request.",
        "cancelled": "Cancelled.",
        "restoring": "Checking for purchases with Apple…",
        "restored": "Restore check finished.",
        "wrongAccount": "Sign in to the account that started this purchase to finish it.",
    ]

    private var awaitingApple: Bool { ["apple", "verifying", "restoring"].contains(state) }
    private var awaitingUpdate: Bool { awaitingApple || state == "pending" }
    private var disabled: Bool { actionInProgress || updating }

    var body: some View {
        KakaStudioSheet(title: "Wallet & rewards") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Diamond balance").font(.subheadline.weight(.semibold)).foregroundStyle(KakaTheme.muted)
                Text(balance ?? (walletError.isEmpty ? "Loading…" : "Unavailable"))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                if !level.isEmpty { Text(level).font(.subheadline).foregroundStyle(KakaTheme.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .modifier(KakaGlass(radius: 20))

            if !walletError.isEmpty {
                Text(walletError).foregroundStyle(KakaStudioCopy.error)
                KakaStudioButton(title: "Try again") { Task { await refresh() } }.disabled(disabled)
            }

            Text("Recharge").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            if !packStatus.isEmpty { Text(packStatus).foregroundStyle(KakaTheme.muted) }
            ForEach(packs) { pack in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(pack.diamonds) diamonds").font(.headline)
                    if !pack.note.isEmpty { Text(pack.note).font(.caption).foregroundStyle(KakaTheme.muted) }
                    KakaStudioButton(title: pack.price, emphasis: true) {
                        Task { await perform("purchase", data: ["productID": pack.id]) }
                    }
                    .disabled(disabled || awaitingApple || !pack.available)
                    .accessibilityLabel("Buy \(pack.diamonds) diamonds for \(pack.price)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(KakaTheme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 15))
            }
            KakaStudioButton(title: "Restore purchases") { Task { await perform("restore") } }
                .disabled(disabled || awaitingApple)
            if !status.isEmpty { Text(status).font(.subheadline).foregroundStyle(KakaTheme.muted) }

            Text("Daily rewards").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            if !reward.isEmpty { Text(reward).foregroundStyle(KakaTheme.muted) }
            if canClaim {
                KakaStudioButton(title: "Claim reward", emphasis: true) { Task { await perform("claimReward") } }
                    .disabled(disabled)
            }
        }
        .task { await refresh() }
        .task(id: pollRevision) { await poll() }
        .onChange(of: scenePhase) { phase in
            if phase == .active, !disabled {
                if awaitingUpdate { pollRevision += 1 }
                else { Task { await reloadBalance() } }
            } else if phase != .active {
                pollRevision += 1
            }
        }
    }

    private func request(_ operation: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        guard let result = try await store.request("commerce." + operation, payload) as? [String: Any] else {
            throw KakaStudioIssue(text: "The wallet response could not be opened.")
        }
        return result
    }

    private func updateState(_ result: [String: Any]) {
        state = result["purchaseState"] as? String ?? ""
        status = Self.displayStatus[state] ?? ""
    }

    private func reloadBalance() async {
        do {
            let value = try await request("wallet")
            guard !Task.isCancelled else { return }
            guard let amount = value["balance"] as? String else {
                throw KakaStudioIssue(text: "Wallet unavailable.")
            }
            balance = amount
            walletError = ""
            updateState(value)
        } catch {
            if !Task.isCancelled { walletError = store.message(error) }
        }
    }

    private func refresh() async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        walletError = ""
        await reloadBalance()
        guard !Task.isCancelled else { return }
        do {
            let catalog = try await request("catalog")
            guard !Task.isCancelled else { return }
            packs = (catalog["packs"] as? [[String: Any]] ?? []).compactMap(Pack.init)
            let missing = (catalog["missingAppleProducts"] as? Int ?? 0) > 0
            packStatus = packs.isEmpty ? (missing ? "Recharge packs aren’t available in the App Store." : "No recharge packs are available.")
                : (missing ? "Some packs are unavailable in the App Store." : "")
        } catch {
            if !Task.isCancelled { packStatus = "Recharge packs are unavailable." }
        }
        guard !Task.isCancelled else { return }
        await reloadRewards()
        guard !Task.isCancelled else { return }
        if let value = try? await request("level"), !Task.isCancelled {
            level = value["tierTitle"] as? String ?? "Level unavailable."
        } else if !Task.isCancelled {
            level = "Level unavailable."
        }
        if awaitingUpdate { pollRevision += 1 }
    }

    private func reloadRewards() async {
        do {
            let value = try await request("rewards")
            guard !Task.isCancelled else { return }
            let locked = permitted(value["orbitBound"])
            canClaim = permitted(value["castPermit"]) && !locked
            if permitted(value["dawnMarked"]) { reward = "Checked in today." }
            else if locked { reward = "Daily rewards unlock at Level 1." }
            else if canClaim { reward = "Your daily reward is available." }
            else { reward = "No reward is available right now." }
        } catch {
            if !Task.isCancelled {
                canClaim = false
                reward = "Daily rewards unavailable."
            }
        }
    }

    private func permitted(_ value: Any?) -> Bool {
        value as? Bool == true || value as? Int == 1 || ["true", "1"].contains(value as? String ?? "")
    }

    private func perform(_ operation: String, data: [String: Any] = [:]) async {
        guard !disabled, !awaitingApple, let token = store.session?.token else { return }
        actionInProgress = true
        defer { actionInProgress = false }
        let busyCopy = ["purchase": "Starting purchase…", "restore": "Checking purchases…", "claimReward": "Claiming reward…"]
        status = busyCopy[operation] ?? ""
        do {
            let response = try await request(operation, data)
            guard store.session?.token == token else { return }
            if operation == "claimReward" {
                await reloadBalance()
                await reloadRewards()
                if store.session?.token == token { status = "Reward claimed." }
            } else {
                updateState(response)
                pollRevision += 1
            }
        } catch {
            if store.session?.token == token { status = store.message(error) }
        }
    }

    private func poll() async {
        guard pollRevision > 0, scenePhase == .active else { return }
        for _ in 0..<9 {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            if disabled { continue }
            await reloadBalance()
            if !awaitingUpdate, walletError.isEmpty { return }
        }
    }
}

struct KakaNativeHostView: View {
    @EnvironmentObject private var store: KakaNativeStore
    let host: KakaNativeHost
    @State private var refreshed: KakaNativeHost?
    @State private var blocked: Bool?
    @State private var profileError = ""
    @State private var blockError = ""
    @State private var busy = false
    @State private var showChat = false
    @State private var decision: KakaStudioDecision?

    private var current: KakaNativeHost { refreshed ?? host }
    private var following: Bool { store.followedIDs.contains(host.id) }
    private var rooms: [KakaNativeRoom] {
        store.knownRooms.values.filter { $0.host?.id == host.id && !store.isHidden($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                ZStack(alignment: .bottomLeading) {
                    KakaNativeImage(asset: "member-mark.jpg", remote: current.portrait)
                        .scaledToFill()
                        .frame(height: 224)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(current.name).font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
                        if !current.style.isEmpty { Text(current.style).font(.subheadline).foregroundStyle(KakaTheme.muted) }
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(KakaGlass(radius: 16))
                    .padding(11)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                if !current.bio.isEmpty { Text(current.bio).foregroundStyle(KakaTheme.muted) }
                if !profileError.isEmpty {
                    Text(profileError).foregroundStyle(KakaStudioCopy.error)
                    KakaStudioButton(title: "Retry profile") { Task { await loadProfile() } }
                }
                if blocked == false {
                    KakaStudioButton(title: following ? "Unfollow" : "Follow", emphasis: true) { Task { await toggleFollow() } }
                        .accessibilityAddTraits(following ? .isSelected : [])
                        .disabled(busy)
                    KakaStudioButton(title: showChat ? "Hide messages" : "Message") { showChat.toggle() }
                        .disabled(busy)
                }
                if let blocked {
                    KakaStudioButton(title: blocked ? "Unblock" : "Block") { askToBlock(!blocked) }
                        .disabled(busy)
                } else if !blockError.isEmpty {
                    KakaStudioButton(title: "Retry block settings") { Task { await loadBlockStatus() } }
                        .disabled(busy)
                }
                if !blockError.isEmpty { Text(blockError).foregroundStyle(KakaStudioCopy.error) }
                if showChat, blocked == false { KakaNativeChatView(hostID: host.id) }
                Text("Hosted rooms").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                if rooms.isEmpty { Text("No rooms to show.").foregroundStyle(KakaTheme.muted) }
                ForEach(rooms) { room in
                    KakaStudioRow(title: room.title, detail: room.format,
                                  icon: room.kind == .live ? "room-watch.png" : "room-listen.png") {
                        store.open(.room(room))
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(KakaTheme.ink)
        .task(id: host.id) {
            await loadProfile()
            await loadBlockStatus()
        }
        .sheet(isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } })) {
            if let decision { KakaStudioDecisionSheet(decision: decision) }
        }
    }

    private func loadProfile() async {
        guard let token = store.session?.token else { return }
        profileError = ""
        do {
            let result = try await store.request("getHost", ["voyagerBadge": host.id])
            guard !Task.isCancelled, store.session?.token == token else { return }
            guard let response = result as? [String: Any],
                  let verified = KakaNativeHost.parse(response, expectedID: host.id) else {
                throw KakaStudioIssue(text: "This host could not be verified.")
            }
            refreshed = KakaNativeHost(id: host.id, name: verified.name == "Host" ? host.name : verified.name,
                                       bio: verified.bio.isEmpty ? host.bio : verified.bio,
                                       portrait: verified.portrait ?? host.portrait,
                                       style: verified.style.isEmpty ? host.style : verified.style)
        } catch {
            if !Task.isCancelled, store.session?.token == token { profileError = store.message(error) }
        }
    }

    private func loadBlockStatus() async {
        guard let token = store.session?.token, !busy else { return }
        blockError = ""
        busy = true
        defer { busy = false }
        do {
            let result = try await store.request("creator.blocked", ["userID": host.id])
            guard !Task.isCancelled, store.session?.token == token else { return }
            guard let value = result as? Bool else { throw KakaStudioIssue(text: "Couldn’t load block settings.") }
            blocked = value
            if value { showChat = false }
        } catch {
            if !Task.isCancelled, store.session?.token == token { blockError = store.message(error) }
        }
    }

    private func askToBlock(_ block: Bool) {
        if block {
            decision = KakaStudioDecision(title: "Block \(current.name)?", detail: "Their messages will be hidden in room chat.",
                                          button: "Block user") { Task { await applyBlock(true) } }
        } else {
            Task { await applyBlock(false) }
        }
    }

    private func applyBlock(_ value: Bool) async {
        guard !busy, let token = store.session?.token else { return }
        busy = true
        defer { busy = false }
        blockError = ""
        if value { showChat = false }
        do {
            _ = try await store.request("creator.block", ["userID": host.id, "blocked": value])
            guard store.session?.token == token else { return }
            blocked = value
            store.notify(value ? "User blocked." : "User unblocked.")
        } catch {
            if store.session?.token == token { blockError = store.message(error) }
        }
    }

    private func toggleFollow() async {
        guard !busy, let token = store.session?.token else { return }
        busy = true
        defer { busy = false }
        do {
            try await store.toggleFollow(current)
            guard store.session?.token == token else { return }
            store.notify(following ? "Added to Following." : "Removed from Following.")
        } catch {
            if store.session?.token == token { store.notify(store.message(error)) }
        }
    }
}
