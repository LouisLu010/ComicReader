#!/usr/bin/env bash

# 测试失败后尽力收集诊断信息：仍在运行的被测 App 调用栈采样、
# xcresult 摘要与自动截图、模拟器内 App 日志和崩溃报告。
# 全部步骤均为 best effort，任何一步失败都不影响退出码。

set -uo pipefail

readonly OUTPUT_DIR="${DIAGNOSTICS_DIR:-${RUNNER_TEMP:?RUNNER_TEMP is required}/ComicReaderTestDiagnostics}"
readonly COLLECT_LOG="$OUTPUT_DIR/collect.log"
readonly APP_PROCESS_NAME="${APP_PROCESS_NAME:-ComicReader}"

mkdir -p "$OUTPUT_DIR"
echo "Collecting diagnostics into $OUTPUT_DIR" | tee -a "$COLLECT_LOG"

# 1. 被测 App 若仍在运行（例如主线程卡死导致查询超时），先采样调用栈。
for pid in $(pgrep -x "$APP_PROCESS_NAME" || true); do
  sample_file="$OUTPUT_DIR/$APP_PROCESS_NAME-$pid-sample.txt"
  if ! sample "$pid" 5 -file "$sample_file" >>"$COLLECT_LOG" 2>&1; then
    sudo sample "$pid" 5 -file "$sample_file" >>"$COLLECT_LOG" 2>&1 \
      || echo "sample failed for pid $pid" >>"$COLLECT_LOG"
  fi
done

# 2. xcresult：测试摘要、逐用例结果与附件（含失败时的自动截图）。
shopt -s nullglob
for bundle in "${RUNNER_TEMP}"/*.xcresult; do
  name="$(basename "${bundle%.xcresult}")"
  xcrun xcresulttool get test-results summary --path "$bundle" \
    >"$OUTPUT_DIR/$name-summary.json" 2>>"$COLLECT_LOG" || true
  xcrun xcresulttool get test-results tests --path "$bundle" \
    >"$OUTPUT_DIR/$name-tests.json" 2>>"$COLLECT_LOG" || true
  xcrun xcresulttool export attachments --path "$bundle" \
    --output-path "$OUTPUT_DIR/$name-attachments" >>"$COLLECT_LOG" 2>&1 || true
done

# 3. 模拟器内 App 日志（仅被测进程）与宿主机上的崩溃报告。
xcrun simctl spawn booted log show --last 30m --style compact \
  --predicate "process == \"$APP_PROCESS_NAME\"" \
  >"$OUTPUT_DIR/simulator-app.log" 2>>"$COLLECT_LOG" || true

for report in "$HOME"/Library/Logs/DiagnosticReports/"$APP_PROCESS_NAME"*; do
  mkdir -p "$OUTPUT_DIR/crash-reports"
  cp "$report" "$OUTPUT_DIR/crash-reports/" 2>>"$COLLECT_LOG" || true
done

find "$OUTPUT_DIR" -type f | sed "s#^$OUTPUT_DIR/##" | tee -a "$COLLECT_LOG"
exit 0
