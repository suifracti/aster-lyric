#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}/.."
BUILD="${TMPDIR:-/tmp}/lyrics-provider-model-protocol"
mkdir -p "$BUILD"
swiftc -parse-as-library \
 "$ROOT/SpotifyLyrics/AI/AITranslationModels.swift" \
 "$ROOT/SpotifyLyrics/AI/AITranslationConfiguration.swift" \
 "$ROOT/SpotifyLyrics/AI/AITranslationKeychain.swift" \
 "$ROOT/SpotifyLyrics/AI/AITranslationPromptBuilder.swift" \
 "$ROOT/SpotifyLyrics/AI/AITranslationResponseParser.swift" \
 "$ROOT/SpotifyLyrics/AI/OpenAICompatibleClient.swift" \
 "$ROOT/SpotifyLyrics/AI/AITranslationService.swift" \
 "$ROOT/SpotifyLyrics/AI/MultiProviderTranslationServices.swift" \
 "$ROOT/Tests/provider_model_directory_protocol_contract.swift" -o "$BUILD/contract"
"$BUILD/contract"
