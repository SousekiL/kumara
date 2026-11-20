import LukaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab(tr("General"), systemImage: "gearshape") { GeneralSettings() }
            Tab(tr("Captions"), systemImage: "captions.bubble") { CaptionSettings() }
            Tab(tr("Models"), systemImage: "cpu") { ModelSettings() }
            Tab(tr("Assistant"), systemImage: "text.badge.star") { SummarySettings() }
            Tab(tr("Knowledge"), systemImage: "books.vertical") { KnowledgeSettings() }
            Tab(tr("Usage"), systemImage: "chart.bar") { UsageSettings() }
            Tab(tr("Shortcuts"), systemImage: "command") { ShortcutSettings() }
        }
        .frame(width: 520)
        .tint(LukaTheme.accent)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var localizer = Localizer.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(tr("Interface language"), selection: $localizer.language) {
                    ForEach(UILanguage.allCases, id: \.self) { Text(Localizer.displayName($0)).tag($0) }
                }
                Toggle(tr("Open at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            model.show(error.localizedDescription)
                        }
                    }
                Toggle(tr("Show in Dock"), isOn: $model.showsInDock)
            } footer: {
                Text(tr("Kumara keeps running in the menu bar, so ⌃⌥N can start a transcription at any time."))
            }
            Section {
                SourcePicker()
                MicrophonePicker()
                LabeledContent(tr("Languages")) { Text(model.languageSummary).foregroundStyle(.secondary) }
            } footer: {
                Text(tr("Change languages from the globe button while listening."))
            }
            Section {
                Toggle(tr("Pause when it’s quiet"), isOn: $model.pausesWhenQuiet)
            } footer: {
                Text(tr("After 3 minutes without sound, Kumara closes the Soniox stream, which is billed while open, and starts again when sound returns."))
            }
            Section {
                TextField(tr("Context"), text: $model.context, prompt: Text(tr("Names, topics, jargon…")), axis: .vertical)
                    .lineLimit(3...6)
            } footer: {
                Text(tr("Helps recognition of names and terms. Applies from the next session."))
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}

/// The key's region, found from the key itself, or why it couldn't be.
struct KeyStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.keyState {
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Checking key…"))
                }
            case .invalid:
                Label(tr("Key not recognized"), systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .unreachable:
                Text(model.region.title + " · " + tr("not checked, offline"))
            case .idle:
                Text(model.hasKey ? model.region.title : "—")
            }
        }
        .foregroundStyle(.secondary)
        .help(model.region.host)
    }
}

extension SonioxRegion {
    var title: String {
        switch self {
        case .us: tr("United States")
        case .eu: tr("European Union")
        case .jp: tr("Japan")
        case .in: tr("India")
        }
    }
}

private struct MicrophonePicker: View {
    @Environment(AppModel.self) private var model
    @State private var devices = InputDevices.shared

    var body: some View {
        @Bindable var model = model
        Picker(tr("Microphone"), selection: $model.microphone) {
            Text(tr("System Default")).tag(String?.none)
            Divider()
            ForEach(devices.all) { Text($0.name).tag(Optional($0.uid)) }
            if let uid = model.microphone, !devices.all.contains(where: { $0.uid == uid }) {
                Text(tr("Disconnected device")).tag(Optional(uid))
            }
        }
        .disabled(model.audioSource == .system)
    }
}

