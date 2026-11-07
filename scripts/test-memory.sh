#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
frameworks="${KARI_LLAMA_MAC_FRAMEWORKS:-Native/Vendor/llama.xcframework/macos-arm64_x86_64}"
output="${TMPDIR:-/tmp}/kari-memory-native-tests"
xcrun swiftc -parse-as-library -module-cache-path /tmp/kari-memory-swift-cache \
  -F "$frameworks" -framework llama -Xlinker -rpath -Xlinker "$frameworks" \
  Native/Sources/KariNative/KariMotionPlan.swift Native/Sources/KariNative/KariMemoryTypes.swift Native/Sources/KariNative/KariMemoryStore.swift \
  Native/Sources/KariNative/KariEmbeddingService.swift Native/Sources/KariNative/KariLocalEmbedding.swift \
  Tests/memory/MemoryTests.swift -o "$output"
"$output" "$@"
