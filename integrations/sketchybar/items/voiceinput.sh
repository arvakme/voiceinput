#!/bin/bash
# Right-position items are added from right to left. Source after CleanShot.
sketchybar --add event voiceinput_state com.zhijie.VoiceInput.stateChanged \
  --add item voiceinput right \
  --set voiceinput \
    icon= \
    icon.width=18 \
    icon.padding_left=4 \
    icon.padding_right=4 \
    icon.background.drawing=on \
    icon.background.image.scale=0.25 \
    label.drawing=off \
    padding_left=6 \
    padding_right=6 \
    updates=on \
    update_freq=5 \
    script="$PLUGIN_DIR/voiceinput.sh" \
  --subscribe voiceinput voiceinput_state mouse.clicked system_woke
