#!/usr/bin/env python3
"""Replay Pengrid pane-search gates from immutable raw component timings."""

import argparse
import copy
import datetime as dt
import hashlib
import json
import math
import os
import pathlib
import tempfile

POLICY_ID = "pane-search-application-latency-v3"
EVALUATOR_REVISION = "1"
TIMING_BOUNDARY = "application-latency-v2"
TOLERANCE = 1e-9
QUERY_SCENARIOS = {
    "firstQuery", "numeric", "english", "korean", "reverseDeletion", "replacement", "rapidBurst",
}


def canonical_scenarios():
    scenarios = {"completeLoad", *QUERY_SCENARIOS}
    for key in ("name", "modifiedAt", "kind", "size"):
        for direction in ("ascending", "descending"):
            for cardinality in (10_000, 3_439, 299, 20, 1):
                scenarios.add(f"sort:{key}:{direction}:{cardinality}")
    return scenarios


def compact_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def evaluator_sha256():
    return sha256_bytes(pathlib.Path(__file__).read_bytes())


def source_artifact_sha256(candidate):
    source = copy.deepcopy(candidate)
    source.pop("gateEvaluations", None)
    return sha256_bytes(compact_json(source))


def product_end_to_end(sample):
    return float(sample["setterToAcceptanceSeconds"]) + float(sample["acceptanceToTableSeconds"])


def statistics(values):
    ordered = sorted(values)
    if not ordered:
        raise ValueError("empty timing sample")
    return {
        "median": ordered[(len(ordered) - 1) // 2],
        "p95": ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)],
        "maximum": ordered[-1],
    }


def cell(sample):
    return "|".join(str(sample.get(field, "")) for field in (
        "trace", "fromQuery", "toQuery", "sortKey", "sortDirection", "cardinality",
    ))


def cells(report):
    result = {}
    for sample in report.get("rawSamples", []):
        result.setdefault(cell(sample), []).append(sample)
    return result


def gate(gates, identifier, passed, **detail):
    gates.append({"id": identifier, "passed": bool(passed), **detail})


def validate_report_contract(report, baseline_report):
    samples = report.get("rawSamples", [])
    sample_count = report.get("sampleCount")
    actual_cells = cells(report)
    baseline_cells = cells(baseline_report)
    indexes = sorted({sample.get("sampleIndex") for sample in samples})
    return (
        isinstance(sample_count, int)
        and sample_count > 0
        and set(actual_cells) == set(baseline_cells)
        and all(len(group) == sample_count for group in actual_cells.values())
        and indexes == list(range(sample_count))
        and all(sample.get("expectedCount") == sample.get("cardinality") for sample in samples)
    )


def timing_integrity(report):
    samples = report.get("rawSamples", [])
    if not samples:
        return False
    if any(not {"setterToAcceptanceSeconds", "acceptanceToTableSeconds", "endToEndSeconds"} <= set(sample) for sample in samples):
        return False
    if any(abs(float(sample["endToEndSeconds"]) - product_end_to_end(sample)) > TOLERANCE for sample in samples):
        return False
    totals = {}
    for sample in samples:
        index = sample["sampleIndex"]
        totals[index] = totals.get(index, 0.0) + product_end_to_end(sample)
    stored = report.get("traceEndToEndSeconds", [])
    return len(stored) == len(totals) and all(
        abs(float(actual) - totals[index]) <= TOLERANCE
        for index, actual in enumerate(stored)
    )


