#!/bin/bash

# --- Check Arguments ---
if [ "$#" -ne 2 ]; then
    echo "Usage: ./mixed_bench.sh <duration> <obj_size>"
    exit 1
fi

DURATION=$1
OBJ_SIZE=$2
CONCURRENCY=64

case $DURATION in
    *m) SECONDS_TOTAL=$((${DURATION%m} * 60)) ;;
    *s) SECONDS_TOTAL=${DURATION%s} ;;
    *)  SECONDS_TOTAL=$DURATION ;;
esac
SLEEP_MID=$((SECONDS_TOTAL / 2))

SAFE_SIZE=$(echo $OBJ_SIZE | tr '[:upper:]' '[:lower:]')
SCENARIO_NAME="mixed_${SAFE_SIZE}_dur_${DURATION}"
OUTPUT_DIR="$HOME/Desktop/gsoc_2026_benchmarks/$SCENARIO_NAME"
mkdir -p "$OUTPUT_DIR"

CEPH_BIN="./bin"
ASOK_PATH="out/radosgw.8000.asok"
ACCESS_KEY="..."
SECRET_KEY="..."

echo "--- Resetting Cluster ---"
../src/stop.sh > /dev/null 2>&1
rm -rf out/* dev/*
export CEPH_HEAP_PROFILER_INIT=true
MON=1 OSD=1 MDS=0 MGR=0 RGW=1 ../src/vstart.sh -n -d > "$OUTPUT_DIR/vstart_log.txt" 2>&1
sleep 20 

echo "--- Pre-loading Objects ---"
# Warp needs an existing pool of objects to perform GETs and DELETEs
./warp put --host=localhost:8000 --access-key="$ACCESS_KEY" --secret-key="$SECRET_KEY" \
           --obj.size="$OBJ_SIZE" --objects=2500 --noprefix --bucket="mixed-bench" > /dev/null 2>&1

echo "--- Starting Mixed Benchmark (Corrected Flags) ---"
$CEPH_BIN/ceph daemon "$ASOK_PATH" heap start_profiler
$CEPH_BIN/ceph daemon "$ASOK_PATH" heap dump
IDLE_DUMP=$(ls -t out/*.heap | head -1)
IDLE_BYTES=$($CEPH_BIN/ceph daemon "$ASOK_PATH" heap stats | grep "Bytes in use by application" | awk '{print $2}')

# Corrected flags: warp uses 'get-distrib' for reads
./warp mixed --host=localhost:8000 \
             --access-key="$ACCESS_KEY" \
             --secret-key="$SECRET_KEY" \
             --duration="$DURATION" \
             --obj.size="$OBJ_SIZE" \
             --concurrent=$CONCURRENCY \
             --get-distrib=50 --put-distrib=25 --delete-distrib=25 \
             --bucket="mixed-bench" > "$OUTPUT_DIR/warp_results.txt" 2>&1 &
WARP_PID=$!

PEAK_LOG="$OUTPUT_DIR/memory_timeline.txt"
( while kill -0 $WARP_PID 2>/dev/null; do
    $CEPH_BIN/ceph daemon "$ASOK_PATH" heap stats | grep "Bytes in use by application" | awk '{print $2}' >> "$PEAK_LOG"
    sleep 1
  done ) &
MONITOR_PID=$!

sleep $SLEEP_MID
$CEPH_BIN/ceph daemon "$ASOK_PATH" heap dump
STRESS_DUMP=$(ls -t out/*.heap | head -1)

wait $WARP_PID
kill $MONITOR_PID 2>/dev/null

# Analysis
google-pprof --text --base="$IDLE_DUMP" "$CEPH_BIN/radosgw" "$STRESS_DUMP" > "$OUTPUT_DIR/pprof_report.txt"
google-pprof --pdf --base="$IDLE_DUMP" "$CEPH_BIN/radosgw" "$STRESS_DUMP" > "$OUTPUT_DIR/callgraph.pdf" 2>/dev/null

PEAK_BYTES=$(sort -n "$PEAK_LOG" 2>/dev/null | tail -1)
PEAK_MB=$(echo "scale=2; $PEAK_BYTES / 1048576" | bc)
echo "PEAK MEMORY: $PEAK_MB MB" >> "$OUTPUT_DIR/warp_results.txt"
