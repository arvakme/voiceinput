# VoiceInput 2

A native macOS 26+ menu-bar dictation app featuring real-time speech-to-text, LLM-powered text refinement, and vocabulary-aware transcription. Designed for Golden Gate with Liquid Glass aesthetics.

## What is VoiceInput?

VoiceInput is a voice-input companion for macOS developers and writers. Activate it with a customizable global hotkey (default: Fn key) to dictate hands-free, and it transcribes your words in real time, polishes the text with an LLM, optionally translates to a target language, and injects the result into your focused application via keyboard emulation.

**Key features:**

- **Real-time speech recognition** via Soniox realtime streaming ASR (stt-rt-v4)
- **OpenAI-compatible fallback** for HTTP-based ASR (e.g., OpenAI Realtime migration, local servers)
- **Text polish** via OpenRouter (GPT OSS 120B free) to clean disfluencies, fillers, grammar, and punctuation
- **Vocabulary biasing** with custom term hints (e.g., "Claude Code") sent to Soniox for better accuracy
- **Translation** via Ollama (hy-mt2 model) to English, Simplified Chinese, Traditional Chinese, or Korean
- **Three hotkey modes** on one key: Hold (push-to-talk), Tap (toggle), Double-tap (hands-free with silence auto-stop)
- **Liquid Glass UI** — borderless floating voice box with adjustable transparency, live auto-scrolling transcript, waveform visualization, and a ChatWise-style settings window
- **Window-like voice box** — drag anywhere to move it, drag any edge/corner to resize it; both position and size persist
- **Compact capsule mode** — minimize the box (⤡ button, top-right) into a small glass capsule with its own resizable dimensions
- **Dictation history** — every completed session stores raw + refined transcripts and the audio (WAV); browse, search, replay, copy, and delete in the History window (⌘Y from the menu bar)
- **Live menu-bar state** — template mic when idle, red filled mic while listening, yellow while finalizing, accent waveform while polishing
- **Media control** — pauses and resumes Spotify/Apple Music via state-checked AppleScript; other players are not automatically controlled
- **Theme override** — System / Light / Dark picker; all colors resolve dynamically at runtime
- **Accessibility** — requires Microphone + Accessibility permissions; respects Reduce Transparency

## Requirements

