#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/vendor/whisper.cpp"
BUILD_DIR="$SOURCE_DIR/build"

if [[ ! -f "$SOURCE_DIR/CMakeLists.txt" ]]; then
  echo "whisper.cpp is missing. Run: git submodule update --init --recursive"
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is missing. Install it with: brew install cmake"
  exit 1
fi

cmake \
  -S "$SOURCE_DIR" \
  -B "$BUILD_DIR" \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.6

cmake --build "$BUILD_DIR" --config Release --parallel

echo "Built: $BUILD_DIR/bin/whisper-cli"
