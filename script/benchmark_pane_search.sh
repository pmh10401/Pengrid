#!/bin/zsh
set -euo pipefail

usage() {
  print "usage: $0 --output <aggregate-report.json> [--replace]" >&2
  exit 64
}

output=""
replace=0
while (( $# > 0 )); do
  case "$1" in
    --output)
      (( $# >= 2 )) || usage
      output="$2"
      shift 2
      ;;
    --replace)
      replace=1
      shift
      ;;
    *) usage ;;
  esac
done

[[ -n "$output" ]] || usage
output_parent="${output:h}"
[[ -d "$output_parent" ]] || { print "output parent does not exist: $output_parent" >&2; exit 66; }
[[ "$output" == *.json ]] || { print "aggregate output must be a .json file" >&2; exit 64; }
if [[ -e "$output" && "$replace" -ne 1 ]]; then
  print "refusing to overwrite existing report: $output (pass --replace)" >&2
  exit 73
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/pengrid-pane-search.XXXXXX")"
completed=0
cleanup() {
  if [[ "$completed" -eq 1 ]]; then
    rm -rf "$stage"
  else
    print "benchmark staging preserved after failure: $stage" >&2
  fi
}
trap cleanup EXIT

scenarios=(
  completeLoad firstQuery numeric english korean reverseDeletion replacement rapidBurst
)
for key in name modifiedAt kind size; do
  for direction in ascending descending; do
    for cardinality in 10000 3439 299 20 1; do
      scenarios+=("sort:${key}:${direction}:${cardinality}")
    done
  done
done

env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test -c release --disable-sandbox --no-parallel \
  --filter paneSearchReleaseBenchmark >/dev/null

for scenario in "${scenarios[@]}"; do
  safe_name="${scenario//:/-}"
  report="$stage/${safe_name}.json"
  stdout="$stage/${safe_name}.stdout"
  stderr="$stage/${safe_name}.stderr"
  print "benchmarking $scenario"
  env PENGRID_PANE_SEARCH_BENCHMARK=1 \
    PENGRID_PANE_SEARCH_SCENARIO="$scenario" \
    PENGRID_PANE_SEARCH_REPORT="$report" \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/time -l /usr/bin/xcrun swift test -c release \
    --skip-build --disable-sandbox --no-parallel --filter paneSearchReleaseBenchmark \
    >"$stdout" 2>"$stderr"
  [[ -s "$report" ]] || { print "missing scenario report: $report" >&2; exit 70; }
done

/usr/bin/python3 -c '
import json, pathlib, sys
output, stage = map(pathlib.Path, sys.argv[1:])
reports = []
for report_path in sorted(stage.glob("*.json")):
    reports.append(json.loads(report_path.read_text()))
process_logs = {}
for stream_path in sorted(stage.glob("*.stdout")) + sorted(stage.glob("*.stderr")):
    process_logs[stream_path.name] = stream_path.read_text(errors="replace")
payload = {
    "schemaVersion": 1,
    "runner": "script/benchmark_pane_search.sh",
    "releaseConfiguration": True,
    "scenarioCount": len(reports),
    "reports": reports,
    "processLogs": process_logs,
}
temporary = output.with_suffix(output.suffix + ".tmp")
temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
temporary.replace(output)
' "$output" "$stage"

completed=1
print "wrote $output"
