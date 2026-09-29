#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/vendor/llama.cpp"
BUILD_DIR="$SOURCE_DIR/build"
[[ -f "$SOURCE_DIR/CMakeLists.txt" ]] || { echo 'Initialize vendor/llama.cpp first.'; exit 1; }
CMAKE_BIN="${CMAKE_BIN:-cmake}"
"$CMAKE_BIN" -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=OFF -DLLAMA_OPENSSL=OFF \
  -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.6
"$CMAKE_BIN" --build "$BUILD_DIR" --config Release --target llama-completion --parallel 4
echo "Built: $BUILD_DIR/bin/llama-completion"