def evaluate(candidate, baseline):
    gates = []
    expected = canonical_scenarios()
    candidate_reports = {report.get("scenario"): report for report in candidate.get("reports", [])}
    baseline_reports = {report.get("scenario"): report for report in baseline.get("reports", [])}
    gate(gates, "schema-and-scenario-contract",
         candidate.get("schemaVersion") == 2 and baseline.get("schemaVersion") == 1
         and candidate.get("scenarioCount") == len(expected)
         and set(candidate_reports) == expected and set(baseline_reports) == expected,
         expectedScenarioCount=len(expected), actualScenarioCount=len(candidate_reports))
    for scenario in sorted(expected):
        report = candidate_reports.get(scenario)
        baseline_report = baseline_reports.get(scenario)
        gate(gates, f"raw-sample-contract:{scenario}",
             report is not None and baseline_report is not None and validate_report_contract(report, baseline_report))
        gate(gates, f"timing-integrity:{scenario}", report is not None and timing_integrity(report))

    samples = [sample for report in candidate_reports.values() for sample in report.get("rawSamples", [])]
    baseline_samples = [sample for report in baseline_reports.values() for sample in report.get("rawSamples", [])]
    gate(gates, "baseline-component-timing", bool(baseline_samples) and all(
        {"setterToAcceptanceSeconds", "acceptanceToTableSeconds"} <= set(sample) for sample in baseline_samples))
    gate(gates, "oracle-identity-and-order", bool(samples) and all(sample.get("matchesFullOracle") is True for sample in samples))
    gate(gates, "production-table-token-callback", bool(samples) and all(
        sample.get("tableAppliedForAcceptedToken") == (False if sample.get("projectionPath") == "accepted-projection-reuse" else True)
        for sample in samples))
    rapid = candidate_reports.get("rapidBurst", {})
    rapid_samples = rapid.get("rawSamples", [])
    gate(gates, "stale-publication:rapid-burst-trace", len(rapid_samples) == rapid.get("sampleCount") and all(
        sample.get("stalePublicationCount") == 0 for sample in rapid_samples))
    gate(gates, "cooperative-cancellation-bound:rapid-burst", len(rapid_samples) == rapid.get("sampleCount") and all(
        0 <= sample.get("cancelledWorkerCandidateVisits", 129) <= 128 for sample in rapid_samples))
    proof = candidate.get("candidateLifecycleProof", {})
    gate(gates, "deterministic-live-projector-cancellation-proof",
         proof.get("verified") is True and proof.get("postCancellationVisitsMustBeGreaterThanZero") is True
         and proof.get("postCancellationVisitsMaximum") == 128 and proof.get("workersMustDrainToZero") is True)
    for scenario in ("numeric", "english", "korean"):
        gate(gates, f"ready-order:{scenario}", all(
            sample.get("matchingActiveOrderWasAccepted") is True
            for sample in candidate_reports[scenario].get("rawSamples", [])))
    for scenario, report in candidate_reports.items():
        if scenario.startswith("sort:") and int(scenario.rsplit(":", 1)[1]) != 10_000:
            gate(gates, f"sort-subset-path:{scenario}", all(
                sample.get("projectionPath") == "sorted-visible-subset" for sample in report.get("rawSamples", [])))
    candidate_peak = max(sample.get("peakResidentBytes", 0) for sample in samples)
    baseline_peak = max(sample.get("peakResidentBytes", 0) for sample in baseline_samples)
    gate(gates, "regression:peak-rss", baseline_peak > 0 and candidate_peak <= baseline_peak * 1.10,
         candidatePeakResidentBytes=candidate_peak, baselinePeakResidentBytes=baseline_peak)

    advisories = []
    stretch = []
    for scenario in sorted(expected):
        candidate_cells = cells(candidate_reports[scenario])
        baseline_cells = cells(baseline_reports[scenario])
        for identifier, candidate_group in candidate_cells.items():
            baseline_group = baseline_cells[identifier]
            candidate_timing = statistics([product_end_to_end(sample) for sample in candidate_group])
            baseline_timing = statistics([product_end_to_end(sample) for sample in baseline_group])
            if scenario == "completeLoad":
                limits = (0.500, 0.750, 1.000)
            elif scenario.startswith("sort:"):
                cardinality = int(scenario.rsplit(":", 1)[1])
                limits = (0.250, 0.300, 0.400) if cardinality == 10_000 else (0.080, 0.100, 0.150)
                if cardinality <= 3_439:
                    stretch.append({"id": f"sort-p50-75ms:{identifier}", "passed": candidate_timing["median"] <= 0.075,
                                    "p50Seconds": candidate_timing["median"], "stretchP50Seconds": 0.075})
            else:
                limits = (0.075, 0.100, 0.200)
            gate(gates, f"application-latency:{identifier}",
                 candidate_timing["median"] <= limits[0] and candidate_timing["p95"] <= limits[1] and candidate_timing["maximum"] <= limits[2],
                 p50Seconds=candidate_timing["median"], p95Seconds=candidate_timing["p95"], maximumSeconds=candidate_timing["maximum"],
                 maximumP50Seconds=limits[0], maximumP95Seconds=limits[1], maximumSampleSeconds=limits[2])
            baseline_p50 = baseline_timing["median"]
            floor = max(0.10 * baseline_p50, 0.005)
            gate(gates, f"baseline-regression-p50:{identifier}", candidate_timing["median"] <= baseline_p50 + floor,
                 candidateP50Seconds=candidate_timing["median"], baselineP50Seconds=baseline_p50, allowedIncreaseSeconds=floor)
            baseline_p95 = baseline_timing["p95"]
            p95_floor = max(0.10 * baseline_p95, 0.005)
            if candidate_timing["p95"] > baseline_p95 + p95_floor:
                advisories.append({"id": f"baseline-regression-p95:{identifier}", "alert": True,
                                   "candidateP95Seconds": candidate_timing["p95"], "baselineP95Seconds": baseline_p95, "allowedIncreaseSeconds": p95_floor})
    non_latency = [item for item in gates if not item["id"].startswith(("application-latency:", "baseline-regression-p50:", "timing-integrity:"))]
    return gates, advisories, stretch, {"passed": all(item["passed"] for item in non_latency), "gateIDs": [item["id"] for item in non_latency]}


