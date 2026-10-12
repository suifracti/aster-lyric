#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUN_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

run_contract() {
  local label="$1"
  shift
  RUN_COUNT=$((RUN_COUNT + 1))
  printf '\n=== RUN %02d: %s ===\n' "$RUN_COUNT" "$label"
  if "$@"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '=== PASS: %s ===\n' "$label"
  else
    local result=$?
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '=== FAIL: %s (exit %s) ===\n' "$label" "$result"
  fi
}

# C1: production clock/subscriber, raw-domain seek conversion, and preview identity.
run_contract "B0 clock + paused update routing" bash Tests/b0_clock_offset_truth_contract.sh
run_contract "C1 offset direction and subscriber semantics" bash Tests/c1_offset_semantics_contract.sh
run_contract "C1 V3 seek draft / Fullscreen route" python3 Tests/v3_seek_draft_contract.py
run_contract "C1 raw pointer-to-seek mapping" python3 Tests/v3_seek_pointer_contract.py
run_contract "C1 preview identity guard" python3 Tests/c1_preview_seek_contract.py

# A0/H1/T1/T2/S1/O1/R1: isolated production source, persistence, projection, and session contracts.
run_contract "A0 source / track / generation containment" bash Tests/a0_capture_source_containment_contract.sh
run_contract "H1 canonical source hash boundary" bash Tests/h1_hash_domain_boundary_contract.sh
run_contract "T1 read projection fidelity" bash Tests/t1_read_projection_fidelity_contract.sh all
run_contract "T2 editor + library timing persistence" bash Tests/t2_lossless_editing_timing_contract.sh all
run_contract "S1 durable manual adoption" bash Tests/s1_durable_manual_adoption_contract.sh all
run_contract "O1 scoped offset persistence and editor identity" bash Tests/o1_scoped_lyrics_offset_contract.sh
run_contract "R1 reading/token consistency" bash Tests/r1_reading_token_consistency_contract.sh all
run_contract "R1 existing click-correction regression" bash Tests/ruby_correction_contract.sh

# U1: honest actions/states, current experiment catalog, and saved layout recovery.
run_contract "U1 action and state projection" bash Tests/u1_honest_experimental_ui_contract.sh
run_contract "Experience Library catalog and route" bash Tests/experience_library_contract.sh
run_contract "Persisted presentation selection" bash Tests/presentation_selection_store_contract.sh
run_contract "Phase 3.3 product host / adapter / router" bash Tests/direction_d_phase_3_3_contracts.sh
run_contract "Direction D stale-track and product-state contract" bash Tests/direction_d_phase_3_4_correctness_contracts.sh
run_contract "Direction D saved-layout recovery" bash Tests/direction_d_phase_3_4_layout_recovery_contracts.sh
run_contract "Classic / V3 / D layout compatibility" bash Tests/main_window_layout_fusion_contract.sh

printf '\nAUTOMATED CONTRACT SUMMARY: run=%d pass=%d fail=%d\n' \
  "$RUN_COUNT" "$PASS_COUNT" "$FAIL_COUNT"
printf 'NOTICE: app UI smoke, external player/capture checks, and required human acceptance are not executed by this headless runner.\n'

if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi
exit 0
