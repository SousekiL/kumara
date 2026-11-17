import LukaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab(tr("General"), systemImage: "gearshape") { GeneralSettings() }
            Tab(tr("Captions"), systemImage: "captions.bubble") { CaptionSettings() }
            Tab(tr("Assistant"), systemImage: "text.badge.star") { SummarySettings() }
            Tab(tr("Usage"), systemImage: "chart.bar") { UsageSettings() }
            Tab(tr("Shortcuts"), systemImage: "command") { ShortcutSettings() }
        }
        .frame(width: 520)
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
                Text(tr("Luka keeps running in the menu bar, so ⌃⌥N can start a transcription at any time."))
            }
            Section {
                SecureField(tr("API key"), text: $model.apiKey)
                LabeledContent(tr("Region")) { KeyStatus() }
                LabeledContent(tr("Model")) { Text(SessionConfig.model).foregroundStyle(.secondary) }
            } header: {
                Text("Soniox")
            } footer: {
                Link(tr("Get a key at console.soniox.com"), destination: URL(string: "https://console.soniox.com")!)
            }
            Section {
                SourcePicker()
                MicrophonePicker()
                LabeledContent(tr("Languages")) { Text(model.languageSummary).foregroundStyle(.secondary) }
            } footer: {
                Text(tr("Change languages from the globe button while listening."))
            }
            Section {
                Toggle(tr("Label Me and Them by source"), isOn: $model.separatesSpeakers)
                Toggle(tr("Translate my speech"), isOn: $model.translatesMyVoice)
                    .disabled(!model.separatesSpeakers)
                Toggle(tr("Pin the latest question"), isOn: $model.pinsQuestions)
            } header: {
                Text(tr("Meetings and interviews"))
            } footer: {
                Text(model.separatesSpeakers && !model.splitsBySource
                     ? tr("Me / Them needs Mac Audio + Microphone, and doesn’t apply in three-way mode.")
                     : tr("The microphone is always you and the Mac audio is everyone else. Turning this on switches the input to Mac Audio + Microphone and runs a second Soniox stream, so it costs about twice as much while on. Wear headphones, or the microphone hears the other side too."))
            }
            Section {
                Toggle(tr("Pause when it’s quiet"), isOn: $model.pausesWhenQuiet)
            } footer: {
                Text(tr("After 3 minutes without sound, Luka closes the Soniox stream, which is billed while open, and starts again when sound returns."))
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
        Form {
            Section {
                Toggle(tr("Liquid Glass"), isOn: $model.liquidGlass)
                    .disabled(!LukaGlassSupport.available)
            } footer: {
                Text(LukaGlassSupport.available
                     ? tr("Turn off for solid, higher-contrast captions and controls.")
                     : tr("Liquid Glass needs macOS 26. Luka uses system materials on this Mac."))
            }
            Section {
                Picker(tr("Show captions"), selection: $model.captionVisibility) {
                    Text(tr("While listening")).tag(CaptionVisibility.whileListening)
                    Text(tr("Always")).tag(CaptionVisibility.always)
                }
            } footer: {
                Text(model.captionVisibility == .whileListening
                     ? tr("Captions fade in when Luka starts listening and out when you finish. ⌃⌥C hides or shows them anytime.")
                     : tr("Captions stay until you hide them with ⌃⌥C."))
            }
            Section {
                Picker(tr("Font"), selection: $model.fontFamily) {
                    Text(tr("System")).tag("")
                    Divider()
                    ForEach(LukaFont.families, id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                Text(tr("Used for captions, the transcript and the summary."))
            }
            Section {
                Picker(tr("Style"), selection: $model.captionStyle) {
                    ForEach(CaptionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent(tr("Text size")) {
                    HStack {
                        Slider(value: $model.captionFontSize, in: AppModel.captionFontRange, step: 2)
                        Text(verbatim: "\(Int(model.captionFontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
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
            } footer: {
                Text(tr("Drag the caption’s top or bottom edge to add lines, its sides to resize. Drop it near the center and it snaps."))
                + Text(verbatim: " ")
                + Text(tr("In three-way mode, captions can show one translation, with the original small above it. Shared Captions always shows all."))
            }
            Section(tr("Transcript")) {
                LabeledContent(tr("Text size")) {
                    HStack {
                        Slider(value: $model.transcriptFontSize, in: AppModel.transcriptFontRange, step: 1)
                        Text(verbatim: "\(Int(model.transcriptFontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
                Toggle(tr("Show Original"), isOn: $model.transcriptShowsOriginal)
            }
            Section {
                LabeledContent(tr("Text size")) {
                    HStack {
                        Slider(value: $model.presenterFontSize, in: AppModel.presenterFontRange, step: 4)
                        Text(verbatim: "\(Int(model.presenterFontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
            } header: {
                Text(tr("Shared Captions"))
            } footer: {
                Text(tr("A regular window for sharing in video calls, with every translation and the original. Open it with ⌘3 and pick it when sharing a window."))
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
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
            Section(tr("In Luka")) {
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
                Text(tr("Usage in Luka"))
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

private struct SummarySettings: View {
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
        Preset(name: "Claude (Anthropic)", provider: .anthropic, baseURL: "", model: "claude-haiku-4-5"),
        Preset(name: "DeepSeek", provider: .openAI, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        Preset(name: "Qwen (DashScope)", provider: .openAI, baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
        Preset(name: "OpenRouter", provider: .openAI, baseURL: "https://openrouter.ai/api/v1", model: ""),
        Preset(name: "Ollama", provider: .openAI, baseURL: "http://localhost:11434/v1", model: ""),
    ]

    var body: some View {
        @Bindable var summarizer = model.summarizer
        @Bindable var answerer = model.answerer
        Form {
            Section {
                LabeledContent(tr("Service")) {
                    Menu(tr("Choose a preset")) {
                        ForEach(Self.presets) { preset in
                            Button(preset.name) {
                                summarizer.provider = preset.provider
                                summarizer.baseURL = preset.baseURL
                                summarizer.model = preset.model
                            }
                        }
                    }
                    .fixedSize()
                }
                Picker(tr("API type"), selection: $summarizer.provider) {
                    Text(tr("OpenAI-compatible")).tag(SummaryProvider.openAI)
                    Text(tr("Anthropic (Claude)")).tag(SummaryProvider.anthropic)
                }
                TextField(tr("Base URL"), text: $summarizer.baseURL, prompt: Text(verbatim: summarizer.provider.defaultBaseURL))
                TextField(tr("Model"), text: $summarizer.model, prompt: Text(tr("The model’s name at this service")))
                SecureField(tr("API key"), text: $summarizer.apiKey)
                HStack {
                    if summarizer.testing {
                        ProgressView().controlSize(.small)
                    } else if let result = summarizer.testResult {
                        Text(result).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button(tr("Test")) { summarizer.test() }
                        .disabled(summarizer.testing || !summarizer.isConfigured)
                }
                .font(.callout)
            } header: {
                Text(tr("Model"))
            } footer: {
                Text(tr("One model, with its own API key, writes both the summary and the answers. A preset fills in the address and a model name to start from; check the name against the service’s current models. Ollama runs on this Mac and needs no key."))
            }
            Section {
                Picker(tr("Mode"), selection: $summarizer.mode) {
                    ForEach(AssistantMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(summarizer.mode.explanation + " " + tr("The mode can also be changed in the column beside the transcript."))
            }
            Section {
                Toggle(tr("Summarize while listening"), isOn: $summarizer.enabled)
                Group {
                    Picker(tr("Detail"), selection: $summarizer.detail) {
                        Text(tr("Concise")).tag(SummaryDetail.concise)
                        Text(tr("Standard")).tag(SummaryDetail.standard)
                        Text(tr("Detailed")).tag(SummaryDetail.detailed)
                    }
                    .pickerStyle(.segmented)
                    TextField(tr("Extra instructions"), text: $summarizer.instructions,
                              prompt: Text(tr("Optional, e.g. “This is an actuarial interview; list every technical question.”")), axis: .vertical)
                        .lineLimit(2...5)
                }
                .disabled(!summarizer.enabled)
            } header: {
                Text(tr("Summary"))
            } footer: {
                Text(tr("In Meeting and Interview mode, new points are added at the end every few sentences and what is already written stays put. In Lecture mode the whole summary is rewritten as the talk goes on."))
            }
            .onChange(of: summarizer.enabled) {
                if summarizer.enabled { summarizer.panelShown = true }
            }
            Section {
                Toggle(tr("Answer questions as they’re asked"), isOn: $answerer.enabled)
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
                .disabled(!answerer.enabled)
                TextField(tr("Extra instructions"), text: $answerer.instructions,
                          prompt: Text(tr("Optional, e.g. “Answer in first person, as a candidate for an actuarial analyst role.”")), axis: .vertical)
                    .lineLimit(2...5)
                    .disabled(!answerer.enabled)
            } header: {
                Text(tr("Answers"))
            } footer: {
                Text(tr("Lecture mode answers nothing. Meeting mode answers only factual or technical questions. Interview mode answers the questions an interviewer asks for the role above (technical, case, behavioral, experience, motivation), and suggests questions to ask back; add your resume and the job description to the knowledge base. With Me / Them on, your own questions are never answered."))
            }
            .onChange(of: answerer.enabled) {
                if answerer.enabled {
                    summarizer.panelShown = true
                    answerer.panelShowsAnswers = true
                }
            }
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
                TextField(tr("My notes"), text: $answerer.notes,
                          prompt: Text(tr("Facts about you worth knowing: role, background, projects, numbers…")), axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text(tr("Knowledge base"))
            } footer: {
                Text(tr("Answers use this first, and the model’s own knowledge only for what it doesn’t cover. Folders are read where they are (Markdown, text, PDF, Word), including subfolders, and reread at the start of every session, so an existing notes or memory folder works as it is. The excerpts that match a question are sent to the model’s provider."))
            }
            Section {
                Picker(tr("Language"), selection: $summarizer.language) {
                    Text(tr("Same as translation")).tag("")
                    Divider()
                    ForEach(Languages.ordered(in: Localizer.shared.locale), id: \.self) {
                        Text(Languages.name($0, in: Localizer.shared.locale)).tag($0)
                    }
                }
                LabeledContent(tr("Text size")) {
                    HStack {
                        Slider(value: $summarizer.fontSize, in: Summarizer.fontRange, step: 1)
                        Text(verbatim: "\(Int(summarizer.fontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
                Toggle(tr("Floating button while listening"), isOn: Binding(get: { model.showsDockButton }, set: { model.showsDockButton = $0 }))
            } header: {
                Text(tr("Display"))
            } footer: {
                Text(tr("The language and text size of the summary and the answers. The floating button sits on the right edge of the screen; click it for the summary and answers over any app, drag it up or down."))
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}
