# Voxtype on Windows — documented manual path.
#
# Upstream peteonrails/voxtype is Linux-native (Wayland + evdev) and does
# not ship a Windows binary. Trying to build from source on Windows is a
# non-goal for the upstream project. This script exists so users who run
# install_voxtype_windows.ps1 by reflex get a clear answer instead of
# silence.
#
# If you really want voxtype on Windows, file an upstream issue and link
# to the relevant Wayland/evdev abstraction work. Do not patch slopcode-
# infra to pretend a Windows build exists.

$msg = @'
voxtype is Linux-only upstream.

  - Source:  https://github.com/peteonrails/voxtype
  - Reason:  Wayland + evdev keyboard hooks; Windows support is a
             non-goal upstream (see voxtype/CLAUDE.md "Non-Goals").

If you need local push-to-talk dictation on Windows pointed at the
slopcode-infra whisper-server, options that work today:

  1. WSL2: install Ubuntu and run
       scripts/install_voxtype_linux.sh
     inside the WSL distro. Hotkeys reach the Linux daemon via the
     WSL keyboard pipe; output goes to the WSL terminal or via
     wl-clipboard if you bridge it.
  2. PowerToys "Voice Typing" or Win+H pointed at a custom STT
     endpoint (third-party tools required; native Win+H talks only
     to Microsoft).
  3. SuperWhisper, Wispr Flow, or any Windows dictation app that
     accepts a custom OpenAI-compatible transcription URL pointed at
     http://127.0.0.1:8427/v1/audio/transcriptions (with the slopcode-
     infra whisper-server reachable from Windows; if Windows hosts the
     llama / whisper stack already, the URL is loopback).

The slopcode-infra Windows install path for the LLM stack runs through
a checkout of this repo on the target host:

  scripts/setup_llamacpp.sh
  python3 scripts/llamacpp_models.py prefetch
  scripts/server_start_llamacpp.sh

There is currently no Windows-native voxtype client until upstream
gains Windows support.
'@

Write-Output $msg
