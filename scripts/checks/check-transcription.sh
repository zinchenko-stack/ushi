#!/bin/bash
# Local end-to-end smoke test: uses the bundled public JFK sample, no downloads.
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD/build/transcription-check"
binary="$PWD/build/DerivedData/Build/Products/Debug/UshiNext.app/Contents/Resources/whisper-cli"
[[ -x "$binary" ]] || { echo 'Build UshiNext first.'; exit 1; }
[[ -f "$HOME/.ushi/models/ggml-large-v3-turbo.bin" && -f "$HOME/.ushi/models/ggml-silero-v5.1.2.bin" ]] || { echo 'Install both speech models through the app first.'; exit 1; }
mkdir -p "$root/Smoke.app/Contents/MacOS" "$root/Smoke.app/Contents/Resources" "$root/audio"
ln -sf "$binary" "$root/Smoke.app/Contents/Resources/whisper-cli"
cp vendor/whisper.cpp/samples/jfk.mp3 "$root/audio/sample.mp3"
afconvert "$root/audio/sample.mp3" "$root/audio/sample.wav" -f WAVE -d LEI16@16000 -c 1
afconvert "$root/audio/sample.mp3" "$root/audio/sample.m4a" -f m4af -d 'aac '
swiftc -parse-as-library ushi-next/TranscriptionService.swift ushi-next/AutoTitle.swift scripts/checks/TranscriptionSmoke.swift -o "$root/Smoke.app/Contents/MacOS/Smoke"
"$root/Smoke.app/Contents/MacOS/Smoke" "$root/audio"
