# Soniox Real-Time STT WebSocket API — Integration Report

*Compiled 2026-06-11 from official docs (soniox.com/docs). Exact JSON field names quoted verbatim.*

## 1. Endpoint & Connection Handshake

**Endpoint:** `wss://stt-rt.soniox.com/transcribe-websocket`

Flow: open the WebSocket → send **one JSON text frame** (the config) as the first message → stream audio as binary frames → receive JSON text frames with tokens.

**Config message schema (first message, JSON text frame):**

```json
{
  "api_key": "<SONIOX_API_KEY or temporary API key>",
  "model": "stt-rt-v4",
  "audio_format": "pcm_s16le",
  "sample_rate": 16000,
  "num_channels": 1,
  "language_hints": ["zh", "en"],
  "language_hints_strict": false,
  "enable_language_identification": true,
  "enable_speaker_diarization": false,
  "enable_endpoint_detection": true,
  "max_endpoint_delay_ms": 2000,
  "context": { "general": [], "text": "", "terms": [], "translation_terms": [] },
  "translation": { "type": "one_way", "target_language": "es" },
  "client_reference_id": "optional, max 256 chars"
}
```

Field notes:
- `api_key` (required) — supports regular keys and temporary API keys.
- `model` (required) — **current GA realtime model is `stt-rt-v5`** (released 2026-06-16; major gains in noisy/telephone/multi-speaker/accented/overlapping/language-switching accuracy AND translation quality). Fully API-compatible with v4 — drop-in, just change the model name. **`stt-rt-v4` retires 2026-06-30** and auto-routes to v5 after. Async equivalent: `stt-async-v5`.
- Real-time translation (unchanged from v4): `translation: {type:"one_way", target_language:"zh"}` or `{type:"two_way", language_a:"en", language_b:"zh"}`; tokens tagged `translation_status` = `"original"` / `"translation"`. v5 adds optional `context.translation_terms` (array of `{source, target}`) for custom translation vocabulary.
- `audio_format` (required) — `"auto"` for containerized formats, or raw: `pcm_s16le` etc. **Raw formats require `sample_rate` and `num_channels`.** Use `"pcm_s16le"`, `16000`, `1`.
- `max_endpoint_delay_ms` — allowed 500–3000, default 2000.
- `translation` — one-way: `{"type": "one_way", "target_language": "es"}`; two-way: `{"type": "two_way", "language_a": "en", "language_b": "es"}`.

## 2. Audio Streaming Protocol

- Send audio as **binary WebSocket frames** containing raw bytes in the declared format. No per-chunk envelope.
- Cadence: ~120 ms intervals (docs/SDK pacing). At 16 kHz/16-bit mono that's ~3,840 bytes per chunk. Anything ~50–200 ms is fine. Don't fall behind real time — server emits "Input too slow" / "Timed out while waiting for the first audio chunk" (408-style) errors.
- **End-of-audio:** send an **empty WebSocket frame (binary or text)**. Server finalizes everything, sends remaining tokens, sends a last message with `"finished": true`, and closes.
- **Control frames (JSON text frames, may interleave with audio):**
  - `{"type": "keepalive"}` — keeps session open while not sending audio.
  - `{"type": "finalize"}` — forces finalization of all audio sent so far.

## 3. Response Message Schema

Every server message is a JSON text frame:

```json
{
  "tokens": [
    { "text": "Hello", "start_ms": 600, "end_ms": 760, "confidence": 0.97,
      "is_final": true, "speaker": "1", "language": "en",
      "translation_status": "original" }
  ],
  "final_audio_proc_ms": 760,
  "total_audio_proc_ms": 880
}
```

- Token fields: `text`, `start_ms`, `end_ms` (may be absent on special tokens), `confidence` (0.0–1.0), `is_final`, `speaker` (only with diarization), `language` (ISO 639-1, only with language ID), `translation_status` (`"original"`/`"translation"`, only with translation).
- **Interim vs final:** non-final tokens (`is_final: false`) are provisional — re-sent in full on each response. Final tokens are immutable, sent exactly once. **Rendering rule: transcript = accumulated final tokens + the non-final tokens from the latest message only** (discard previous non-finals each message).
- **Special tokens:** endpoint detection emits `{"text": "<end>", "is_final": true}` once per utterance after preceding tokens finalize. After manual `finalize`, server emits `{"text": "<fin>", "is_final": true}`. **Filter both out of displayed text.**
- **Session end:** final message contains `"finished": true`, then server closes.
- **Error schema:** `{"error_code": <number>, "error_type": "...", "error_message": "...", "more_info": "<docs URL>", "request_id": "<id>"}`. `error_code` mirrors HTTP: 400 (bad config), 401 (auth), 402 (payment), 403, 408 (audio timeout), 429 (rate/concurrency), 500, 503.