private struct CaptionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var service = model.assistant
        Form {
            // One look for everything that floats over other apps: captions, the assistant card, its button.
            Section {
                Picker(tr("Style"), selection: $model.captionStyle) {
                    ForEach(CaptionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.captionStyle == .dark {
                    LabeledContent(tr("Background opacity")) {
                        HStack {
                            Slider(value: $model.captionBackgroundOpacity, in: AppModel.captionBackgroundRange, step: 0.05)
                            Text(verbatim: "\(Int((model.captionBackgroundOpacity * 100).rounded()))%")
                                .monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                Toggle(tr("Liquid Glass"), isOn: $model.liquidGlass)
                    .disabled(!LukaGlassSupport.available)
            } header: {
                Text(tr("Caption window"))
            } footer: {
                Text(tr("The Dark style and its opacity also apply to the floating summary and answers card."))
                + Text(verbatim: " ")
                + Text(LukaGlassSupport.available
                       ? tr("Liquid Glass applies to all of Kumara, the transcript window’s buttons included. Turn it off for solid, higher-contrast captions and controls.")
                       : tr("Liquid Glass needs macOS 26. Kumara uses system materials on this Mac."))
            }

            // The transcript window is a separate window with its own light or dark choice.
            Section {
                Picker(tr("Appearance"), selection: $model.windowAppearance) {
                    ForEach(WindowAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(tr("Transcript window"))
            } footer: {
                Text(tr("System follows your Mac’s light or dark setting."))
            }

            Section {
                Picker(tr("Font"), selection: $model.fontFamily) {
                    Text(tr("System")).tag("")
                    Divider()
                    ForEach(LukaFont.families, id: \.self) { Text($0).tag($0) }
                }
                Picker(tr("Chinese font"), selection: $model.cjkFontFamily) {
                    Text(tr("System (PingFang)")).tag("")
                    Divider()
                    ForEach(LukaFont.cjkFamilies, id: \.self) { Text($0).tag($0) }
                }
                Picker(tr("Caption weight"), selection: $model.captionWeight) {
                    Text(tr("Light")).tag(CaptionWeight.light)
                    Text(tr("Regular")).tag(CaptionWeight.regular)
                    Text(tr("Medium")).tag(CaptionWeight.medium)
                }
                .pickerStyle(.segmented)
                size(tr("Captions"), $model.captionFontSize, AppModel.captionFontRange, step: 2)
                size(tr("Original text size"), $model.captionOriginalFontSize, AppModel.captionOriginalFontRange, step: 1)
                    .disabled(!model.captionShowsOriginal)
                size(tr("Transcript"), $model.transcriptFontSize, AppModel.transcriptFontRange, step: 1)
                size(tr("Summary and answers"), $service.fontSize, AssistantService.fontRange, step: 1)
                size(tr("Shared Captions"), $model.presenterFontSize, AppModel.presenterFontRange, step: 4)
            } header: {
                Text(tr("Fonts"))
            } footer: {
                Text(tr("Used for captions, the transcript and the summary. The Chinese font applies to Chinese and Japanese characters; English keeps the main font."))
            }

            Section {
                Picker(tr("Show captions"), selection: $model.captionVisibility) {
                    Text(tr("While listening")).tag(CaptionVisibility.whileListening)
                    Text(tr("Always")).tag(CaptionVisibility.always)
                }
                Stepper(value: $model.captionLines, in: AppModel.captionLineRange) {
                    LabeledContent(tr("Lines"), value: "\(model.captionLines)")
                }
                Toggle(tr("Show Original"), isOn: $model.captionShowsOriginal)
                Toggle(tr("Keep on Top"), isOn: $model.captionPinned)
                Picker(tr("Three-way translation"), selection: $model.captionLanguage) {
                    Text(tr("All")).tag("")
                    let codes = model.sessionConfig.threeWayLanguages
                    ForEach(codes, id: \.self) { Text(Languages.name($0, in: Localizer.shared.locale)).tag($0) }
                    if !model.captionLanguage.isEmpty, !codes.contains(model.captionLanguage) {
                        Text(Languages.name(model.captionLanguage, in: Localizer.shared.locale)).tag(model.captionLanguage)
                    }
                }
            } header: {
                Text(tr("Captions"))
            } footer: {
                Text(model.captionVisibility == .whileListening
                     ? tr("Captions fade in when Kumara starts listening and out when you finish. ⌃⌥C hides or shows them anytime.")
                     : tr("Captions stay until you hide them with ⌃⌥C."))
                + Text(verbatim: " ")
                + Text(tr("Drag the caption’s top or bottom edge to add lines, its sides to resize. Drop it near the center and it snaps."))
                + Text(verbatim: " ")
                + Text(tr("In three-way mode, captions can show one translation, with the original small above it. Shared Captions always shows all."))
            }

            Section(tr("Transcript")) {
                Toggle(tr("Show Original"), isOn: $model.transcriptShowsOriginal)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }

    /// One scale for every text size slider, so the same size sits at the same spot on each.
    private static let sizeScale = 10.0...60.0

    /// A text size slider with its value. It runs along the shared scale and stops at the ends of its own range.
    private func size(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        let clamped = Binding<Double>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) })
        return LabeledContent(title) {
            HStack {
                Slider(value: clamped, in: Self.sizeScale)
                Text(verbatim: "\(Int(value.wrappedValue))").monospacedDigit().frame(width: 28, alignment: .trailing)
            }
        }
    }
}

private struct ShortcutSettings: View {
    private var local: [(String, [String])] {
        [
            (tr("Start / Pause"), ["⌘", "R"]),
            (tr("Finish Session"), ["⌘", "."]),
            (tr("New Session"), ["⌘", "N"]),
            (tr("Name whoever is speaking"), ["⌘", "E"]),
            (tr("Captions"), ["⌘", "1"]),
            (tr("Show Transcript"), ["⌘", "2"]),
            (tr("Shared Captions Window"), ["⌘", "3"]),
            (tr("Bigger / Smaller Text"), ["⌘", "+", "−"]),
            (tr("More / Fewer Caption Lines"), ["⌘", "↑", "↓"]),
            (tr("Show Original"), ["⌥", "⌘", "O"]),
            (tr("Keep Captions on Top"), ["⌥", "⌘", "T"]),
            (tr("Copy Transcript"), ["⇧", "⌘", "C"]),
            (tr("Export Transcript…"), ["⌘", "S"]),
        ]
    }

    var body: some View {
        Form {
            Section(tr("Works from any app")) {
                ForEach(GlobalShortcut.allCases, id: \.self) { shortcut in
                    LabeledContent(shortcut.title) { KeyCaps(keys: shortcut.keys) }
                }
            }
            Section(tr("In Kumara")) {
                ForEach(local, id: \.0) { row in
                    LabeledContent(row.0) { KeyCaps(keys: row.1) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}

private struct UsageSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent(tr("This session")) { Text(model.sessionUsage.summary).monospacedDigit() }
                LabeledContent(tr("This month")) { Text(model.monthUsage.summary).monospacedDigit() }
                LabeledContent(tr("Last month")) { Text(model.lastMonthUsage.summary).monospacedDigit() }
            } header: {
                Text(tr("Usage in Kumara"))
            } footer: {
                Text(tr("Estimated from Soniox’s published rates: $0.12 per hour transcribed, $0.18 per hour translated, per stream. Your Soniox console has the exact bill."))
            }
            Section {
                LabeledContent(tr("Balance")) {
                    if let b = model.accountBalance {
                        Text(b.invoiced ? tr("Invoiced") : String(format: "$%.2f", b.availableUSD))
                            .monospacedDigit()
                            .foregroundStyle(b.exhausted ? Color.red : Color.secondary)
                    } else {
                        Text(model.orgKey.isEmpty ? tr("Needs an organization key") : "—").foregroundStyle(.secondary)
                    }
                }
                LabeledContent(tr("This month, all apps")) {
                    Text(model.accountMonthCost.map { String(format: "$%.2f", $0) } ?? "—")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                SecureField(tr("Organization API key"), text: $model.orgKey, prompt: Text(verbatim: "snx_org_…"))
                HStack {
                    if let error = model.accountError {
                        Text(error).foregroundStyle(.red).lineLimit(2)
                    } else if let at = model.accountCheckedAt {
                        Text(String(format: tr("Checked %@"), at.formatted(date: .omitted, time: .shortened)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(tr("Refresh")) { model.refreshAccount() }
                }
                .font(.callout)
            } header: {
                Text(tr("Soniox account"))
            } footer: {
                Text(tr("This month’s cost comes from your API key and counts everything that key’s project used, in any app. The prepaid balance needs an organization API key: Soniox Console › Settings › Organization API keys, with read access to billing."))
            }
            .onAppear { model.refreshAccount() }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}

/// The three models Kumara uses, in one place: what each is for and how it is reached.
private struct ModelSettings: View {
    @Environment(AppModel.self) private var model

    /// Common services, so nobody has to look up a base URL. The model name is only a starting point.
    private struct Preset: Identifiable {
        let name: String
        let provider: SummaryProvider
        let baseURL: String
        let model: String
        var id: String { name }
    }

    private static let presets: [Preset] = [
        Preset(name: "OpenAI", provider: .openAI, baseURL: "", model: "gpt-4.1-mini"),
        Preset(name: "Claude (Anthropic)", provider: .anthropic, baseURL: "", model: "claude-haiku-5-5"),
        Preset(name: "DeepSeek", provider: .openAI, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        Preset(name: "Qwen (DashScope)", provider: .openAI, baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
        Preset(name: "OpenRouter", provider: .openAI, baseURL: "https://openrouter.ai/api/v1", model: ""),
        Preset(name: "Ollama", provider: .openAI, baseURL: "http://localhost:11434/v1", model: ""),
    ]

    var body: some View {
        @Bindable var model = model
        @Bindable var service = model.assistant
        Form {
            Section {
                SecureField(tr("API key"), text: $model.apiKey)
                LabeledContent(tr("Region")) { KeyStatus() }
                LabeledContent(tr("Model")) { Text(SessionConfig.model).foregroundStyle(.secondary) }
            } header: {
                Text(tr("Transcription") + " · Soniox")
            } footer: {
                Text(tr("Turns speech into text and translates it, live. Everything else builds on its transcript.") + " ")
                + Text(.init("[\(tr("Get a key at console.soniox.com"))](https://console.soniox.com)"))
            }
            Section {
                LabeledContent(tr("Service")) {
                    Menu(tr("Choose a preset")) {
                        ForEach(Self.presets) { preset in
                            Button(preset.name) {
                                service.provider = preset.provider
                                service.baseURL = preset.baseURL
                                service.model = preset.model
                            }
                        }
                    }
                    .fixedSize()
                }
                Picker(tr("API type"), selection: $service.provider) {
                    Text(tr("OpenAI-compatible")).tag(SummaryProvider.openAI)
                    Text(tr("Anthropic (Claude)")).tag(SummaryProvider.anthropic)
                }
                TextField(tr("Base URL"), text: $service.baseURL, prompt: Text(verbatim: service.provider.defaultBaseURL))
                TextField(tr("Model"), text: $service.model, prompt: Text(tr("The model’s name at this service")))
                SecureField(tr("API key"), text: $service.apiKey)
                HStack {
                    if service.testing {
                        ProgressView().controlSize(.small)
                    } else if let result = service.testResult {
                        Text(result).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button(tr("Test")) { service.test() }
                        .disabled(service.testing || !service.isConfigured)
                }
                .font(.callout)
            } header: {
                Text(tr("Live assistant"))
            } footer: {
                Text(tr("Writes the live summary, the answers to questions heard, feedback on your answers, and the review after each session. It runs every few seconds while listening, so pick a fast, inexpensive model. A preset fills in the address and a model name to start from."))
            }

            // Questions typed in the panel can take a stronger, slower model than the live helpers.
            Section {
                Toggle(tr("Use a separate model"), isOn: $service.askUsesOwnModel)
                if service.askUsesOwnModel {
                    LabeledContent(tr("Service")) {
                        Menu(tr("Choose a preset")) {
                            ForEach(Self.presets) { preset in
                                Button(preset.name) {
                                    service.askProvider = preset.provider
                                    service.askBaseURL = preset.baseURL
                                    service.askModel = preset.model
                                }
                            }
                        }
                        .fixedSize()
                    }
                    Picker(tr("API type"), selection: $service.askProvider) {
                        Text(tr("OpenAI-compatible")).tag(SummaryProvider.openAI)
                        Text(tr("Anthropic (Claude)")).tag(SummaryProvider.anthropic)
                    }
                    TextField(tr("Base URL"), text: $service.askBaseURL, prompt: Text(verbatim: service.askProvider.defaultBaseURL))
                    TextField(tr("Model"), text: $service.askModel, prompt: Text(tr("The model’s name at this service")))
                    SecureField(tr("API key"), text: $service.askAPIKey)
                    HStack {
                        if service.askTesting {
                            ProgressView().controlSize(.small)
                        } else if let result = service.askTestResult {
                            Text(result).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button(tr("Test")) { service.testAsk() }
                            .disabled(service.askTesting || !service.isAskConfigured)
                    }
                    .font(.callout)
                }
                Toggle(tr("Think deeply"), isOn: $service.askThinks)
            } header: {
                Text(tr("Deep analysis"))
            } footer: {
                Text(tr("Used when you ask for something and can wait: questions typed in the ask box, and working out who each speaker is. Worth a stronger model. Off: the live assistant’s model does these too. Think deeply turns on extended thinking for Claude and the highest reasoning effort for OpenAI-compatible models; if a model doesn’t accept a setting, it steps down to one it does."))
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}

private struct SummarySettings: View {
    @Environment(AppModel.self) private var model


    var body: some View {
        @Bindable var model = model
        @Bindable var service = model.assistant
        @Bindable var summarizer = model.summarizer
        @Bindable var answerer = model.answerer
        Form {

            // The mode sets the scene; every switch it sets stays here to change by hand.
            Section {
                Picker(tr("Mode"), selection: $model.assistantMode) {
                    ForEach(AssistantMode.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(tr("Summarize while listening"), isOn: $summarizer.enabled)
                Toggle(tr("Answer questions as they’re asked"), isOn: $answerer.enabled)
                Toggle(tr("Polish my answers"), isOn: $answerer.polishes)
                    .disabled(!answerer.enabled || model.assistantMode != .interview)
                Toggle(tr("Label Me and Them by source"), isOn: $model.separatesSpeakers)
                Toggle(tr("Translate my speech"), isOn: $model.translatesMyVoice)
                    .disabled(!model.separatesSpeakers)
                Toggle(tr("Pin the latest question"), isOn: $model.pinsQuestions)
            } header: {
                Text(tr("Mode"))
            } footer: {
                Text(model.assistantMode.explanation + " " + tr("Choosing a mode sets these switches; change any of them afterwards as you like. The mode can also be changed at the top of the summary column."))
                + Text(verbatim: "\n")
                + Text(model.separatesSpeakers && !model.splitsBySource
                       ? tr("Me / Them needs Mac Audio + Microphone, and doesn’t apply in three-way mode.")
                       : tr("Me / Them: the microphone is always you and the Mac audio is everyone else, numbered Them 1, Them 2… It runs a second Soniox stream, so it costs about twice as much while on. Wear headphones."))
            }

            Section {
                LabeledContent(tr("Interviewing for")) {
                    HStack(spacing: 6) {
                        TextField("", text: $answerer.role, prompt: Text(verbatim: "Data Scientist"))
                            .labelsHidden()
                        Menu {
                            ForEach(Answerer.rolePresets, id: \.self) { preset in
                                Button(preset) { answerer.role = preset }
                            }
                        } label: { Image(systemName: "chevron.down") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                TextField(tr("About this conversation"), text: $service.note,
                          prompt: Text(tr("Optional, e.g. “Second-round interview at an insurer; list every technical question.”")), axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text(tr("This conversation"))
            } footer: {
                Text(tr("Read by both the summary and the answers. The role tells Interview mode which questions are interview questions."))
            }

            TuningSection(tuner: model.answerer.tuner)

            Section {
                Picker(tr("Summary detail"), selection: $summarizer.detail) {
                    Text(tr("Concise")).tag(SummaryDetail.concise)
                    Text(tr("Standard")).tag(SummaryDetail.standard)
                    Text(tr("Detailed")).tag(SummaryDetail.detailed)
                }
                .pickerStyle(.segmented)
                Picker(tr("Language"), selection: $service.language) {
                    Text(tr("Same as translation")).tag("")
                    Text(tr("Guide (bilingual)")).tag("guide")
                    Divider()
                    ForEach(Languages.ordered(in: Localizer.shared.locale), id: \.self) {
                        Text(Languages.name($0, in: Localizer.shared.locale)).tag($0)
                    }
                }
                Toggle(isOn: $model.showsDockButton) {
                    HStack {
                        Text(tr("Floating button while listening"))
                        KeyCaps(keys: GlobalShortcut.dockButton.keys, size: 10)
                    }
                }
            } header: {
                Text(tr("Output"))
            } footer: {
                Text((service.language == "guide"
                      ? tr("Guide: explanations in the translation language; technical terms, key original wording and anything to say aloud (sample answers, questions to ask) in the spoken language.") + " "
                      : "")
                     + tr("In Meeting and Interview mode, new points are added at the end every few sentences and what is already written stays put. The floating button sits on the right edge of the screen; its top half opens the summary and answers, its bottom half shows or hides the captions. Text size is in Captions › Fonts."))
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
        // Turning a helper on brings its column into view.
        .onChange(of: summarizer.enabled) { if summarizer.enabled { summarizer.panelShown = true } }
        .onChange(of: answerer.enabled) {
            if answerer.enabled {
                summarizer.panelShown = true
                answerer.panelShowsAnswers = true
            }
        }
    }
}

/// Files, folders and notes the answers draw on first.
/// What the answers learned from past sessions, with a way to undo any of it.
private struct TuningSection: View {
    @Bindable var tuner: AnswerTuner

    var body: some View {
        Section {
            Toggle(tr("Learn from each session"), isOn: $tuner.enabled)
            ForEach(AnswerTuner.modes, id: \.self) { mode in
                let t = tuner.tuning(for: mode)
                DisclosureGroup {
                    if t.rules.isEmpty {
                        Text(tr("No rules yet")).foregroundStyle(.secondary)
                    }
                    ForEach(t.rules) { rule in
                        HStack(alignment: .firstTextBaseline) {
                            Text(rule.text).help(rule.why)
                            if rule.trial {
                                Text(tr("trial")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { tuner.removeRule(rule.id, mode: mode) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                                .help(tr("Remove this rule"))
                        }
                    }
                    if !t.cues.isEmpty {
                        Text(tr("Also answers turns with") + ":").foregroundStyle(.secondary)
                        ForEach(t.cues, id: \.self) { cue in
                            HStack {
                                Text(verbatim: "“\(cue)”")
                                Spacer()
                                Button { tuner.removeCue(cue, mode: mode) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button(tr("Reset to the defaults")) { tuner.reset(mode) }
                            .disabled(t == AnswerTuning())
                    }
                } label: {
                    LabeledContent(mode.title) {
                        Text(String(format: tr("%d rules · %d cues"), t.rules.count, t.cues.count)
                             + (mode == .interview ? " · " + String(format: tr("answers turns from %d"), t.eagerWeight) : "")
                             + (t.floor > 0 ? " · " + String(format: tr("ignores under %d"), t.floor) : ""))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !tuner.history.isEmpty {
                Menu(tr("Undo a change")) {
                    ForEach(tuner.history.prefix(15)) { v in
                        Button(v.mode.title + " · " + v.date.formatted(date: .abbreviated, time: .shortened) + " · " + (v.changes.first ?? "")) {
                            tuner.undo(v)
                        }
                    }
                }
                .fixedSize()
            }
            if tuner.reviewing {
                HStack { ProgressView().controlSize(.small); Text(tr("Reviewing the last session…")) }
            } else if let report = tuner.lastReport {
                Text(report).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text(tr("Learning from sessions"))
        } footer: {
            Text(tr("When an interview or meeting with answers on ends, the answer model reviews it once (about the cost of one long answer) and adjusts how answers are triggered and what they put first, a little at a time: at most two rules and three phrases per session, and a threshold moves one step only when two sessions in a row agree and replaying the session shows nothing that needed an answer would be missed. Every change can be undone."))
        }
    }
}

private struct KnowledgeSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var answerer = model.answerer
        @Bindable var service = model.assistant
        Form {
            Section {
                ForEach(answerer.sources) { source in
                    HStack(spacing: 8) {
                        Image(systemName: source.missing ? "questionmark.folder" : source.isFolder ? "folder" : "doc.text")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(source.name).lineLimit(1).truncationMode(.middle).help(source.path)
                        Spacer()
                        Text(source.missing ? tr("Not found")
                             : String(format: tr("%d files · %dk characters"), source.files, source.characters / 1000))
                            .font(.callout).monospacedDigit()
                            .foregroundStyle(source.missing ? Color.red : Color.secondary)
                        Button { answerer.remove(source) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(tr("Remove"))
                    }
                }
                HStack {
                    Button(tr("Add Files or Folders…")) { answerer.pickSources() }
                    Button(tr("Reload")) { answerer.reload() }
                        .disabled(answerer.sources.isEmpty || answerer.loading)
                    Spacer()
                    if answerer.loading { ProgressView().controlSize(.small) }
                }
            } header: {
                Text(tr("Files and folders"))
            } footer: {
                Text(tr("Answers use this first, and the model’s own knowledge only for what it doesn’t cover. Folders are read where they are (Markdown, text, PDF, Word), including subfolders, and reread at the start of every session, so an existing notes or memory folder works as it is. The excerpts that match a question are sent to the model’s provider."))
            }
            Section {
                TextField(tr("Your names"), text: $service.readerNames, prompt: Text(verbatim: "Alex, Alexander"))
            } header: {
                Text(tr("You"))
            } footer: {
                Text(tr("Separate names with commas. In meetings, lines that mention one show under For you, and questions put to you get a reply outline."))
            }
            Section {
                TextField(tr("My notes"), text: $answerer.notes,
                          prompt: Text(tr("Facts about you worth knowing: role, background, projects, numbers…")), axis: .vertical)
                    .lineLimit(6...14)
                    .labelsHidden()
            } header: {
                Text(tr("My notes"))
            } footer: {
                Text(tr("Stays the same from one conversation to the next. For what is only about this one, use Assistant › This conversation."))
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}
