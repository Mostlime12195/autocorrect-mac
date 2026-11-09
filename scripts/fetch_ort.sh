#!/bin/bash
# onnxruntime (official macOS arm64 build, C API) -> vendor/onnxruntime/{include,lib}
set -euo pipefail
V="${ORT_VERSION:-1.31.1}"
cd "$(dirname "$0")/.."
[ -f vendor/onnxruntime/lib/libonnxruntime.$V.dylib ] && { echo "onnxruntime $V present"; exit 0; }
rm -rf vendor/onnxruntime && mkdir -p vendor
curl -fsSL "https://github.com/microsoft/onnxruntime/releases/download/v$V/onnxruntime-osx-arm64-$V.tgz" -o vendor/ort.tgz
tar xzf vendor/ort.tgz -C vendor
mv "vendor/onnxruntime-osx-arm64-$V" vendor/onnxruntime
rm -rf vendor/ort.tgz vendor/onnxruntime/lib/*.dSYM
echo "onnxruntime $V -> vendor/onnxruntime"