- **macOS 26.0+** (Golden Gate compatible; tested with Xcode 26 Command Line Tools)
- **Xcode 26 Command Line Tools** (includes Swift 6 toolchain, language mode v5)
- **API Keys** (after first install):
  - `SONIOX_API_KEY` — for Soniox realtime ASR (get from [soniox.com](https://soniox.com))
  - `OPENROUTER_API_KEY` — for text polish via OpenRouter (free tier available)
  - Optional: `OLLAMA_API_KEY` if using non-local Ollama (default: `http://127.0.0.1:11434/v1`)

## Build

```bash
# One-shot build and install
make install

# Or step by step
make build          # Compile: swift build -c release
make run            # Launch app (for testing)
make clean          # Remove build artifacts
```

The Makefile assembles a proper `.app` bundle (VoiceInput.app) with:
- Binary at `Contents/MacOS/VoiceInput`
- Info.plist with `NSMicrophoneUsageDescription`, `NSAppleEventsUsageDescription` (for media pause)
- AppIcon.icns in `Contents/Resources`
- Ad-hoc code signature

## Regression tests and toolchain notes

```bash
make test           # Swift Testing; no API keys, microphone, or real history required
```

The offline suite covers corrupt history preservation, audio path boundaries,
preset fallback, reconnect budgets, and malformed/empty/incomplete LLM responses.
It does not simulate Accessibility injection, real microphone/system capture,
or provider authentication. Those still require a manual dictation smoke test.

If macOS 27 beta Command Line Tools fail with `SwiftUIMacros.StateMacro` missing,
use an installed macOS 26 SDK for this macOS 26+ project, or a complete matching
Xcode installation. On the audited machine, these commands work around the CLT
SDK and test-framework lookup issues without changing `xcode-select` globally:

```bash
make build SWIFT_FLAGS='--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'
make test SWIFT_FLAGS='--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib'
```

The paths are machine-specific; use your installed SDK/framework paths. This CLT
version also emits linker warnings for two nonexistent `CommandLineTools/Developer`
search paths. These are toolchain warnings, not source compilation failures.

## First Run

1. **Set up environment:**

   ```bash
   cd /path/to/voiceinput
   # Create .env.local with your API keys (gitignored — never commit it)
   cat > .env.local << 'EOF'
   SONIOX_API_KEY=your_soniox_key
   OPENROUTER_API_KEY=sk-or-v1-...
   EOF
   ```

2. **Seed UserDefaults with keys:**

   ```bash
   bash scripts/seed-keys.sh
   ```

   This reads `.env.local` and populates `com.zhijie.VoiceInput` domain via `defaults write`.

3. **Grant permissions** (macOS will prompt first use, or grant manually):

   - **Microphone**: System Settings → Privacy & Security → Microphone → Enable VoiceInput
   - **Accessibility**: System Settings → Privacy & Security → Accessibility → Enable VoiceInput

4. **Configure & test:**

   - Launch VoiceInput (appears in menu bar as a mic icon)
   - Open Settings ("Settings…" in menu)
   - Go to **Providers** tab and click **Test** on Soniox to verify connectivity
   - Adjust **General** language hints, **Hotkey**, **Appearance** as desired

## Hotkey Modes

All three modes activate on a single key (default: Fn, customizable via Settings → Hotkey):

| Mode | Interaction | Behavior |
|------|---|---|
| **Hold** (≥200 ms) | Press and hold the hotkey | Push-to-talk: records while pressed; releases stops and injects. Forgiving 300 ms window—brief gaps don't end recording. |
| **Tap** (release <200 ms) | Quick tap | Toggle: first tap starts recording, second tap (or hotkey again) stops and injects. |
| **Hands-free** (double-tap within 350 ms) | Two quick taps | Starts recording; ends automatically on silence (2500 ms of no speech detected) or when you tap the hotkey again. Great for long monologues. |

Press **Esc** anywhere to cancel the current session (discards transcript, no injection).

## Providers Configuration

### ASR (Speech Recognition)

**Soniox Realtime** (primary, recommended):
- WebSocket realtime streaming at `wss://stt-rt.soniox.com/transcribe-websocket`
- Model: `stt-rt-v4` (current GA, supports 60+ languages, semantic endpoint detection)
- **Settings**: General → Language Hints (e.g., `zh,en` for mixed Chinese–English)
- **Providers** → Soniox: paste your API key, verify with Test button

**OpenAI-Compatible HTTP** (fallback):
- POST to `https://api.openai.com/v1/audio/transcriptions` or compatible endpoint
- Records audio as WAV, sends file on stop (no real-time transcript)
- **Limitation**: hands-free silence auto-stop is impossible (no interim results)—can only end via hotkey
- **Settings**: Providers → OpenAI-compatible ASR → set base URL, key, model name

### Text Polish

**OpenRouter + GPT OSS 120B:free**:
- Cleans disfluencies, fillers, repeats, false starts, punctuation, grammar
- Preserves meaning, tone, source language; keeps natural zh/en mix
- Temperature 0.3, max 2048 tokens
- Includes reasoning field (low effort) for deeper cleanup
- **Settings**: Providers → Polish → toggle Enable, set API key, model, Test

### Translation

**Ollama + hy-mt2-1.8b-translate**:
- Fast local neural machine translation (1.8B parameters)
- Targets: English, Simplified Chinese, Traditional Chinese, Korean
- Runs on `http://127.0.0.1:11434/v1` by default (local Ollama server)
- Can override base URL for remote Ollama
- Temperature 0.1 (deterministic)
- **Settings**: Providers → Translate → toggle Enable, pick target language, configure base URL if needed

## Vocabulary Correction

Custom vocabulary allows Soniox to recognize your preferred terms and polish to correct mishearings.

**Example:**
```
Term: Claude Code
Hints: cloud code, clot code
```

Soniox receives "Claude Code" in its context window for recognition biasing.
If it mishears "cloud code," the polish step uses the hint list to spot and correct it to "Claude Code."

**Settings:**
- Providers → Vocabulary tab
- Add entries: term (canonical form) + hints (comma-separated common mishearings)
- Delete with minus button; edit inline
- Entries persist to UserDefaults

**How it works:**
- Soniox context.terms: vocabulary canonical terms boost recognition accuracy
- Polish system prompt includes: `"If the transcript contains something like the left side, the speaker almost certainly meant the right side: - 'cloud code' → 'Claude Code'"` etc.
- Improves both ASR and post-hoc correction

## UI & Settings

### Overlay Panel (during recording)

- Floating Liquid Glass voice box (default 680×200 pt, centered at 62% from screen bottom)
- **Move**: drag anywhere on the glass; **Resize**: drag any edge or corner like a normal window (system resize cursors). Position and size persist; "Reset layout" in Appearance restores defaults
- **Transcript area** (top): final text + interim text with soft shimmer, auto-scrolls to the newest words past the visible height (flick up to re-read mid-dictation)
- **Waveform** (center): real-time audio levels; bar count adapts to the box width
- **Minimize** (⤡, top-right): collapses into a compact glass capsule (dot + waveform + countdown + stop + expand) — independently resizable, mode persists across sessions
- **Bottom bar**:
  - Left: phase indicator dot (pulsing accent while listening, yellow finalizing, purple refining) + status label
  - Hands-free countdown pill (e.g., "2.5s") when active
  - Polish & Translate chips — **click to toggle** the feature on/off
  - Right: Stop button + hotkey badge, Cancel button + Esc badge

### Settings Window (ChatWise style)

640×560 minimum, full-size content, hidden title bar, icon-tab strip:

1. **General**: App enable toggle, language hints field (ISO codes, e.g., `zh,en`), "Pause media while dictating" toggle
2. **Hotkey**: Key picker (Fn, Right ⌘, Right ⌥, Right ⇧, Right ⌃, Custom), shortcut recorder, timing steppers (tap/hold threshold, double-press window, hold forgive, silence duration)
3. **Providers**: Master-detail source list (Soniox, OpenAI-compatible, Polish, Translate) with status dots and detail panes per provider
4. **Vocabulary**: Term + mishearings table, +/− buttons, explainer card
5. **Appearance**: Theme picker (System / Light / Dark), voice-box transparency slider (0% = clear glass, 100% = solid), vertical position slider, Reset layout, Preview button (shows sample transcription for 4 s)
6. **Permissions**: Microphone + Accessibility rows with status and grant buttons

Theme: ChatWise palette (blue accent #4E80EE light / #2464EB dark, warm stone sidebar, white content background). Colors resolve dynamically — switching theme repaints every window without relaunch.

### History Window (⌘Y from the menu bar)

Master-detail browser over every completed dictation: searchable session list (transcript preview + relative time + duration), per-session raw/refined transcripts with copy buttons, an audio player for the stored WAV, and delete / Clear All. Storage lives in `~/Library/Application Support/VoiceInput/` (`history.json` + `audio/*.wav`), pruned beyond the configured session limit (default 200). Toggles for saving history and keeping audio live in the window footer; cancelled or empty sessions are never recorded.

## Liquid Glass Transparency

Adjustable in Settings → Appearance (default 25%):

- **0%**: Pure Liquid Glass, highly transparent
- **25%**: Default—subtle frosted effect
- **100%**: Solid panel (opaque)

On macOS 27, your adjustment layers on top of the system Liquid Glass opacity slider.

Respects **Reduce Transparency** accessibility setting → forces opaque.

## Architecture

One Swift Package Module (VoiceInput), no inter-file imports needed:

- **App/**: AppDelegate, DictationController (orchestration), AppState
- **Core/**: AppSettings (UserDefaults-backed), VocabularyStore, Log (os.Logger)
- **Audio/**: AudioCapture (AVAudioEngine tap + format conversion)
- **ASR/**: Soniox realtime WebSocket, OpenAI-compatible HTTP transcription
- **Refine/**: Refiner (polish + translate chaining)
- **System/**: KeyMonitor (hotkey state machine), TextInjector, MediaController, PermissionStatus
- **UI/**: Theme (ChatWise palette), OverlayPanel (Liquid Glass voice box), SettingsWindow (SwiftUI)

## Troubleshooting

**Hotkey not working:**
- Check Settings → Hotkey → Test by pressing the configured key (status should change)
- Ensure Accessibility permission is granted (Settings → Permissions tab)
- Try resetting to Fn key (default)

**No audio capture:**
- Verify Microphone permission (Settings → Permissions → Grant)
- Check System Preferences → Security & Privacy → Microphone → VoiceInput enabled
- Test with `afplay` or built-in Audio MIDI Setup

**Soniox "auth" error:**
- Verify API key is correct (Settings → Providers → Soniox, Test button)
- Check `.env.local` and re-run `bash scripts/seed-keys.sh`

**Polish or Translate not working:**
- For Polish: verify OpenRouter API key, check OpenRouter account balance
- For Translate: ensure Ollama is running (`ollama serve`), pull model with `ollama pull hy-mt2-1.8b-translate:latest`
- Test buttons in Settings → Providers show errors inline

**Media doesn't pause while dictating:**
- First use needs an Automation consent prompt (VoiceInput → Spotify/Music) — approve it in System Settings → Privacy & Security → Automation if missed
- Automatic pause/resume supports Spotify and Apple Music only. There is no generic media-key fallback, because it can start playback or launch Music when nothing was playing.
- The General tab toggle must be on

**Vocabulary not helping:**
- Verify entries are added in Settings → Vocabulary
- Check Soniox is the active ASR backend (Settings → Providers)
- Soniox context updates on next session (reconnect WebSocket)
- Try rebooting Soniox session if vocabulary was just added

## Development

Code compiles under Swift 6 (`swift build -c release`) with zero warnings, using language mode v5 to support pre-concurrency AppKit patterns. No third-party dependencies—AppKit, SwiftUI, Foundation, AVFoundation, Carbon (TIS) only.

Follows the contract in SPEC.md (public interface compliance). All main-thread mutations in AppState, callbacks on main thread, generation counters for session invalidation, graceful fallback on LLM failures.

## License

No license specified yet.

## 2026-09-06 product fixes

Polish now supports OpenRouter/custom APIs, the official Cursor SDK with a Cursor User API key, and Codex/Grok account sign-in. See [setup, supported media, and validation](docs/reviews/2026-09-06-product-fixes.md). The Cursor SDK helper is packaged as a SwiftPM resource; use `make build` to produce a complete app bundle.

## Cursor latency, model search, and stable updates

Cursor now prewarms an app-owned worker and reuses runtime infrastructure while keeping each dictation independent. Model fields open searchable provider catalogs, including explicit Fast/Standard variants. Release builds use a persistent signing certificate to preserve app identity across updates. See [measurements and behavior](docs/reviews/2026-09-06-performance-and-permissions.md) and [signing setup](docs/SIGNING.md).
