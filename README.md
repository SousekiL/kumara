<p align="center">
  <img src="docs/assets/icon.png" width="128" alt="Luka">
</p>

<h1 align="center">Luka</h1>

<p align="center">
  <strong>Live captions for everything your Mac hears.</strong><br>
  Transcribes and translates calls, videos and meetings as they happen, and tells you who is talking.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat-square" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/speech-Soniox%20stt--rt--v6-FF6A3D?style=flat-square" alt="Soniox">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT"></a>
</p>

<p align="center">
  <b>English</b> | <a href="docs/README.ko.md">한국어</a> | <a href="docs/README.zh.md">中文</a>
</p>

<p align="center">
  <img src="docs/assets/hero.png" width="820" alt="Luka transcript window and captions">
</p>

---

## Install

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/StableFluffy/luka/main/install.sh | sh
```

It installs the latest release into Applications (or updates it there), checks that the app is signed and notarized, and opens it. The same command updates Luka later. Prefer a disk image? Download `Luka-<version>.dmg` from [Releases](../../releases) and drag **Luka** into **Applications**.

Then:

1. Paste a [Soniox API key](https://console.soniox.com) into the first window.
2. Press <kbd>⌃</kbd><kbd>⌥</kbd><kbd>N</kbd> and allow **System Audio Recording** when asked.

Requires macOS 15 or newer; Liquid Glass on macOS 26 and later. Soniox bills per audio hour ([pricing](https://soniox.com/pricing)).

## Captions

<p align="center">
  <img src="docs/assets/captions.png" width="720" alt="Caption strip">
</p>

A glass strip that floats over any app, full-screen video included, and never takes focus.
It appears when Luka starts listening and fades out when you finish; <kbd>⌃</kbd><kbd>⌥</kbd><kbd>C</kbd> hides it anytime.

| Do | Result |
| --- | --- |
| Drag the top or bottom edge | Add or remove lines (1–6) |
| Drag a side | Resize width |
| Drop near screen center | Snaps to center |
| Hover | Controls for language, source, size and lock |
| Click a speaker name | Rename them, everywhere, live |
| Lock <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd> | Click-through; hover shows **Unlock** |

## Sessions

Every transcription is a session in the sidebar, saved as you go.
Click the title to rename it. Finish with <kbd>⌘</kbd><kbd>.</kbd>, then **Continue** later, edit lines, or copy everything with <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd>.

Speakers split by mistake? Open a name and choose **Same person as…**.

## Shortcuts

Work from any app:

| Keys | Action |
| --- | --- |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>N</kbd> | New transcription |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>R</kbd> | Start / pause |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>C</kbd> | Show / hide captions |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>T</kbd> | Show / hide transcript |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd> | Lock / unlock captions |

Inside Luka: <kbd>⌘</kbd><kbd>E</kbd> names whoever is speaking, <kbd>⌘</kbd><kbd>1</kbd> / <kbd>⌘</kbd><kbd>2</kbd> toggle windows, <kbd>⌘</kbd><kbd>+</kbd> <kbd>⌘</kbd><kbd>−</kbd> text size, <kbd>⌘</kbd><kbd>↑</kbd> <kbd>⌘</kbd><kbd>↓</kbd> caption lines.

## Modes

| Mode | For |
| --- | --- |
| Translate | Any spoken language → one language |
| Two-way | Conversations: each side translated to the other |
| Transcribe | Write it down, no translation |

Listen to Mac audio, the microphone, or both. The interface speaks English, 한국어 and 中文.

## This fork: Luka Plus

This fork builds as **Luka Plus** (`~/Applications/Luka Plus.app`, bundle ID `io.github.sousekil.luka-plus`), so it sits beside the original Luka without being mistaken for it. It takes over the original's settings on first launch and shares its API key and sessions; don't run both at once. Settings › Captions › **Font** sets the font for captions, the transcript and the summary.

## Meetings and interviews

Settings › General › **Meetings and interviews**, also in the menu bar:

| Option | What it does |
| --- | --- |
| Label Me and Them by source | With **Mac Audio + Microphone**, the microphone is always **Me** and the Mac audio is always **Them**, on two separate Soniox streams. No more guessing voices; costs a second stream while on. |
| Translate my speech | In Me / Them mode, translate your own words too, or only write them down. |
| Pin the latest question | Keeps the latest question (from Them, or anyone when Me / Them is off) above the captions while you answer. Click × to unpin. Off by default. |

## Usage

Settings › General › **Usage** shows audio sent to Soniox this session, this month and last month, with an estimated cost ($0.12 per hour transcribed, $0.18 per hour translated, per stream). The menu bar shows this month's total.

## Live summary

Settings › **Assistant**: pick any OpenAI-compatible model (OpenAI, DeepSeek, Qwen, OpenRouter, Ollama…) or Claude, with its own API key. While you listen, a column beside the transcript keeps running notes: every few sentences, new points are added at the end under topic headings, in the order they were said, and what is already written stays put, so you only read the newest lines to keep up. ↻ writes the notes again from the whole transcript; they are saved with the session and lead the Markdown export. The transcript text goes to the model's provider; use Ollama to keep it on your Mac.

## Assistant modes

Pick **Lecture**, **Meeting** or **Interview** at the top of the summary column, in the menu bar, or in Settings › Assistant. A mode sets the scene in one go, and every switch it sets can still be changed by hand afterwards:

| | Lecture | Meeting | Interview |
|---|---|---|---|
| Summary | off | on (running notes) | off |
| Answers | off | off | on |
| Me / Them | off | on (others numbered) | on |
| Pin the latest question | off | off | on |
| Polish my answers | — | — | on |

Settings › Assistant › **This conversation** holds the role you're interviewing for and one note about this conversation, read by both the summary and the answers. Settings › **Knowledge** holds what stays the same: files, folders and your own notes.

## Floating button

While Luka listens, a small button sits on the right edge of the screen, its dots moving with the sound. Click it for the summary and answers in a floating panel over any app, full-screen ones included; a red mark means an answer arrived while it was closed. Its top half opens the panel, its bottom half shows or hides the captions. Drag it up or down; turn it off in Settings › Assistant › Output or the menu bar's Windows menu. With the Dark caption style, the panel uses the same black and opacity as the captions.

## Answers and knowledge base

Settings › Assistant › **Answers**: when someone else asks a question, the summary's model writes a short answer with hints in the **Answers** column beside the transcript. It draws first on your **knowledge base**: files and folders you point it at (Markdown, text, PDF, Word; folders are read in place and reread at the start of each session, so an existing notes or memory folder works as it is) plus your own notes. What the knowledge base doesn't cover, the model answers from its own knowledge, and each answer says which it was. Answers stream in as they are written: the question shows at once, then the gist, then the points, with the words to say in the accent color.

## Soniox account

Settings › General › **Soniox account** shows what Soniox itself reports: this month's cost for your key's project (all apps), and, with an organization API key (`snx_org_…`), the prepaid balance, also shown in the menu bar.

## Privacy

Audio goes straight from your Mac to Soniox over WebSocket; there is no Luka server.
The API key is AES-GCM encrypted in `~/Library/Application Support/Luka/`, sessions are JSON files next to it.

## Build from source

```sh
./scripts/build-app.sh --install   # ~/Applications/Luka.app
./scripts/build-app.sh --dmg       # build/Luka-<version>.dmg
./scripts/build-app.sh --release   # signed + notarized DMG and zip (Developer ID)
swift test                         # replays recorded Soniox streams
```

Builds with Xcode 26 / Swift 6.2 and runs on macOS 15+. Debug flags: `--feed file.pcm` streams a 16 kHz mono file instead of live audio.

## License

MIT
