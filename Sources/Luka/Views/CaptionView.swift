import LukaCore
import SwiftUI

struct CaptionRoot: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?
    /// The language popover lives in its own window, so hovering it doesn't count as hovering the caption.
    @State private var languagesShown = false
    @Namespace private var glass

    private var metrics: CaptionMetrics { CaptionMetrics(fontSize: model.captionFontSize, family: model.fontFamily, originalSize: model.captionOriginalFontSize,
                                                           weight: model.captionWeight.ns, cjk: model.cjkFontFamily) }

    var body: some View {
        let showToolbar = (hovering || languagesShown || model.notice != nil) && !model.locked
        let showStatus = !showToolbar && model.hasKey && !model.transcript.isEmpty
            && [.connecting, .reconnecting, .paused, .standby].contains(model.status)
        let question = showToolbar ? nil : model.pinnedQuestion
        // Spacing below the gaps between pieces: they morph out of the caption but don't fuse at rest.
        LukaGlassContainer(spacing: 6) {
            VStack(spacing: CaptionPanelController.toolbarGap) {
                ZStack(alignment: .bottom) {
                    Color.clear
                    if let notice = model.notice {
                        Text(notice)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .lukaGlass(.regular, in: .capsule)
                            .lukaGlassID("notice", in: glass)
                            .transition(.opacity)
                    } else if showToolbar {
                        CaptionToolbar(namespace: glass, languagesShown: $languagesShown)
                            .onHover { setHover($0) }
                    } else if showStatus {
                        HStack(spacing: 7) {
                            Image(systemName: model.status == .paused ? "pause.fill" : model.status == .standby ? "moon.zzz.fill" : "arrow.trianglehead.2.clockwise")
                                .symbolEffect(.rotate, options: .repeating, isActive: ![.paused, .standby].contains(model.status))
                            Text(model.status.label)
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .lukaGlass(.regular, in: .capsule)
                        .lukaGlassID("status", in: glass)
                        .transition(.opacity)
                    } else if let question {
                        PinnedQuestion(line: question)
                            .lukaGlassID("question", in: glass)
                            .transition(.opacity)
                    }
                }
                .frame(height: CaptionPanelController.toolbarHeight)

                if model.captionLayout.showsCaptions {
                    CaptionSurface(metrics: metrics)
                        .modifier(CaptionBackground(cornerRadius: cornerRadius))
                        .lukaGlassID("caption", in: glass)
                        .onHover { setHover($0) }
                        .overlay { ResizeHandles(metrics: metrics) }
                        .environment(\.colorScheme, model.captionStyle == .dark ? .dark : colorScheme)
                }
                if model.captionLayout.showsAnswers {
                    // The answers, under the captions or in their place.
                    SummaryPanel(transcript: model.transcript, answersOnly: true)
                        .id(model.cjkFontFamily)
                        .frame(height: model.captionAnswersHeight)
                        .clipShape(.rect(cornerRadius: 18))
                        .modifier(CaptionBackground(cornerRadius: 18))
                        .lukaGlassID("answers", in: glass)
                        .onHover { setHover($0) }
                        .overlay { AnswerResizeHandles() }
                        .tint(LukaTheme.accent)
                        .environment(\.colorScheme, model.captionStyle == .dark ? .dark : colorScheme)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: showToolbar)
        .animation(.smooth(duration: 0.3), value: showStatus)
        .animation(.smooth(duration: 0.3), value: question?.id)
        .animation(.smooth(duration: 0.3), value: model.notice)
        .animation(.smooth(duration: 0.3), value: model.captionLayout)
        .environment(\.usesGlass, model.usesGlass)
        .popover(item: Binding(get: { model.renaming?.place == .caption ? model.renaming : nil },
                               set: { if $0 == nil { model.renaming = nil } }),
                 attachmentAnchor: .rect(.bounds), arrowEdge: .top) { request in
            SpeakerEditor(id: request.id).environment(model)
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var cornerRadius: CGFloat {
        let h = metrics.height(lines: model.captionLines)
        return min(h / 2, 26)
    }

    private func setHover(_ inside: Bool) {
        hideTask?.cancel()
        if inside {
            hovering = true
        } else {
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { hovering = false }
            }
        }
    }
}

extension CaptionStyle {
    var glass: LukaGlass {
        switch self {
        case .glass: .regular
        case .clear: .clear
        case .dark: .regular.tint(.black.opacity(0.5))
        }
    }

    var title: String {
        switch self {
        case .glass: tr("Glass")
        case .clear: tr("Clear")
        case .dark: tr("Dark")
        }
    }
}

struct CaptionSurface: View {
    @Environment(AppModel.self) private var model
    let metrics: CaptionMetrics

    var body: some View {
        GeometryReader { geo in
            let transcript = model.transcript
            let names = transcript.visibleSpeakers.map { model.speakerName($0.id) }
            let gutter = names.isEmpty ? 0 : CaptionLayout.labelWidth(names, metrics: metrics, limit: geo.size.width * 0.26)
            let textWidth = geo.size.width - metrics.horizontalPadding * 2 - (gutter > 0 ? gutter + metrics.gutterSpacing : 0) - 4
            let language = model.captionLanguageFilter
            // With one translation chosen, the original stays visible, small, for the other languages.
            let dual = model.captionShowsOriginal || language != nil
            let rows = CaptionLayout.rows(
                CaptionLayout.blocks(from: transcript, dual: dual, language: language),
                width: textWidth, metrics: metrics, dual: dual,
                budget: CGFloat(model.captionLines) * metrics.lineHeight,
                same: { a, b in a.map(transcript.canonical) == b.map(transcript.canonical) })

            ZStack(alignment: .bottomLeading) {
                if !model.hasKey || rows.isEmpty {
                    CaptionPlaceholder(metrics: metrics)
                        .transition(.blurReplace)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            CaptionRowView(row: row, metrics: metrics, gutter: gutter)
                                .transition(.asymmetric(
                                    insertion: .offset(y: row.height * 0.6).combined(with: .opacity),
                                    removal: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .animation(.smooth(duration: 0.34), value: rows.map(\.id))
                    .animation(.smooth(duration: 0.25), value: gutter)
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
            .clipped()
        }
        .contentShape(.rect)
        .gesture(WindowDragGesture())
        .contextMenu { CaptionMenu() }
    }
}

struct CaptionRowView: View {
    @Environment(AppModel.self) private var model
    let row: CaptionRow
    let metrics: CaptionMetrics
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: gutter > 0 ? metrics.gutterSpacing : 0) {
            if gutter > 0 {
                Group {
                    if row.showsLabel, let speaker = row.speaker {
                        Button {
                            NSApp.activate()
                            model.renaming = RenameRequest(session: model.transcript.id, id: model.transcript.canonical(speaker), place: .caption)
                        } label: {
                            Text(model.speakerName(speaker))
                                .font(LukaFont.font(metrics.family, size: metrics.labelFontSize, weight: .semibold))
                                .foregroundStyle(model.speakerColor(speaker))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .contentTransition(.interpolate)
                        }
                        .buttonStyle(.plain)
                        .help(tr("Rename speaker"))
                        .transition(.opacity)
                    } else {
                        Text(verbatim: " ").font(.system(size: metrics.labelFontSize))
                    }
                }
                .frame(width: gutter, alignment: .trailing)
            }
            text
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: row.height, alignment: .center)
    }

    private var text: Text {
        let size = row.isOriginal ? metrics.originalFontSize : metrics.fontSize
        // The original stays a step below the translation, but firm enough to read over any background.
        let solid = Text(row.solid).foregroundStyle(row.isOriginal ? AnyShapeStyle(Color.primary.opacity(0.82)) : AnyShapeStyle(.primary))
        // Words still being recognized: quieter than settled text, but clearly readable on any background.
        let faint = Text(row.faint).foregroundStyle(Color.primary.opacity(0.6))
        return Text("\(solid)\(faint)")
            .font(LukaFont.font(metrics.family, size: size, weight: row.isOriginal ? .regular : metrics.weight))
    }
}

struct CaptionPlaceholder: View {
    @Environment(AppModel.self) private var model
    let metrics: CaptionMetrics

    var body: some View {
        HStack(spacing: 12) {
            if !model.hasKey {
                Image(systemName: "key.horizontal")
                    .foregroundStyle(.secondary)
                Text(tr("Add your Soniox API key to start."))
                    .foregroundStyle(.secondary)
                Button(tr("Open Settings…")) { model.openSettings() }
                    .lukaGlassButton()
                    .controlSize(.small)
            } else {
                switch model.status {
                case .idle:
                    Button { model.start() } label: {
                        Label(tr("Start Listening"), systemImage: "waveform")
                    }
                    .lukaGlassButton(prominent: true)
                    .controlSize(.regular)
                    KeyCaps(keys: GlobalShortcut.newSession.keys, size: 11)
                    Text(tr("from any app")).foregroundStyle(.tertiary)
                case .error(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).foregroundStyle(.secondary).lineLimit(2)
                    Button(tr("Try Again")) { model.start() }
                        .lukaGlassButton()
                        .controlSize(.small)
                default:
                    ListeningText(label: model.status.label)
                }
            }
        }
        .font(.system(size: min(metrics.fontSize * 0.7, 17), weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 8)
    }
}

struct ListeningText: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            PhaseAnimator([0.3, 1.0]) { phase in
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.9) }
            Text(label).foregroundStyle(.secondary)
        }
    }
}

/// A small status light in the corner, so you can tell it’s live without hovering.
struct LiveDot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let color: Color? = switch model.status {
        case .live: .red
        case .connecting, .reconnecting: .orange
        case .paused, .standby: .secondary
        default: nil
        }
        if let color {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(model.status == .live ? Double(0.55 + 0.45 * model.level) : 0.8)
                .animation(.smooth(duration: 0.15), value: model.level)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

struct CaptionToolbar: View {
    @Environment(AppModel.self) private var model
    let namespace: Namespace.ID
    @Binding var languagesShown: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { model.toggleListening() } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.isListening ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                    if model.isListening {
                        LevelBars(level: model.level, active: model.status == .live, color: .white)
                    }
                }
                .frame(minWidth: 20)
                .padding(.horizontal, 7)
                .frame(height: 34)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .lukaGlass(.regular.tint(model.isListening ? .red : LukaTheme.accent).interactive(), in: .capsule)
            .lukaGlassID("play", in: namespace)
            .help(model.isListening ? tr("Pause") : tr("Start Listening"))

            if model.status != .idle {
                Button { withAnimation(.smooth) { model.endSession() } } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .lukaGlass(.regular.interactive(), in: .circle)
                .lukaGlassID("stop", in: namespace)
                .help(tr("Finish Session"))
                .transition(.scale.combined(with: .opacity))
            }

            HStack(spacing: 2) {
                Button { languagesShown.toggle() } label: {
                    Text(model.languageSummary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(.capsule)
                }
                .buttonStyle(ToolbarHoverStyle())
                .popover(isPresented: $languagesShown, arrowEdge: .top) { LanguagePicker().environment(model) }

                Menu {
                    CaptionAppearanceMenu()
                } label: {
                    Image(systemName: "textformat.size")
                        .environment(\.locale, Locale(identifier: "en"))
                        .frame(width: 30, height: 30)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(ToolbarHoverStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("Caption appearance"))

                // Captions, captions with the answers under them, or the answers alone.
                Menu {
                    Picker(tr("Show"), selection: Bindable(model).captionLayout) {
                        ForEach(CaptionLayout.allCases, id: \.self) { layout in
                            Label(layout.title, systemImage: layout.symbol).tag(layout)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: model.captionLayout.symbol)
                        .frame(width: 30, height: 30)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(ToolbarHoverStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("Captions and answers"))

                toolbarButton("lock", tr("Lock captions (click-through)") + "  ⌃⌥L") { model.lock(true) }
                toolbarButton("gearshape", tr("Settings…")) { model.openSettings() }
                toolbarButton("eye.slash", tr("Hide Captions") + "  ⌃⌥C") { model.setCaptions(false) }
                toolbarButton("rectangle.expand.vertical", tr("Open transcript") + "  ⌃⌥T") {
                    model.openTranscript()
                }
            }
            .padding(.horizontal, 2)
            .frame(height: 34)
            .lukaGlass(.regular, in: .capsule)
            .lukaGlassID("tools", in: namespace)

            SourceSwitch(height: 34)
                .lukaGlass(.regular, in: .capsule)
                .lukaGlassID("source", in: namespace)
        }
        .font(.system(size: 13, weight: .semibold))
        .animation(.smooth(duration: 0.3), value: model.status != .idle)
    }

    private func toolbarButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .buttonStyle(ToolbarHoverStyle())
        .help(help)
    }
}

/// Plain icon button that lights up under the pointer, for controls sitting on glass.
struct ToolbarHoverStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.smooth(duration: 0.15), value: hovering)
            .animation(.smooth(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

struct CaptionAppearanceMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Button(tr("Bigger Text")) { model.adjustFontSize(1, captions: true) }
        Button(tr("Smaller Text")) { model.adjustFontSize(-1, captions: true) }
        Divider()
        Picker(tr("Lines"), selection: $model.captionLines) {
            ForEach(AppModel.captionLineRange, id: \.self) { Text(verbatim: "\($0)").tag($0) }
        }
        Toggle(tr("Show Original"), isOn: $model.captionShowsOriginal)
        Picker(tr("Style"), selection: $model.captionStyle) {
            ForEach(CaptionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle(tr("Keep on Top"), isOn: $model.captionPinned)
    }
}

struct CaptionMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.isListening ? tr("Pause") : tr("Start Listening")) { model.toggleListening() }
        SourcePicker()
        Divider()
        CaptionAppearanceMenu()
        Divider()
        // The pin's × sits where the hover toolbar appears, so it can be hard to reach.
        if let question = model.pinnedQuestion {
            Button(tr("Unpin Question")) { model.dismissedQuestion = question.id }
        }
        Button(tr("Lock Captions")) { model.lock(true) }
        Button(tr("Show Transcript")) { model.openTranscript() }
        Button(tr("Hide Captions")) { model.setCaptions(false) }
    }
}

/// Invisible edge strips: sides change width, top and bottom snap to whole lines.
struct ResizeHandles: View {
    let metrics: CaptionMetrics

    var body: some View {
        ZStack {
            handle(.leading).frame(width: 7).frame(maxWidth: .infinity, alignment: .leading)
            handle(.trailing).frame(width: 7).frame(maxWidth: .infinity, alignment: .trailing)
            handle(.top).frame(height: 6).padding(.horizontal, 24).frame(maxHeight: .infinity, alignment: .top)
            handle(.bottom).frame(height: 6).padding(.horizontal, 24).frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func handle(_ edge: Edge) -> some View {
        let position: FrameResizePosition = switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
        return Color.clear
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: position))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in CaptionPanelController.current?.drag(edge) }
                .onEnded { _ in CaptionPanelController.current?.endDrag() })
    }
}


