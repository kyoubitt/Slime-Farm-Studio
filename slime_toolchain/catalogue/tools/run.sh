#!/bin/bash
# Phase 5, one band: ./run.sh band_12_inf   (re-run to resume from the last DONE_THROUGH; touch STOP to prevent a start)
cd "$(dirname "$0")"
b=$1; [ -f STOP ] && { echo "STOP present"; exit 1; }
start=$(grep -o 'DONE_THROUGH [0-9]*' $b.log 2>/dev/null | tail -1 | cut -d' ' -f2); start=${start:-0}
../hs_plan.exe --heat-survey --heat-plan $b.plan --heat-seeds 16384 --heat-min 6.5 --rng-seed 0xCA7A1060 --heat-start $start --heat-out $b.csv >> $b.log 2>&1
