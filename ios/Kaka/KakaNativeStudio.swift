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
    @EnvironmentObject private var store: KakaNativeStore
    @State private var sheetID = UUID()
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
        .onAppear { store.setSheet(sheetID, presented: true) }
        .onDisappear { store.setSheet(sheetID, presented: false) }
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
                VStack(alignment: .trailing, spacing: 8) {
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
            HStack(spacing: 10) {
                KakaNativeImage(asset: "action-tune.png")
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .frame(width: 48, height: 48)
                    .modifier(KakaGlass(interactive: true, radius: 14))
                    .accessibilityHidden(true)
                Text("\(tempo) BPM · \(length) bars")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Self.signal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Verse settings")
        .accessibilityValue("\(tempo) BPM, \(length) bars")
    }

    private var draftVerseButton: some View {
        let busy = generating != nil || saving
        return Button(action: submit) {
            KakaNativeImage(asset: "action-draft.png")
                .scaledToFit()
                .frame(width: 31, height: 31)
                .opacity(busy ? 0.48 : 1)
                .frame(width: 58, height: 52)
                .modifier(KakaGlass(interactive: !busy, radius: 16,
                                    tint: busy ? nil : KakaTheme.actionFill.opacity(0.62)))
                .background(KakaTheme.actionFill.opacity(busy ? 0.12 : 0.42),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(generating == nil ? "Draft verse" : "Drafting verse")
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
        case edit, account, wallet, help, messages
        var id: String { rawValue }
    }

    private enum CrateCollection: Equatable {
        case verses, rooms

        var title: LocalizedStringKey { self == .verses ? "Verse drafts" : "Rooms & notes" }
        var artwork: String { self == .verses ? "profile-crate-verses.jpg" : "profile-crate-rooms.jpg" }
        var accent: Color { self == .verses ? KakaTheme.accent : KakaTheme.voiceAccent }
    }

    private struct CardPress: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? 0.78 : 1)
        }
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
                    library(width: contentWidth)
                    if !hosts.isEmpty { people(width: contentWidth) }
                    accountLinks(width: contentWidth)
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
            case .messages:
                KakaInbox()
            }
        }
        .sheet(isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } })) {
            if let decision { KakaStudioDecisionSheet(decision: decision) }
        }
    }

    private func identity(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    profilePortrait
                    Spacer(minLength: 0)
                    editProfileLink
                }
                if !name.isEmpty || !style.isEmpty { profileCredit }
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
            KakaNativeImage(asset: "action-edit.png")
                .scaledToFit()
                .frame(width: 26, height: 26)
                .frame(width: 48, height: 48)
                .modifier(KakaGlass(interactive: !profileLoading, radius: 19, tint: KakaTheme.base.opacity(0.28)))
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit profile")
        .disabled(profileLoading)
        .opacity(profileLoading ? 0.52 : 1)
    }

    private func library(width: CGFloat) -> some View {
        let scores = drafts
        let rooms = savedRoomIDs
        let sideBySide = width >= 316 && !textSize.isAccessibilitySize && scores.isEmpty && rooms.isEmpty
        let cardWidth = sideBySide ? (width - 12) / 2 : width
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
                            count: sideBySide ? 2 : 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Your crate").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 12) {
                crateCard(.verses, count: scores.count, width: cardWidth, coverAbove: sideBySide,
                          open: { store.select(.write) }) {
                    draftCollection(scores)
                }
                crateCard(.rooms, count: rooms.count, width: cardWidth, coverAbove: sideBySide,
                          open: { store.select(.live) }) {
                    savedRoomCollection(rooms)
                }
            }
            if !reports.isEmpty { hiddenRooms }
        }
    }

    private func crateCard<Records: View>(_ collection: CrateCollection, count: Int, width: CGFloat, coverAbove: Bool,
                                          open: @escaping () -> Void, @ViewBuilder records: () -> Records) -> some View {
        let frame = RoundedRectangle(cornerRadius: 17, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            if count == 0 {
                Button(action: open) {
                    crateCover(collection, count: count, width: width, coverAbove: coverAbove)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CardPress())
                .accessibilityLabel(Text(collection.title))
                .accessibilityHint(collection == .verses ? "Opens the verse editor" : "Opens live rooms")
            } else {
                crateCover(collection, count: count, width: width, coverAbove: coverAbove)
                rowDivider
                records()
            }
        }
        .background(collection.accent.opacity(0.10), in: frame)
        .clipShape(frame)
        .overlay { frame.strokeBorder(collection.accent.opacity(0.23)).allowsHitTesting(false) }
    }

    private func crateCover(_ collection: CrateCollection, count: Int, width: CGFloat, coverAbove: Bool) -> some View {
        let artworkWidth = coverAbove ? width : min(118, width * 0.32)
        let artworkHeight = coverAbove ? min(190, width * 0.72) : max(64, artworkWidth * 0.78)
        let artwork = KakaNativeImage(asset: collection.artwork)
            .scaledToFill()
            .frame(width: artworkWidth, height: artworkHeight)
            .clipped()
            .accessibilityHidden(true)
        let title = HStack(spacing: 7) {
            Text(collection.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(count > 0 ? .isHeader : [])
            if count > 0 {
                Text("\(count)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(collection.accent)
                    .accessibilityLabel(count == 1 ? "1 item" : "\(count) items")
            } else {
                KakaNativeImage(asset: "action-forward.png")
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 51)
        return Group {
            if coverAbove {
                VStack(spacing: 0) {
                    artwork
                    title
                }
            } else {
                HStack(spacing: 0) {
                    artwork
                    title
                }
            }
        }
    }

    private var rowDivider: some View {
        KakaTheme.line.frame(height: 1).padding(.horizontal, 13).accessibilityHidden(true)
    }

    private func draftCollection(_ scores: [KakaVerseScore]) -> some View {
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

    private func savedRoomCollection(_ ids: [String]) -> some View {
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
                        .buttonStyle(CardPress())
                        .accessibilityLabel("View \(host.name)")
                    }
                }
            }
        }
    }

    private func hostPortrait(_ host: KakaNativeHost, width: CGFloat) -> some View {
        let frame = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            KakaNativeImage(asset: "member-mark.jpg", remote: host.portrait)
                .scaledToFill()
                .frame(width: width, height: width * 0.99)
                .clipped()
                .accessibilityHidden(true)
            Text(host.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(textSize.isAccessibilitySize ? 3 : 2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .background(KakaTheme.surface, in: frame)
        .clipShape(frame)
        .overlay { frame.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
    }

    private func accountLinks(width: CGFloat) -> some View {
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10),
                            count: width >= 310 && !textSize.isAccessibilitySize ? 2 : 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Account & support").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 10) {
                accountCard("Messages", artwork: "profile-card-messages.png", destination: .messages)
                accountCard("Account settings", artwork: "profile-card-account.png", destination: .account)
                accountCard("Wallet & rewards", artwork: "profile-card-wallet.png", destination: .wallet)
                accountCard("Help center", artwork: "profile-card-help.png", destination: .help)
            }
        }
    }

    private func accountCard(_ title: LocalizedStringKey, artwork: String, destination: Panel) -> some View {
        let frame = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { panel = destination } label: {
            HStack(spacing: 7) {
                KakaNativeImage(asset: artwork)
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(minHeight: 80)
            .background(KakaTheme.surface, in: frame)
            .overlay { frame.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
            .contentShape(frame)
        }
        .buttonStyle(CardPress())
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
final class KakaStudioPresenter: ObservableObject {
    weak var anchor: UIViewController?

    var controller: UIViewController? {
        guard var owner = anchor, let window = owner.viewIfLoaded?.window else { return nil }
        while let parent = owner.parent, parent.viewIfLoaded?.window === window {
            owner = parent
        }
        return owner
    }
}

struct KakaStudioPresenterAnchor: UIViewControllerRepresentable {
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
    @ObservedObject private var notifications = KakaPushNotifications.shared
    @AppStorage(KakaCallPreferences.incomingEnabled) private var acceptsCalls = true
    @State private var selectedPolicy: KakaNativePolicy?
    @State private var decision: KakaStudioDecision?
    @State private var showingCallHistory = false
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        KakaStudioSheet(title: "Account settings") {
            if let session = store.session {
                Text(session.email).font(.subheadline).foregroundStyle(KakaTheme.muted)
            }
            KakaStudioRow(title: "Terms of Use", icon: nil) { selectedPolicy = .terms }
            KakaStudioRow(title: "Privacy Policy", icon: nil) { selectedPolicy = .privacy }
            KakaStudioRow(title: acceptsCalls ? "Incoming video calls on" : "Incoming video calls off", icon: nil) {
                acceptsCalls.toggle()
            }
            .accessibilityHint("Changes whether this device shows incoming calls")
            KakaStudioRow(title: notifications.settingsTitle, icon: nil) {
                if let token = store.session?.token { Task { await notifications.openSettings(session: token) } }
            }
            if notifications.registrationIssue {
                Text("This device couldn’t register for push notifications.")
                    .font(.footnote).foregroundStyle(KakaTheme.muted)
            }
            KakaStudioRow(title: "Call history", icon: nil) { showingCallHistory = true }
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
        .sheet(isPresented: $showingCallHistory) { KakaPrivateCallHistoryScreen() }
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

@MainActor
struct KakaStudioHelpView: View {
    private struct FAQ: Identifiable {
        let id: Int
        let title: String
        let answer: String
        let action: Action?

        enum Action {
            case copy(String)
            case open(KakaDirectoryCampaign.Destination)
        }
    }

    @EnvironmentObject private var store: KakaNativeStore
    @State private var questions: [FAQ] = []
    @State private var expanded = Set<Int>()
    @State private var status = "Loading help topics…"
    @State private var retry = false
    @State private var destination: KakaDirectoryCampaign.Destination?
    @State private var copiedFAQ: Int?

    var body: some View {
        KakaStudioSheet(title: "Help center") {
            KakaStudioButton(title: "Contact support", emphasis: true) { destination = .support }
            if !status.isEmpty { Text(status).foregroundStyle(KakaTheme.muted) }
            if retry { KakaStudioButton(title: "Try again") { Task { await load() } } }
            ForEach(questions) { faq in
                KakaStudioRow(title: faq.title, icon: nil) {
                    if !expanded.insert(faq.id).inserted { expanded.remove(faq.id) }
                }
                if expanded.contains(faq.id) {
                    if !faq.answer.isEmpty {
                        Text(verbatim: faq.answer).font(.subheadline).foregroundStyle(KakaTheme.muted).padding(.horizontal, 10)
                    }
                    switch faq.action {
                    case .copy(let value):
                        KakaStudioButton(title: copiedFAQ == faq.id ? "Copied" : "Copy answer") {
                            UIPasteboard.general.string = value
                            copiedFAQ = faq.id
                        }
                    case .open(let target):
                        KakaStudioButton(title: target.accessibilityLabel) { destination = target }
                    case nil:
                        EmptyView()
                    }
                }
            }
        }
        .task(id: store.session?.token) {
            questions = []
            expanded = []
            copiedFAQ = nil
            destination = nil
            await load()
        }
        .sheet(item: $destination) { target in
            switch target {
            case .support:
                KakaStudioSheet(title: "Contact support") { KakaNativeChatView() }
            case .wallet:
                KakaStudioWalletView()
            case .backpack:
                KakaStudioGiftBackpackView()
            case .page(let url):
                KakaCampaignPage(target: url)
            case .external:
                EmptyView()
            }
        }
    }

    private func load() async {
        guard let session = store.session?.token else { return }
        status = "Loading help topics…"
        retry = false
        do {
            let result = try await store.request("support.faq")
            guard store.session?.token == session, !Task.isCancelled else { return }
            let value = result as? [String: Any]
            let rows = result as? [[String: Any]] ?? ["gridBands", "records", "roster", "data"]
                .compactMap { value?[$0] as? [[String: Any]] }.first ?? []
            questions = rows.enumerated().compactMap { index, row in
                let title = KakaRoomFields.text(row, "anomalyTitle", "anomalyHeader").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let answer = KakaRoomFields.text(row, "signalResponse")
                let value = KakaRoomFields.text(row, "maneuverBrief")
                let action: FAQ.Action?
                switch row["maneuver"] as? String {
                case "copy" where !value.isEmpty:
                    action = .copy(value)
                case "page":
                    action = KakaDirectoryCampaign.internalDestination(value).map(FAQ.Action.open)
                default:
                    action = nil
                }
                guard !answer.isEmpty || action != nil else { return nil }
                return FAQ(id: index, title: title, answer: answer, action: action)
            }
            status = questions.isEmpty ? "No help topics are available right now." : ""
        } catch {
            guard store.session?.token == session, !Task.isCancelled else { return }
            status = store.message(error)
            retry = true
        }
    }
}

@MainActor
struct KakaStudioGiftBackpackView: View {
    private struct Gift: Identifiable {
        let id: Int64
        let name: String
        let count: Int64
        let expires: String
        let image: URL?

        init?(_ row: [String: Any], owner: Int64) {
            guard let id = KakaRoomFields.id(row, keys: ["fanSatchel"]),
                  let count = KakaRemoteClient.userID(row["cosmicCount"]), count > 0 else { return nil }
            if let marker = row["voyagerBadge"], !(marker is NSNull), KakaRemoteClient.userID(marker) != owner { return nil }
            let name = KakaRoomFields.text(row, "voyagerLabel").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            self.id = id
            self.count = count
            self.name = String(name.prefix(120))
            let validity = KakaRemoteClient.userID(row["intervalTicks"])
            let description = KakaRoomFields.text(row, "countdownBrief")
            expires = validity == -1 && description.isEmpty ? "No expiry" : String(description.prefix(120))
            image = KakaRoomFields.url(KakaRoomFields.text(row, "orbitGlyph"))
        }
    }

    @EnvironmentObject private var store: KakaNativeStore
    @State private var gifts: [Gift] = []
    @State private var page: Int? = 1
    @State private var requestID: UUID?
    @State private var status = ""
    private let pageSize = 20

    var body: some View {
        KakaStudioSheet(title: "Gift backpack") {
            ForEach(gifts) { gift in
                HStack(alignment: .top, spacing: 14) {
                    KakaNativeImage(asset: "Dock-crate", remote: gift.image)
                        .scaledToFit().frame(width: 42, height: 42).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: gift.name).font(.subheadline.weight(.semibold))
                        Text("\(gift.count) in backpack").font(.subheadline).foregroundStyle(KakaTheme.muted)
                        if !gift.expires.isEmpty { Text(verbatim: gift.expires).font(.caption).foregroundStyle(KakaTheme.muted) }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .padding(.vertical, 4)
            }
            if requestID != nil { KakaRhythmProgress(title: "Loading backpack") }
            if !status.isEmpty { Text(status).foregroundStyle(KakaTheme.muted) }
            if requestID == nil, page != nil {
                KakaStudioButton(title: status.isEmpty ? "Load more gifts" : "Try again") { Task { await load() } }
            }
        }
        .task(id: store.session?.token) {
            requestID = nil
            page = 1
            gifts = []
            status = ""
            await load()
        }
    }

    private func load() async {
        guard requestID == nil, let page, let session = store.session?.token else { return }
        let request = UUID()
        requestID = request
        status = ""
        defer { if requestID == request { requestID = nil } }
        do {
            let owner = try await KakaAccountStore.shared.remoteUserID(session: session)
            guard requestID == request, store.session?.token == session, !Task.isCancelled else { return }
            let response = try await store.request("gift.backpack", ["horizon": "", "folio": page, "folioScale": pageSize])
            guard requestID == request, store.session?.token == session, !Task.isCancelled else { return }
            guard let result = response as? [String: Any] else { throw KakaAccountStore.Failure.rejected }
            let rows = KakaRoomFields.rows(result, keys: ["gridBands"])
            var seen = Set(gifts.map(\.id))
            let next = rows.compactMap { Gift($0, owner: owner) }.filter { seen.insert($0.id).inserted }
            gifts.append(contentsOf: next)
            self.page = rows.count == pageSize ? page + 1 : nil
            if gifts.isEmpty, self.page == nil { status = "Your gift backpack is empty." }
        } catch {
            guard requestID == request, store.session?.token == session, !Task.isCancelled else { return }
            status = store.message(error)
        }
    }
}

struct KakaStudioWalletView: View {
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
    private struct ActiveRoom: Identifiable {
        let kind: KakaNativeRoom.Kind
        let roomID: Int64
        var id: String { kind.rawValue }
    }

    @EnvironmentObject private var store: KakaNativeStore
    let host: KakaNativeHost
    @State private var refreshed: KakaNativeHost?
    @State private var blocked: Bool?
    @State private var profileError = ""
    @State private var blockError = ""
    @State private var busy = false
    @State private var showChat = false
    @State private var activeRooms: [ActiveRoom] = []
    @State private var joiningRoom: KakaNativeRoom.Kind?
    @State private var decision: KakaStudioDecision?

    private var current: KakaNativeHost { refreshed ?? host }
    private var following: Bool { store.followedIDs.contains(host.id) }
    private var rooms: [KakaNativeRoom] {
        store.knownRooms.values.filter { room in
            room.host?.id == host.id && !store.isHidden(room.id) && !store.isLiveEnded(room)
                && !activeRooms.contains { $0.kind == room.kind && $0.roomID == room.serverID }
        }
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
                    ForEach(activeRooms) { room in
                        let title = room.kind == .live ? "Watch live" : "Join voice room"
                        KakaStudioButton(title: joiningRoom == room.kind ? "Checking room…" : title,
                                         icon: room.kind.actionArt, emphasis: true) {
                            Task { await enterActiveRoom(room) }
                        }
                        .disabled(joiningRoom != nil || busy)
                    }
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
                if showChat, blocked == false { KakaNativeChatView(hostID: host.id, hostName: current.name) }
                if blocked == false, activeRooms.isEmpty || !rooms.isEmpty {
                    Text("Hosted rooms").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                    if rooms.isEmpty { Text("No rooms to show.").foregroundStyle(KakaTheme.muted) }
                    ForEach(rooms) { room in
                        KakaStudioRow(title: room.title, detail: room.format, icon: room.kind.actionArt) {
                            store.open(.room(room))
                        }
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
            async let presence: Void = loadActiveRooms()
            await loadProfile()
            await loadBlockStatus()
            await presence
        }
        .sheet(isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } })) {
            if let decision { KakaStudioDecisionSheet(decision: decision) }
        }
    }

    private func loadActiveRooms() async {
        guard let session = store.session?.token, let rooms = try? await fetchActiveRooms(),
              isViewingHost(session: session) else { return }
        activeRooms = rooms
    }

    private func fetchActiveRooms() async throws -> [ActiveRoom] {
        async let presence: Any? = try? await store.request("getHostPresence", ["voyagerBadges": [host.id]])
        let profile = try await store.request("getHostPortrait", ["voyagerBadge": host.id])
        let status = await presence
        guard let profile = profile as? [String: Any], KakaNativeHost.parse(profile, expectedID: host.id) != nil else {
            throw KakaStudioIssue(text: "This host could not be verified.")
        }
        let fields = KakaNativeHost.fields(in: profile)
        let summary = (fields["showBrief"] ?? fields["liveRoom"]) as? [String: Any]
        let liveID = KakaRoomFields.id(fields, keys: ["studioCode"])
            ?? summary.flatMap { KakaRoomFields.id($0, keys: ["habitatTag", "orbitMark"]) }
            ?? (KakaRoomFields.flag(fields["broadcastMark"]) ? KakaRoomFields.id(fields, keys: ["habitatTag"]) : nil)
        let root: Any? = (status as? [String: Any])?["data"] ?? status
        let byID = (root as? [String: Any])?[String(host.id)] as? [String: Any]
        let statusRow = byID ?? root.flatMap {
            KakaRoomFields.rows($0, keys: ["gridBands", "records", "result"])
                .first { KakaRoomFields.id($0, keys: ["voyagerBadge"]) == host.id }
        }
        let voiceID = KakaRemoteClient.userID(fields["crewChamberId"] ?? statusRow?["crewChamberId"])
        var result: [ActiveRoom] = []
        if let liveID, !store.isHidden(String(liveID)) {
            result.append(ActiveRoom(kind: .live, roomID: liveID))
        }
        if let voiceID, voiceID > 0, !store.isHidden("party-\(voiceID)") {
            result.append(ActiveRoom(kind: .voice, roomID: voiceID))
        }
        return result
    }

    private func enterActiveRoom(_ selected: ActiveRoom) async {
        guard joiningRoom == nil, blocked == false, let session = store.session?.token else { return }
        joiningRoom = selected.kind
        defer { joiningRoom = nil }
        do {
            let fresh = try await fetchActiveRooms()
            guard isViewingHost(session: session), blocked == false else { return }
            activeRooms = fresh
            guard fresh.contains(where: { $0.kind == selected.kind && $0.roomID == selected.roomID }) else {
                store.notify("This room is no longer available.")
                return
            }
            switch selected.kind {
            case .live:
                let response = try await store.request("getLiveRoom", ["habitatTag": selected.roomID])
                guard isViewingHost(session: session), blocked == false else { return }
                guard let payload = response as? [String: Any],
                      let room = [payload, payload["venueBrief"] as? [String: Any]].compactMap({ $0 })
                        .compactMap({ KakaNativeRoom.parse($0, kind: .live) })
                        .first(where: { $0.serverID == selected.roomID && $0.host?.id == host.id }),
                      !store.isHidden(room.id), !store.isLiveEnded(room) else {
                    activeRooms.removeAll { $0.kind == .live }
                    store.notify("This live is no longer available.")
                    return
                }
                store.remember([room])
                store.openLive(room, lineup: [room])
            case .voice:
                if let room = KakaNativeRoom.voiceInvitation(roomID: selected.roomID) { store.open(.room(room)) }
            }
        } catch {
            if isViewingHost(session: session) { store.notify(store.message(error)) }
        }
    }

    private func isViewingHost(session: UUID) -> Bool {
        guard !Task.isCancelled, store.session?.token == session,
              case .host(let displayed) = store.route else { return false }
        return displayed.id == host.id
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
