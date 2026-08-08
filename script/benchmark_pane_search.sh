#!/bin/zsh
set -euo pipefail

usage() {
  print "usage: $0 --output <aggregate-report.json> [--candidate] [--replace]" >&2
  exit 64
}

output=""
replace=0
candidate_requested=0
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
    --candidate)
      candidate_requested=1
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

baseline="docs/verification/2026-08-07-incremental-pane-search-baseline.json"
candidate_mode=0
if [[ "$candidate_requested" -eq 1 ]]; then
  candidate_mode=1
  [[ -f "$baseline" ]] || { print "missing committed baseline: $baseline" >&2; exit 66; }
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

# Capture repository and host state before any report is generated. The stage
# directory is outside the worktree, so this snapshot cannot include output.
provenance="$stage/provenance.json"
reports_dir="$stage/reports"
/bin/mkdir -p "$reports_dir"
head_commit="$(/usr/bin/git rev-parse HEAD)"
git_status_short="$(/usr/bin/git status --short)"
tracked_diff_sha256="$(/usr/bin/git diff --binary | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
xcode_version="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -version)"
swift_version="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift --version)"
macos_version="$(/usr/bin/sw_vers -productVersion)"
macos_build="$(/usr/bin/sw_vers -buildVersion)"
hardware_model="$(/usr/sbin/sysctl -n hw.model)"
hardware_arch="$(/usr/bin/uname -m)"
thermal_snapshot="$(/usr/bin/pmset -g therm 2>&1 || true)"
power_snapshot="$(/usr/bin/pmset -g batt 2>&1 || true)"
captured_at_utc="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
/usr/bin/python3 -c '
import json, sys
output, head, status, diff_sha, xcode, swift, macos, build, model, arch, thermal, power, captured = sys.argv[1:]
payload = {
    "headCommit": head,
    "gitStatusShort": status,
    "trackedDiffSHA256": diff_sha,
    "xcodeVersion": xcode,
    "swiftVersion": swift,
    "macOS": {"version": macos, "build": build},
    "hardware": {"model": model, "architecture": arch},
    "thermalPowerSnapshot": {"thermal": thermal, "power": power},
    "fixture": {"identifier": "paneSearchFixture", "seed": "index-range-0..<10_000"},
    "capturedAtUTC": captured,
    "timingBoundary": "application-latency-v2",
    "visualPaintMeasured": False,
}
with open(output, "w", encoding="utf-8") as file:
    json.dump(payload, file, sort_keys=True)
' "$provenance" "$head_commit" "$git_status_short" "$tracked_diff_sha256" \
  "$xcode_version" "$swift_version" "$macos_version" "$macos_build" \
  "$hardware_model" "$hardware_arch" "$thermal_snapshot" "$power_snapshot" "$captured_at_utc"

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

if [[ "$candidate_mode" -eq 1 ]]; then
  lifecycle_stdout="$stage/lifecycle-proof.stdout"
  lifecycle_stderr="$stage/lifecycle-proof.stderr"
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun swift test -c release --disable-sandbox --no-parallel \
    --filter paneSearchLiveProjectorCancellationProofIsNonVacuousAndDrains \
    >"$lifecycle_stdout" 2>"$lifecycle_stderr"
  lifecycle_started_count="$(grep -c 'Test paneSearchLiveProjectorCancellationProofIsNonVacuousAndDrains() started.' "$lifecycle_stdout" || true)"
  if [[ "$lifecycle_started_count" != "1" ]] \
    || ! grep -q 'Test run with 1 test' "$lifecycle_stdout" \
    || ! grep -q 'Test run with 1 test.*passed' "$lifecycle_stdout"; then
    print "deterministic lifecycle proof did not run exactly one passing Swift Testing test" >&2
    exit 70
  fi
fi

env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test -c release --disable-sandbox --no-parallel \
  --filter paneSearchReleaseBenchmark >/dev/null

for scenario in "${scenarios[@]}"; do
  safe_name="${scenario//:/-}"
  report="$reports_dir/${safe_name}.json"
  stdout="$stage/${safe_name}.stdout"
  stderr="$stage/${safe_name}.stderr"
  print "benchmarking $scenario"
  env PENGRID_PANE_SEARCH_BENCHMARK=1 \
    PENGRID_PANE_SEARCH_CANDIDATE="$candidate_mode" \
    PENGRID_PANE_SEARCH_SCENARIO="$scenario" \
    PENGRID_PANE_SEARCH_REPORT="$report" \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/time -l /usr/bin/xcrun swift test -c release \
    --skip-build --disable-sandbox --no-parallel --filter paneSearchReleaseBenchmark \
    >"$stdout" 2>"$stderr"
  [[ -s "$report" ]] || { print "missing scenario report: $report" >&2; exit 70; }
