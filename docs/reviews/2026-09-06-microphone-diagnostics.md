# Microphone / realtime diagnosis preview

This preview fixes misleading diagnostics; it does not claim to resolve an
unreproduced macOS 26.5.1 microphone failure.

## Confirmed findings

- The old waveform moved even at zero input because it added a synthetic sine
  ripple. It now renders only measured, converted PCM energy.
- The old connection test succeeded after four seconds even if its config send
  had not completed. A pending send now times out as a failure. A completed send
  or server response explicitly does not certify microphone or transcription.
- Empty transcripts are intentionally omitted from history, including audio.
  Therefore a missing history WAV cannot establish that capture failed. This
  preview adds explicit local test recording/export, without changing history
  retention or automatically saving unsuccessful dictation audio.
- The v1.1.1 and v1.2.0 microphone initialization/conversion code was identical;
  v1.2.0 only added tail-chunk flushing during stop.

## Test on the affected Mac

1. Finish dictation and quit VoiceInput normally before replacing the app.
2. Open Settings → Providers → Voice model → **Test microphone (5 seconds)**.
   Speak a short sentence. This test uses the production AudioCapture path and
   does not send audio to an ASR provider.
3. Copy the result. It distinguishes no incoming frames, no converted PCM,
   all-zero PCM, and nonzero PCM; it includes format and conversion errors.
4. If available, choose **Export test WAV…** and play the file. Export works
   without a transcript or enabled history. Do not share private speech; the
   diagnostic summary and whether playback is audible are sufficient initially.
5. If the WAV sounds normal, try normal realtime dictation. Logs now include
   capture frame/peak counts, queued PCM bytes, and first successful audio send.
   A completed WebSocket send is not a server transcription acknowledgement.

The capture path validates hardware/tap formats, creates a fresh engine per
start, logs conversion errors, and meters the actual converted Int16 audio.
Mid-recording route recovery is not implemented; a changed buffer format is
rejected and reported rather than fed to a stale converter. Start another
recording after changing the sound input.

## Validation

- Offline Swift regression suite, including the real AVAudioConverter at
  44.1/48 kHz, Float32/Int16, mono/stereo, interleaved/non-interleaved input.
- Duration/amplitude checks, changed-format rejection, empty-buffer behavior,
  and rejection of connection timeout before config send completes.
- macOS 26.5 SDK release build, existing persistent development signature.
- Hardware capture on the affected macOS 26.5.1 machine remains unverified.
