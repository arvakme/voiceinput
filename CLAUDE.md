# CLAUDE.md

> claude --resume a9faa47e-6d0a-4247-9b05-fbb2c48df3ab

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make build     # swift build -c release + assemble VoiceInput.app (ad-hoc codesigned)
make run       # build and launch
make install   # build and copy to /Applications
make clean     # remove build artifacts
swift build -c release   # compile only — must finish with zero errors AND zero warnings
```

There is no test suite. Verification is: clean release build, then launch the app and exercise the dictation flow (hotkey → speak → text lands in the focused app).

First-run setup: create a gitignored `.env.local` with `SONIOX_API_KEY` and `OPENROUTER_API_KEY`, then `bash scripts/seed-keys.sh` (writes them into the `com.zhijie.VoiceInput` UserDefaults domain). Never hardcode keys in source.

## What this is

A macOS 26+ menu-bar dictation app (single SPM executable module, no third-party dependencies, Swift language mode v5 — deliberate, to keep ported pre-concurrency AppKit patterns; do not "fix" it to v6). `SPEC.md` is the original build contract: public types/methods are declared there and the code matches it. `docs/research/` holds the protocol/design references the implementation was built against (Soniox WebSocket API, Liquid Glass APIs and technique, ChatWise palette + OpenRouter specifics) — consult these before touching the corresponding subsystem; they are more specific than vendor docs.

## Big-picture flow

`KeyMonitor` (CGEventTap + NSEvent fallback; hold/tap/double-tap state machine on one key) → `AppDelegate` (wiring, status item, rewires on settings changes) → `DictationController` (session lifecycle, the only writer of `AppState`) → a per-session `TranscriptionSession` (`SonioxRealtimeSession` streaming over WebSocket, or `HTTPTranscriptionSession` batch WAV upload) fed by `AudioCapture` (AVAudioEngine → 16 kHz mono s16le) → `Refiner` (polish via OpenRouter, then translate via Ollama, sequential) → `TextInjector` (clipboard + synthetic Cmd-V, IME-aware) → `HistoryStore` (records raw/refined/WAV under `~/Library/Application Support/VoiceInput/`).

The overlay (`OverlayPanel` + `GlassVoiceBox`) renders purely reactively from `AppState`/`AppSettings`; `DictationController` owns sequencing (media resume, KeyMonitor reset, error dwell) — don't move that into the UI.

A second, independent pipeline is Live Captions (`Listen/` + `UI/Listen/`, toggled by Fn+Space via `ListenHotkey`): `SystemAudioCapture` (ScreenCaptureKit audio-only, needs Screen & System Audio Recording TCC) or `AudioCapture` → `ListenSession` (one Soniox WebSocket with `translation: one_way`; tokens route by `translation_status` into original/translation columns) → `ListenController`/`ListenState` → `ListenPanel`. Target-language changes restart the WS carrying displayed text; source changes swap only the capture.

## Invariants (each one encodes a fixed bug — violating them reintroduces it)

- **One Liquid Glass surface per panel.** The box background is the only `glassEffect`. A second glass level above content (e.g. glass buttons) inside a `GlassEffectContainer` makes the compositor render all glass in one pass above the sandwiched content, fogging it.
- **The overlay panel never becomes key** (`NonActivatingPanel`), so its hosting view must accept first mouse (`FirstMouseHostingView`) or every control eats the first click.
- **Resizing is custom.** `BoxResizeController` drags the panel frame from SwiftUI edge handles using `NSEvent.mouseLocation` (global coords — immune to the view moving mid-drag). Do not add `.resizable` to the styleMask: the panel edge sits 40 pt outside the visible glass (shadow canvas), so AppKit's resize zone would be unreachable.
- **All UI-bound callbacks land on the main thread; `AppState` mutates only there.** Async session callbacks are guarded by generation counters so a stale session can never touch fresh state.
- **The transcript is sacred.** Any failure after speech ends (refine, inject) still delivers the best text available; only an explicit cancel discards it.
- **Soniox token semantics:** final tokens are append-only; non-final tokens are replaced wholesale on every message; `<end>` and `<fin>` are control tokens — filter them from display. Graceful stop is `finalize` → empty frame → await `"finished": true` (3 s timeout falls back to accumulated finals).
- **macOS has no `AVAudioSession`** — that's iOS-only. Tap `AVAudioEngine.inputNode` directly.
- **Soniox batch is NOT OpenAI-compatible.** "Just transcribe" mode routes by URL: Soniox URLs go through `SonioxAsyncSession` (POST /files multipart → POST /transcriptions {model, file_id} → poll status → GET …/transcript → DELETE cleanup); everything else uses the OpenAI-style `/audio/transcriptions` multipart. Don't point `HTTPTranscriptionSession` at Soniox.
- **OpenRouter `:free` endpoints support no `response_format`** — prompt for plain text. The `reasoning` field is sent only when the base URL contains "openrouter". Refine steps never throw to the caller; a failed step logs and passes the prior text through.
- **MRMediaRemote is dead** for third-party apps (macOS 15.4+). Media pause is AppleScript for Spotify/Apple Music ONLY, state-checked (`player state == playing`) so resume only undoes what pause did. There is deliberately NO generic fallback: the old CoreAudio (`kAudioDevicePropertyDeviceIsRunningSomewhere`) + system play/pause media-key path false-positived on any app merely holding the output device open and, with nothing actually playing, made macOS launch Apple Music. Don't reintroduce a media-key fallback — it cannot be made launch-safe without a real "now playing" signal.
- **The waveform render clock is phase-gated.** `WaveformView` only mounts `TimelineView(.animation)` during audio-active phases (connecting/listening/finalizing); otherwise it draws one static `Canvas`. The overlay's `GlassVoiceBox` is never unmounted (dismiss only sets opacity 0 + `orderOut`), so an unconditional `TimelineView(.animation)` repaints at display refresh rate forever behind the hidden panel — that was a ~50% idle CPU drain. Same rule for any `repeatForever` animation (e.g. pulse dots): gate it on an active flag, never start-and-forget in `onAppear`.
- **Settings UI uses `Theme` colors only** (ChatWise palette via `NSColor(name:dynamicProvider:)` so the Light/Dark override repaints live). New settings follow the existing pattern in `AppSettings`: a `Key` constant, a seeded default in `init`, an `@Published` property with `didSet` persistence.
