#!/bin/bash
# No transcript, credentials, or error text ever cross this status bridge.
set -u
export PATH="/opt/homebrew/bin:/usr/bin:/bin"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}"
source "$CONFIG_DIR/colors.sh"

status_file="${VOICEINPUT_STATUS_FILE:-$HOME/Library/Caches/VoiceInput/status.json}"
state=offline
if [[ -f "$status_file" ]]; then
  pid=$(/usr/bin/plutil -extract pid raw -o - "$status_file" 2>/dev/null) || pid=
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
    process=$(/bin/ps -p "$pid" -o comm= 2>/dev/null)
    case "$process" in
      */VoiceInput|VoiceInput)
        state=$(/usr/bin/plutil -extract state raw -o - "$status_file" 2>/dev/null) || state=offline
        ;;
    esac
  fi
fi

if [[ "${SENDER:-}" == mouse.clicked ]]; then
  # Preserve the active editor as the insertion target; never activate the app.
  # A pending review is resolved in VoiceInput, not discarded by another start.
  case "$state" in
    processing|reviewing|disabled) exit 0 ;;
    *) /usr/bin/open -g 'voiceinput://toggle'; exit $? ;;
  esac
fi

symbol=mic
color="$ICON_COLOR"
case "$state" in
  recording) symbol=stop; color=0xffef4444 ;;
  connecting|processing) symbol=hourglass; color="$BLUE" ;;
  reviewing) symbol=check; color="$GREEN" ;;
  error) symbol=warning; color="$RED" ;;
  disabled) symbol=mic-off; color="$GREY" ;;
  offline) color="$GREY" ;;
esac

cache="$HOME/Library/Caches/SketchyBar/voiceinput"
mkdir -p "$cache"
svg="$CONFIG_DIR/assets/voiceinput/$symbol.svg"
png="$cache/$symbol-$color.png"
if [[ ! -s "$png" || "$svg" -nt "$png" ]]; then
  hex="${color#0x}"
  # Render to a private temporary file, then atomically publish it.
  temporary=$(mktemp "$cache/icon.XXXXXX") || exit 1
  if sed "s/currentColor/#${hex:2}/g" "$svg" | rsvg-convert -w 72 -h 72 -o "$temporary"; then
    mv -f "$temporary" "$png"
  else
    rm -f "$temporary"
    exit 1
  fi
fi
sketchybar --set "${NAME:-voiceinput}" icon.background.image="$png" \
  icon.background.image.scale=0.25 label.drawing=off