def replay(candidate_path, baseline_path):
    candidate_path, baseline_path = pathlib.Path(candidate_path), pathlib.Path(baseline_path)
    candidate = json.loads(candidate_path.read_text())
    baseline = json.loads(baseline_path.read_text())
    source_sha = source_artifact_sha256(candidate)
    gates, advisories, stretch, non_latency = evaluate(candidate, baseline)
    previous = next((item for item in candidate.get("gateEvaluations", []) if item.get("policy") == POLICY_ID and item.get("sourceArtifactSHA256") == source_sha and item.get("evaluatorSHA256") == evaluator_sha256()), None)
    evaluated_at = previous.get("evaluatedAtUTC") if previous else dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    entry = {"policy": POLICY_ID, "evaluatorRevision": EVALUATOR_REVISION, "evaluatorSHA256": evaluator_sha256(),
             "sourceArtifactSHA256": source_sha, "evaluatedAtUTC": evaluated_at, "timingBoundary": TIMING_BOUNDARY,
             "hardGates": gates, "hardGatePassed": all(item["passed"] for item in gates),
             "relativeP95Advisories": advisories, "stretchTargets": stretch,
             "preexistingNonLatencyHardGates": non_latency}
    candidate["gateEvaluations"] = [item for item in candidate.get("gateEvaluations", []) if item.get("policy") != POLICY_ID] + [entry]
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=candidate_path.parent, delete=False) as temporary:
        json.dump(candidate, temporary, indent=2, sort_keys=True)
        temporary.write("\n")
        temporary_path = temporary.name
    os.replace(temporary_path, candidate_path)
    return entry


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--baseline", required=True)
    arguments = parser.parse_args()
    result = replay(arguments.candidate, arguments.baseline)
    print(json.dumps({"policy": POLICY_ID, "hardGatePassed": result["hardGatePassed"], "advisoryCount": len(result["relativeP95Advisories"]), "stretchCount": len(result["stretchTargets"])}, sort_keys=True))
    return 0 if result["hardGatePassed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