## 4. Context / Custom Vocabulary Biasing

Field name: **`context`** (object) in the config message:

| Field | Type | Use |
|---|---|---|
| `general` | array of `{"key":..., "value":...}` | Domain/topic/participants metadata |
| `terms` | **array of strings** | Domain-specific or uncommon words — **the mechanism for the user vocabulary list** |
| `text` | string | Long free-form background docs (weakest influence) |
| `translation_terms` | array of `{"source":..., "target":...}` | Custom translation mappings |

Example:

```json
"context": {
  "general": [ { "key": "domain", "value": "Software engineering" } ],
  "terms": ["Soniox", "Claude Code", "AVAudioEngine", "微服务"]
}
```

- **Limit: 8,000 tokens (~10,000 characters) across the whole context object**; exceeding returns an API error.
- Influence ranking: `terms` > `general` > `text`. Context is set once per session at config time — to update vocabulary, reconnect.

## 5. Mixed Chinese + English

- Set `"language_hints": ["zh", "en"]` and `"enable_language_identification": true`.
- Language ID is token-level; Soniox handles code-switching within one stream.
- `language_hints_strict: true` constrains output more strongly toward hinted languages.
- Token `text` includes its own leading space where appropriate (English) and no spaces for Chinese — plain string concatenation produces correct output.

## 6. Limits, Keepalive, Reconnection

- **Rate limits (defaults):** 100 requests/min, **10 concurrent WebSocket connections**, **300 minutes max per stream (fixed)**. 429 on excess.
- **Keepalive:** if server receives no audio and no keepalive for **>20 seconds**, it may close. Send `{"type": "keepalive"}` every 5–10 s when paused.
- **Billing:** charged for full stream duration, not just speech — for push-to-talk, disconnect between utterances rather than idling.
- **Reconnection:** sessions are stateless, not resumable. On unexpected close: keep accumulated final tokens client-side, reopen socket, resend config (including `context`), resume streaming. Backoff on 429.

## 7. Swift Integration Sketch (URLSessionWebSocketTask)

Key points (full sketch validated against docs):
- `URLSession.shared.webSocketTask(with: URL("wss://stt-rt.soniox.com/transcribe-websocket"))`, `resume()`, send config as `.string(json)` first.
- Mic: `AVAudioEngine` input tap at hardware format (e.g. 48 kHz float32), convert with `AVAudioConverter` to 16 kHz mono Int16 interleaved, send `Data` as `.data(...)` binary frames (~100 ms per tap buffer: `bufferSize = hwSampleRate / 10`).
- Note: macOS has NO `AVAudioSession` — that's iOS-only. Just tap `AVAudioEngine.inputNode` directly.
- Receive loop: parse JSON; `error_code` present → error; iterate `tokens`; `text == "<end>"` → utterance end marker; `text == "<fin>"` → finalize marker; `is_final` → append to accumulated finals; else collect interim (fully replace previous interims each message); `finished == true` → done.
- `finalize()` → send `{"type": "finalize"}`; `stop()` → remove tap, stop engine, send empty `Data()` frame, await `finished`, then `cancel(with: .normalClosure)`.

## Quick Answers

- **Speaker diarization in realtime:** Yes — `"enable_speaker_diarization": true` adds `"speaker"` labels per token. Lower accuracy than async.
- **GA realtime model (mid-2026):** **`stt-rt-v4`** — 60+ languages, improved semantic endpointing, lower final-token latency.

Sources: soniox.com/docs/stt/api-reference/websocket-api, /stt/rt/real-time-transcription, /stt/models, /stt/concepts/context, /stt/rt/endpoint-detection, /stt/rt/manual-finalization, /stt/rt/connection-keepalive, /stt/rt/limits-and-quotas, /stt/concepts/language-identification, blog/2026-02-05-soniox-v4-real-time