/// The answers under the captions: drag the sides for width, the bottom for height.
struct AnswerResizeHandles: View {
    var body: some View {
        ZStack {
            Color.clear.frame(width: 7).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .pointerStyle(.frameResize(position: .leading))
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { _ in CaptionPanelController.current?.drag(.leading) }
                    .onEnded { _ in CaptionPanelController.current?.endDrag() })
            Color.clear.frame(width: 7).frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(.rect)
                .pointerStyle(.frameResize(position: .trailing))
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { _ in CaptionPanelController.current?.drag(.trailing) }
                    .onEnded { _ in CaptionPanelController.current?.endDrag() })
            Color.clear.frame(height: 6).padding(.horizontal, 24).frame(maxHeight: .infinity, alignment: .bottom)
                .contentShape(.rect)
                .pointerStyle(.frameResize(position: .bottom))
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { _ in CaptionPanelController.current?.dragAnswers() }
                    .onEnded { _ in CaptionPanelController.current?.endDrag() })
        }
    }
}

/// Appears over a locked caption while the pointer is on it.
struct UnlockPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { withAnimation(.smooth) { model.lock(false) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.open.fill")
                Text(tr("Unlock"))
                KeyCaps(keys: GlobalShortcut.lock.keys, size: 10)
            }
            .font(.callout.weight(.semibold))
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 32)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .lukaGlass(.regular.interactive(), in: .capsule)
        .padding(2)
        .fixedSize()
        .environment(\.usesGlass, model.usesGlass)
    }
}

