#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}/.."
BUILD="${TMPDIR:-/tmp}/lyrics-provider-runtime-safety"
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
 "$ROOT/SpotifyLyrics/Settings/TranslationCLISetupStore.swift" \
 "$ROOT/Tests/translation_cli_runtime_safety_contract.swift" -o "$BUILD/contract"
"$BUILD/contract"