done

merge_status=0
if /usr/bin/python3 -c '
import json, pathlib, sys
output, stage, baseline_path, candidate_mode, provenance_path = sys.argv[1:]
output = pathlib.Path(output)
stage = pathlib.Path(stage)
baseline_path = pathlib.Path(baseline_path)
provenance_path = pathlib.Path(provenance_path)
candidate_mode = candidate_mode == "1"
reports = []
for report_path in sorted(stage.glob("reports/*.json")):
    reports.append(json.loads(report_path.read_text()))
process_logs = {}
for stream_path in sorted(stage.glob("*.stdout")) + sorted(stage.glob("*.stderr")):
    process_logs[stream_path.name] = stream_path.read_text(errors="replace")
payload = {
    "schemaVersion": 2 if candidate_mode else 1,
    "runner": "script/benchmark_pane_search.sh",
    "releaseConfiguration": True,
    "scenarioCount": len(reports),
    "reports": reports,
    "processLogs": process_logs,
    "provenance": json.loads(provenance_path.read_text()),
}
if candidate_mode:
    # The runner executes this bounded real-LivePaneItemProjector test before
    # the matrix. A rapid sample may legitimately launch no superseded worker
    # on a fast machine, so its zero is not used as the cancellation proof.
    payload["candidateLifecycleProof"] = {
        "deterministicLiveProjectorCancellationTest": "paneSearchLiveProjectorCancellationProofIsNonVacuousAndDrains",
        "verified": "Test run with 1 test" in process_logs.get("lifecycle-proof.stdout", "") and "passed" in process_logs.get("lifecycle-proof.stdout", ""),
        "swiftTestingTestCount": 1,
        "stdoutLog": "lifecycle-proof.stdout",
        "stderrLog": "lifecycle-proof.stderr",
        "cancellationRequestedAfterTraversalBegan": True,
        "postCancellationVisitsMustBeGreaterThanZero": True,
        "postCancellationVisitsMaximum": 128,
        "workersMustDrainToZero": True,
        "rapidBurstMayHaveNoSupersededWorker": True,
    }

def statistics(values):
    ordered = sorted(values)
    if not ordered:
        raise ValueError("benchmark statistic has no samples")
    median_index = (len(ordered) - 1) // 2
    p95_index = max(0, int(__import__("math").ceil(len(ordered) * 0.95)) - 1)
    return {"median": ordered[median_index], "p95": ordered[p95_index], "maximum": ordered[-1]}

def product_end_to_end(sample):
    return float(sample["setterToAcceptanceSeconds"]) + float(sample["acceptanceToTableSeconds"])

def trace_end_to_end_by_sample_index(report):
    totals = {}
    for sample in report["rawSamples"]:
        index = sample["sampleIndex"]
        totals[index] = totals.get(index, 0.0) + product_end_to_end(sample)
    return [totals[index] for index in sorted(totals)]

def has_product_timing_components(sample):
    return all(field in sample for field in (
        "setterToAcceptanceSeconds", "acceptanceToTableSeconds",
    ))

def candidate_timing_integrity(report, tolerance=1e-9):
    samples = report.get("rawSamples", [])
    if not samples or not all(has_product_timing_components(sample) for sample in samples):
        return False, "missing component timing field"
    if any("endToEndSeconds" not in sample for sample in samples):
        return False, "missing stored end-to-end field"
    if any(abs(float(sample["endToEndSeconds"]) - product_end_to_end(sample)) > tolerance for sample in samples):
        return False, "stored sample end-to-end does not match component sum"
    derived_trace_totals = trace_end_to_end_by_sample_index(report)
    stored_trace_totals = report.get("traceEndToEndSeconds", [])
    if len(stored_trace_totals) != len(derived_trace_totals):
        return False, "stored trace total count does not match derived sample-index totals"
    if any(abs(float(stored) - derived) > tolerance for stored, derived in zip(stored_trace_totals, derived_trace_totals)):
        return False, "stored trace total does not match component-derived sample-index total"
    return True, None