/// The latest question asked, kept above the captions while you answer it.
struct PinnedQuestion: View {
    @Environment(AppModel.self) private var model
    let line: Line

    private var restated: String? {
        if let live = model.answerer.live, live.id == line.id, let r = live.restated { return r }
        return model.transcript.answers.last { $0.id == line.id && $0.kind != "polish" }?.restated
    }

    var body: some View {
        // Read in the caption's language unless the captions show the original too.
        let translated = line.translatedText
        let full = model.captionShowsOriginal || translated.isEmpty ? line.original : translated
        // The question restated with its premise once the answer model has written it;
        // until then just the question, without whatever was said before it in the same breath.
        let text = restated ?? Questions.lastSentence(full) ?? full
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(model.speakerColor(line.speaker))
            Text(text)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation(.smooth) { model.dismissedQuestion = line.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(tr("Unpin"))
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .lukaGlass(.regular, in: .rect(cornerRadius: 15, style: .continuous))
        .padding(.horizontal, 24)
        .help(translated.isEmpty ? line.original : line.original + "\n" + translated)
    }
}

/// The caption strip's background: Liquid Glass for Glass and Clear, and for Dark a black backing
/// at the opacity the user set, like broadcast captions.
struct CaptionBackground: ViewModifier {
    @Environment(AppModel.self) private var model
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if model.captionStyle == .dark {
            content
                .background(Color.black.opacity(model.captionBackgroundOpacity), in: .rect(cornerRadius: cornerRadius))
                // The same faint edge as the floating card, so the two read as one set.
                .lukaFloatingEdge(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content
                .lukaGlass(model.captionStyle.glass, in: .rect(cornerRadius: cornerRadius))
        }
    }
}
