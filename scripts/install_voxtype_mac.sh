#!/usr/bin/env bash
# Voxtype on macOS — documented manual path.
#
# Upstream peteonrails/voxtype is Linux-native (Wayland-first) and does not
# ship a macOS binary. Trying to build from source on macOS is a non-goal
# for the upstream project (see voxtype/CLAUDE.md → "Non-Goals"). This
# script exists so users who run install_voxtype_mac.sh by reflex get a
# clear answer instead of silence.
#
# If you only need cloud STT on macOS, every Whisper-API client speaks the
# OpenAI /v1/audio/transcriptions endpoint that scripts/install_mac_
# launchagents.sh already bootstraps for whisper.cpp on :8427. Examples:
# the Apple Shortcuts "Dictate Text" action with a custom server URL,
# https://github.com/ggerganov/whisper.cpp/tree/master/examples/talk-llama,
# or any third-party Mac dictation app that lets you point at a custom
# Whisper API endpoint.
#
# If you really want voxtype on macOS, file an upstream issue and link to
# the relevant Wayland/evdev abstraction work. Do not patch slopcode-infra
# to pretend a Mac build exists.
set -euo pipefail

cat <<'EOF'
voxtype is Linux-only upstream.

  - Source:  https://github.com/peteonrails/voxtype
  - Reason:  Wayland + evdev keyboard hooks; macOS support is a
             non-goal upstream (see voxtype/CLAUDE.md "Non-Goals").

If you need local push-to-talk dictation on macOS, options that work
today against the slopcode-infra whisper-server agent on :8427:

  1. Apple Shortcuts → "Dictate Text" with a custom Whisper endpoint.
  2. https://github.com/ggerganov/whisper.cpp/tree/master/examples/stream
     for live transcription (no PTT, but no GUI either).
  3. Third-party Mac apps that accept a custom OpenAI-compatible
     transcription URL (e.g. SuperWhisper "Custom" mode) pointed at
     http://127.0.0.1:8427/v1/audio/transcriptions.

The slopcode-infra Mac launchd agent for whisper-server is installed by:

  scripts/install_mac_launchagents.sh

That covers the server side on Mac. The PTT client lives outside this
repo until upstream voxtype gains macOS support.
EOF
