# SketchyBar control

`open -g 'voiceinput://toggle'` starts dictation; calling it again while recording stops capture and continues the existing transcription/polish/review pipeline. `-g` keeps the focused editor as the insertion target.

VoiceInput publishes a small atomic snapshot at `~/Library/Caches/VoiceInput/status.json` and then posts the distributed notification `com.zhijie.VoiceInput.stateChanged`. A snapshot has exactly three fields: `version` (currently 1), `pid`, and `state`. It never includes a transcript, credentials, or error details.

States: `idle`, `connecting`, `recording`, `processing`, `reviewing`, `error`, `disabled`, `offline`. Final transcription, polish and insertion all map to `processing`. Normal exit writes `offline`; consumers should validate the PID and process name for crashes or stale snapshots.

A SketchyBar item subscribes with:

```sh
sketchybar --add event voiceinput_state com.zhijie.VoiceInput.stateChanged
sketchybar --subscribe voiceinput voiceinput_state mouse.clicked system_woke
```

The local configuration uses `~/.config/sketchybar/items/voiceinput.sh`, `plugins/voiceinput.sh`, and `assets/voiceinput/*.svg`. It is sourced after the CleanShot item, placing the microphone immediately to CleanShot's left because right-aligned items are added from right to left. The icon changes to a red stop square while recording, an hourglass during connection/processing, and a green check while reviewing. Error and disabled states have separate icons. Only state changes trigger notification-driven redraws; a five-second liveness check handles crashes. SVG icons are rendered once per color/state and cached.

The button ignores clicks during processing, review and disabled mode. Pending review remains in VoiceInput so another click cannot abandon text waiting for approval. Recording started through the hotkey uses the same state bridge. The current review preference is unchanged.

Validation: 85 Swift tests passed, including export-field privacy, state mapping, write-before-notify ordering, and shutdown behavior. A hidden SketchyBar item verified real distributed notifications for all six active UI states, stale-PID recovery, and the live layout position. No microphone recording was started by these tests. A signed release build passed. Restart VoiceInput after installing the bridge; SketchyBar can hotload its configuration independently.

## Install the bundled configuration

The tested item, plugin and SVG icons are included in [`integrations/sketchybar`](../integrations/sketchybar). They use the existing SketchyBar theme variables `ICON_COLOR`, `GREY`, `BLUE`, `GREEN`, and `RED` from `colors.sh`, and require `rsvg-convert` (Homebrew `librsvg`). From the VoiceInput repository:

```sh
mkdir -p "$HOME/.config/sketchybar/items" "$HOME/.config/sketchybar/plugins" "$HOME/.config/sketchybar/assets/voiceinput"
cp integrations/sketchybar/items/voiceinput.sh "$HOME/.config/sketchybar/items/"
cp integrations/sketchybar/plugins/voiceinput.sh "$HOME/.config/sketchybar/plugins/"
cp integrations/sketchybar/assets/voiceinput/*.svg "$HOME/.config/sketchybar/assets/voiceinput/"
chmod +x "$HOME/.config/sketchybar/plugins/voiceinput.sh"
```

In `sketchybarrc`, after the line that creates CleanShot (locally `source "$ITEM_DIR/status_apps.sh"`), add:

```sh
source "$ITEM_DIR/voiceinput.sh"
```

Restart VoiceInput once after installing a version with the status bridge, then reload SketchyBar if hotloading is disabled. The widget uses the existing URL scheme; it does not need separate API keys or audio permissions.
