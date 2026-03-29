#!/bin/bash

# --- Check Arguments ---
if [ "$#" -ne 2 ]; then
    echo "Usage: ./read_bench.sh <duration> <obj_size>"
    echo "Example: ./read_bench.sh 1m 4KB"
    exit 1
fi

DURATION=$1
OBJ_SIZE=$2
CONCURRENCY=64

# --- Helper: Convert duration to seconds ---
case $DURATION in
    *m) SECONDS_TOTAL=$((${DURATION%m} * 60)) ;;
    *s) SECONDS_TOTAL=${DURATION%s} ;;
    *)  SECONDS_TOTAL=$DURATION ;;
esac
SLEEP_MID=$((SECONDS_TOTAL / 2))

# --- Directory Setup ---
SAFE_SIZE=$(echo $OBJ_SIZE | tr '[:upper:]' '[:lower:]')
SCENARIO_NAME="read_${SAFE_SIZE}_dur_${DURATION}"
OUTPUT_DIR="$HOME/Desktop/gsoc_2026_benchmarks/$SCENARIO_NAME"
mkdir -p "$OUTPUT_DIR"

# Ceph & Warp Config
CEPH_BIN="./bin"
ASOK_PATH="out/radosgw.8000.asok"
ACCESS_KEY="..."
SECRET_KEY="..."

echo "=========================================="
echo " SCENARIO: Read-Only | Size: $OBJ_SIZE | Duration: $DURATION"
echo "=========================================="

# 1. Reset Environment
echo "[1/7] Resetting Ceph (MGR=0)..."
../src/stop.sh > /dev/null 2>&1
rm -rf out/* dev/*
export CEPH_HEAP_PROFILER_INIT=true

# 2. Launch Cluster
MON=1 OSD=1 MDS=0 MGR=0 RGW=1 ../src/vstart.sh -n -d > "$OUTPUT_DIR/vstart_log.txt" 2>&1
echo "Waiting 20s for cluster stabilization..."
sleep 20 

# 3. Pre-load Phase (Mandatory for Read tests)
echo "[3/7] Pre-loading 1500 objects to read..."
./warp put --host=localhost:8000 --access-key="$ACCESS_KEY" --secret-key="$SECRET_KEY" \
           --obj.size="$OBJ_SIZE" --objects=1500 --noprefix --bucket="read-bench" > /dev/null 2>&1

# 4. Initialize Profiler & Idle Baseline
echo "[4/7] Capturing Idle Baseline..."
$CEPH_BIN/ceph daemon "$ASOK_PATH" heap start_profiler
$CEPH_BIN/ceph daemon "$ASOK_PATH" heap dump
IDLE_DUMP=$(ls -t out/*.heap | head -1)
IDLE_BYTES=$($CEPH_BIN/ceph daemon "$ASOK_PATH" heap stats | grep "Bytes in use by application" | awk '{print $2}')

# 5. Launch Warp GET & Peak Monitor
echo "[5/7] Hammering RGW with Warp GET..."
./warp get --host=localhost:8000 \
           --access-key="$ACCESS_KEY" \
           --secret-key="$SECRET_KEY" \
           --duration="$DURATION" \
           --obj.size="$OBJ_SIZE" \
           --concurrent=$CONCURRENCY \
           --bucket="read-bench" > "$OUTPUT_DIR/warp_results.txt" 2>&1 &
WARP_PID=$!

# Background Monitoring
PEAK_LOG="$OUTPUT_DIR/memory_timeline.txt"
( while kill -0 $WARP_PID 2>/dev/null; do
    $CEPH_BIN/ceph daemon "$ASOK_PATH" heap stats | grep "Bytes in use by application" | awk '{print $2}' >> "$PEAK_LOG"
    sleep 1
  done ) &
MONITOR_PID=$!

# 6. Mid-Point Stress Snapshot
echo "[6/7] Stress snapshot scheduled for ${SLEEP_MID}s mark..."
sleep $SLEEP_MID
$CEPH_BIN/ceph daemon "$ASOK_PATH" heap dump
STRESS_DUMP=$(ls -t out/*.heap | head -1)

# Wait for Warp
wait $WARP_PID
kill $MONITOR_PID 2>/dev/null

# 7. Analysis
echo "[7/7] Finalizing Analysis..."
google-pprof --text --base="$IDLE_DUMP" "$CEPH_BIN/radosgw" "$STRESS_DUMP" > "$OUTPUT_DIR/pprof_report.txt"
google-pprof --pdf --base="$IDLE_DUMP" "$CEPH_BIN/radosgw" "$STRESS_DUMP" > "$OUTPUT_DIR/callgraph.pdf" 2>/dev/null

# Calculate Peak
PEAK_BYTES=$(sort -n "$PEAK_LOG" 2>/dev/null | tail -1)
if [ -z "$PEAK_BYTES" ]; then PEAK_BYTES=$IDLE_BYTES; fi
PEAK_MB=$(echo "scale=2; $PEAK_BYTES / 1048576" | bc)

echo -e "\nPEAK MEMORY: $PEAK_MB MB" >> "$OUTPUT_DIR/warp_results.txt"
echo "SUCCESS. Results in: $OUTPUT_DIR"