def sample_cell(sample):
    return "|".join(str(sample.get(field, "")) for field in (
        "trace", "fromQuery", "toQuery", "sortKey", "sortDirection", "cardinality"
    ))

def transition_cells(report):
    result = {}
    for sample in report["rawSamples"]:
        result.setdefault(sample_cell(sample), []).append(sample)
    return result

def add_gate(gates, identifier, passed, **detail):
    gates.append({"id": identifier, "passed": bool(passed), **detail})

if candidate_mode:
    baseline_payload = json.loads(baseline_path.read_text())
    baseline_reports = {report["scenario"]: report for report in baseline_payload["reports"]}
    baseline_samples = [
        sample
        for report in baseline_payload["reports"]
        for sample in report.get("rawSamples", [])
    ]
    report_scenarios = [report["scenario"] for report in reports]
    candidate_reports = {report["scenario"]: report for report in reports}
    expected_scenarios = {
        "completeLoad", "firstQuery", "numeric", "english", "korean",
        "reverseDeletion", "replacement", "rapidBurst",
    }
    for key in ("name", "modifiedAt", "kind", "size"):
        for direction in ("ascending", "descending"):
            for cardinality in (10_000, 3_439, 299, 20, 1):
                expected_scenarios.add(f"sort:{key}:{direction}:{cardinality}")

    trace_contracts = {
        "completeLoad": [("<unloaded>", "", 10_000)],
        "firstQuery": [("", "report", 5_000)],
        "numeric": [("", "1", 3_439), ("1", "19", 299), ("19", "199", 20), ("199", "1999", 1)],
        "english": [("", "r", 8_750), ("r", "re", 7_500), ("re", "rep", 6_250), ("rep", "report", 5_000), ("report", "report-1999", 1)],
        "korean": [("", "보", 8_750), ("보", "보고", 7_500), ("보고", "보고서", 6_250), ("보고서", "보고서-1998", 1)],
        "reverseDeletion": [("", "1999", 1), ("1999", "199", 20), ("199", "19", 299), ("19", "1", 3_439), ("1", "", 10_000)],
        "replacement": [("", "report-1999", 1), ("report-1999", "보고서-1998", 1), ("보고서-1998", " \n report-1999 \t", 1)],
        "rapidBurst": [("", "report-19", 56)],
    }

    def expected_cells_for(scenario):
        if scenario in trace_contracts:
            return {
                "|".join((scenario, before, after, "name", "ascending", str(cardinality)))
                for before, after, cardinality in trace_contracts[scenario]
            }
        _, key, direction, cardinality = scenario.split(":")
        return {"|".join(("sortChange", "1" if cardinality == "3439" else "19" if cardinality == "299" else "199" if cardinality == "20" else "1999" if cardinality == "1" else "", "1" if cardinality == "3439" else "19" if cardinality == "299" else "199" if cardinality == "20" else "1999" if cardinality == "1" else "", key, direction, cardinality))}

    hard_gates = []
    baseline_components_present = bool(baseline_samples) and all(
        has_product_timing_components(sample) for sample in baseline_samples
    )
    add_gate(
        hard_gates,
        "baseline-component-timing",
        baseline_components_present,
        baselineSampleCount=len(baseline_samples),
        requiredFields=["setterToAcceptanceSeconds", "acceptanceToTableSeconds"],
        normalizedFromComponentIntervals=True,
    )
    timing_integrity = {
        report["scenario"]: candidate_timing_integrity(report)
        for report in reports
    }
    add_gate(
        hard_gates,
        "candidate-timing-integrity",
        all(result[0] for result in timing_integrity.values()),
        toleranceSeconds=1e-9,
        scenarioErrors={
            scenario: reason
            for scenario, (_, reason) in timing_integrity.items()
            if reason is not None
        },
    )
    add_gate(
        hard_gates,
        "duplicate-scenario-reports",
        len(report_scenarios) == len(set(report_scenarios)),
        reportCount=len(report_scenarios),
        uniqueScenarioCount=len(set(report_scenarios)),
    )
    add_gate(
        hard_gates,
        "matrix-integrity",
        len(report_scenarios) == len(set(report_scenarios))
        and set(candidate_reports) == expected_scenarios
        and all(report.get("warmupCount") == 3 for report in reports)
        and all(report.get("sampleCount") == 30 for report in reports)
        and all(len(report.get("traceEndToEndSeconds", [])) == 30 for report in reports),
        expectedScenarioCount=len(expected_scenarios),
        actualScenarioCount=len(report_scenarios),
    )

    for scenario in sorted(expected_scenarios):
        report = candidate_reports.get(scenario)
        if report is None:
            add_gate(hard_gates, f"raw-sample-contract:{scenario}", False, reason="missing scenario")
            continue
        cells = transition_cells(report)
        expected_cells = expected_cells_for(scenario)
        sample_count = report.get("sampleCount", 0)
        add_gate(
            hard_gates,
            f"raw-sample-contract:{scenario}",
            set(cells) == expected_cells
            and len(report.get("rawSamples", [])) == sample_count * len(expected_cells)
            and all(len(samples) == sample_count for samples in cells.values())
            and all(sample.get("expectedCount") == sample.get("cardinality") for sample in report.get("rawSamples", [])),
            expectedTransitionCells=sorted(expected_cells),
            actualTransitionCells=sorted(cells),
            expectedRawSampleCount=sample_count * len(expected_cells),
            actualRawSampleCount=len(report.get("rawSamples", [])),
        )

    for trace in ("numeric", "english", "korean"):
        report = candidate_reports.get(trace)
        if report is None:
            add_gate(hard_gates, f"ready-order:{trace}:missing", False)
            continue
        for cell, samples in transition_cells(report).items():
            ready = all(sample.get("matchingActiveOrderWasAccepted") is True for sample in samples)
            add_gate(
                hard_gates,
                f"ready-order:{cell}",
                ready,
                sampleCount=len(samples),
            )

    all_candidate_samples = [sample for report in reports for sample in report["rawSamples"]]
    add_gate(
        hard_gates,
        "oracle-identity-and-order",
        bool(all_candidate_samples)
        and all(sample.get("matchesFullOracle") is True for sample in all_candidate_samples),
        sampleCount=len(all_candidate_samples),
    )
    add_gate(
        hard_gates,
        "production-table-token-callback",
        bool(all_candidate_samples)
        and all(
            sample.get("tableAppliedForAcceptedToken")
            == (False if sample.get("projectionPath") == "accepted-projection-reuse" else True)
            for sample in all_candidate_samples
        ),
        sampleCount=len(all_candidate_samples),
    )
    rapid_report = candidate_reports.get("rapidBurst")
    rapid_samples = rapid_report.get("rawSamples", []) if rapid_report else []
    rapid_sample_count = rapid_report.get("sampleCount") if rapid_report else None
    add_gate(
        hard_gates,
        "stale-publication:rapid-burst-trace",
        rapid_sample_count == 30
        and len(rapid_samples) == rapid_sample_count
        and all(sample.get("stalePublicationCount") == 0 for sample in rapid_samples),
        maximumStalePublications=0,
        expectedRapidSampleCount=rapid_sample_count,
        actualRapidSampleCount=len(rapid_samples),
    )
    add_gate(
        hard_gates,
        "cooperative-cancellation-bound:rapid-burst",
        rapid_sample_count == 30
        and len(rapid_samples) == rapid_sample_count
        and all(0 <= sample.get("cancelledWorkerCandidateVisits", 129) <= 128 for sample in rapid_samples),
        maximumAdditionalCandidates=128,
    )
    lifecycle_proof = payload.get("candidateLifecycleProof", {})
    add_gate(
        hard_gates,
        "deterministic-live-projector-cancellation-proof",
        lifecycle_proof.get("deterministicLiveProjectorCancellationTest")
            == "paneSearchLiveProjectorCancellationProofIsNonVacuousAndDrains"
        and lifecycle_proof.get("verified") is True
        and lifecycle_proof.get("swiftTestingTestCount") == 1
        and lifecycle_proof.get("cancellationRequestedAfterTraversalBegan") is True
        and lifecycle_proof.get("postCancellationVisitsMustBeGreaterThanZero") is True
        and lifecycle_proof.get("postCancellationVisitsMaximum") == 128
        and lifecycle_proof.get("workersMustDrainToZero") is True
        and lifecycle_proof.get("rapidBurstMayHaveNoSupersededWorker") is True,
        rapidBurstZeroIsPermittedOnlyWithDeterministicProof=True,
    )

    query_scenarios = (
        "firstQuery", "numeric", "english", "korean", "reverseDeletion", "replacement", "rapidBurst",
    )
    for scenario in query_scenarios:
        report = candidate_reports.get(scenario)
        if report is None:
            add_gate(hard_gates, f"application-latency:{scenario}:missing", False)
            continue
        for cell, samples in transition_cells(report).items():
            timing = statistics([product_end_to_end(sample) for sample in samples])
            add_gate(
                hard_gates,
                f"application-latency:{cell}",
                timing["median"] <= 0.075 and timing["p95"] <= 0.100 and timing["maximum"] <= 0.200,
                p50Seconds=timing["median"],
                p95Seconds=timing["p95"],
                maximumSeconds=timing["maximum"],
                maximumP50Seconds=0.075,
                maximumP95Seconds=0.100,
                maximumSampleSeconds=0.200,
                sampleCount=len(samples),
            )

    complete_load = candidate_reports.get("completeLoad")
    if complete_load is None:
        add_gate(hard_gates, "application-latency:completeLoad:missing", False)
    else:
        for cell, samples in transition_cells(complete_load).items():
            timing = statistics([product_end_to_end(sample) for sample in samples])
            add_gate(
                hard_gates,
                f"application-latency:{cell}",
                timing["median"] <= 0.500 and timing["p95"] <= 0.750 and timing["maximum"] <= 1.000,
                p50Seconds=timing["median"],
                p95Seconds=timing["p95"],
                maximumSeconds=timing["maximum"],
                maximumP50Seconds=0.500,
                maximumP95Seconds=0.750,
                maximumSampleSeconds=1.000,
                sampleCount=len(samples),
            )

    candidate_peak = max(sample["peakResidentBytes"] for sample in all_candidate_samples)
    baseline_peak = max(
        sample["peakResidentBytes"]
        for report in baseline_payload["reports"]
        for sample in report["rawSamples"]
    )
    add_gate(
        hard_gates,
        "regression:peak-rss",
        candidate_peak <= baseline_peak * 1.10,
        candidatePeakResidentBytes=candidate_peak,
        baselinePeakResidentBytes=baseline_peak,
        regressionPercent=(candidate_peak / baseline_peak - 1) * 100,
    )

    matched_latency_scenarios = tuple(sorted(expected_scenarios))
    for scenario in matched_latency_scenarios:
        candidate = candidate_reports.get(scenario)
        baseline = baseline_reports.get(scenario)
        if candidate is None or baseline is None:
            add_gate(hard_gates, f"baseline-regression:{scenario}", False, reason="missing matched scenario")
            continue
        candidate_cells = transition_cells(candidate)
        baseline_cells = transition_cells(baseline)
        for cell in sorted(expected_cells_for(scenario)):
            candidate_samples = candidate_cells.get(cell, [])
            baseline_samples = baseline_cells.get(cell, [])
            if not candidate_samples or not baseline_samples:
                add_gate(hard_gates, f"baseline-regression:{cell}", False, reason="missing matched transition")
                continue
            candidate_timing = statistics([product_end_to_end(sample) for sample in candidate_samples])
            baseline_timing = statistics([product_end_to_end(sample) for sample in baseline_samples])
            add_gate(
                hard_gates,
                f"baseline-regression:{cell}",
                candidate_timing["median"] <= baseline_timing["median"] * 1.10
                and candidate_timing["p95"] <= baseline_timing["p95"] * 1.10,
                candidateP50Seconds=candidate_timing["median"],
                baselineP50Seconds=baseline_timing["median"],
                candidateP95Seconds=candidate_timing["p95"],
                baselineP95Seconds=baseline_timing["p95"],
                p50RegressionPercent=(candidate_timing["median"] / baseline_timing["median"] - 1) * 100,
                p95RegressionPercent=(candidate_timing["p95"] / baseline_timing["p95"] - 1) * 100,
            )

        if scenario.startswith("sort:"):
            cardinality = int(scenario.rsplit(":", 1)[1])
            samples = candidate["rawSamples"]
            if cardinality != 10_000:
                add_gate(
                    hard_gates,
                    f"sort-subset-path:{scenario}",
                    bool(samples) and all(sample.get("projectionPath") == "sorted-visible-subset" for sample in samples),
                    expectedProjectionPath="sorted-visible-subset",
                    actualProjectionPaths=sorted(set(sample.get("projectionPath") for sample in samples)),
                )
            for cell, cell_samples in transition_cells(candidate).items():
                timing = statistics([product_end_to_end(sample) for sample in cell_samples])
                if cardinality == 10_000:
                    maximums = (0.250, 0.300, 0.400)
                else:
                    maximums = (0.075, 0.100, 0.150)
                add_gate(
                    hard_gates,
                    f"application-latency:{cell}",
                    timing["median"] <= maximums[0] and timing["p95"] <= maximums[1] and timing["maximum"] <= maximums[2],
                    p50Seconds=timing["median"],
                    p95Seconds=timing["p95"],
                    maximumSeconds=timing["maximum"],
                    maximumP50Seconds=maximums[0],
                    maximumP95Seconds=maximums[1],
                    maximumSampleSeconds=maximums[2],
                    sampleCount=len(cell_samples),
                )

    aspirational = []
    for scenario in query_scenarios:
        candidate = candidate_reports.get(scenario)
        if candidate is None:
            aspirational.append({"id": f"application-latency-50ms:{scenario}:missing", "passed": False})
            continue
        for cell, samples in transition_cells(candidate).items():
            timing = statistics([product_end_to_end(sample) for sample in samples])
            aspirational.append({
                "id": f"application-latency-50ms:{cell}",
                "passed": timing["p95"] <= 0.050,
                "p95Seconds": timing["p95"],
                "stretchP95Seconds": 0.050,
                "sampleCount": len(samples),
            })
    for trace in ("numeric", "english", "korean"):
        candidate = candidate_reports.get(trace)
        baseline = baseline_reports.get(trace)
        if candidate is None or baseline is None:
            aspirational.append({"id": f"post-first-character:{trace}:missing", "passed": False})
            aspirational.append({"id": f"complete-trace:{trace}:missing", "passed": False})
            continue
        baseline_cells = transition_cells(baseline)
        for cell, samples in transition_cells(candidate).items():
            if samples[0]["fromQuery"] == "":
                continue
            baseline_samples = baseline_cells.get(cell)
            if not baseline_samples:
                aspirational.append({"id": f"post-first-character:{cell}", "passed": False, "reason": "missing baseline cell"})
                continue
            candidate_p95 = statistics([product_end_to_end(sample) for sample in samples])["p95"]
            baseline_p95 = statistics([product_end_to_end(sample) for sample in baseline_samples])["p95"]
            aspirational.append({
                "id": f"post-first-character:{cell}",
                "passed": candidate_p95 <= baseline_p95 * 0.70,
                "candidateP95Seconds": candidate_p95,
                "baselineP95Seconds": baseline_p95,
                "improvementPercent": (1 - candidate_p95 / baseline_p95) * 100,
            })
        candidate_p95 = statistics(trace_end_to_end_by_sample_index(candidate))["p95"]
        baseline_p95 = statistics(trace_end_to_end_by_sample_index(baseline))["p95"]
        aspirational.append({
            "id": f"complete-trace:{trace}",
            "passed": candidate_p95 <= baseline_p95 * 0.60,
            "candidateP95Seconds": candidate_p95,
            "baselineP95Seconds": baseline_p95,
            "improvementPercent": (1 - candidate_p95 / baseline_p95) * 100,
        })

    payload["candidateGateEvaluation"] = {
        "baseline": str(baseline_path),
        "baselineTimingNormalizedFromComponentIntervals": True,
        "timingBoundary": "application-latency-v2",
        "hardGates": hard_gates,
        "hardGatePassed": all(gate["passed"] for gate in hard_gates),
        "aspirationalTargets": aspirational,
    }
temporary = output.with_suffix(output.suffix + ".tmp")
temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
temporary.replace(output)
' "$output" "$stage" "$baseline" "$candidate_mode" "$provenance"; then
  :
else
  merge_status=$?
fi

if [[ "$candidate_mode" -eq 1 && "$merge_status" -eq 0 ]]; then
  if /usr/bin/python3 script/evaluate_pane_search_gates.py \
    --candidate "$output" --baseline "$baseline"; then
    :
  else
    merge_status=$?
  fi
fi

if [[ "$merge_status" -eq 0 ]]; then
  completed=1
  print "wrote $output"
else
  print "benchmark merge failed; staging preserved: $stage" >&2
fi
exit "$merge_status"
