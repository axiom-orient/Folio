#!/usr/bin/env python3
"""Check the v2 128 MiB total-process physical-footprint gate.
Preserve the independent legacy peak-RSS verdict; never convert it to PASS.
Input: FOLIO_SEMANTIC_MEMORY_TRACE=1 JSONL, one fresh process per file.
"""
import argparse, json, pathlib

BUDGET = 128 * 1024 * 1024
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('traces', type=pathlib.Path, nargs='+')
args = parser.parse_args()
reports = []
for path in args.traces:
    records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    phases = {r['phase'] for r in records}
    if not {'e5.model.loaded', 'relevance.model.loaded', 'e5.resources.released', 'relevance.resources.released'} <= phases:
        raise SystemExit(f'Incomplete two-model lifecycle trace: {path}')
    for r in records:
        if not all(isinstance(r.get(k), int) and r[k] > 0 for k in ['peakRSS', 'peakFootprint', 'rss', 'footprint']):
            raise SystemExit(f'Missing or invalid kernel measurement: {path}')
        if r['peakFootprint'] < r['footprint']:
            raise SystemExit(f'Inconsistent physical high-water mark: {path}')
    footprint = max(r['peakFootprint'] for r in records)
    rss = max(r['peakRSS'] for r in records)
    reports.append({'trace': path.name, 'budgetBytes': BUDGET, 'peakPhysicalFootprintBytes': footprint,
                    'peakResidentBytes': rss, 'physicalFootprint128': 'PASS' if footprint <= BUDGET else 'FAIL',
                    'legacyResident128': 'PASS' if rss <= BUDGET else 'FAIL'})
print(json.dumps({'schema': 'folio.semantic-memory-gates/2', 'runs': reports}, indent=2))
raise SystemExit(0 if all(r['physicalFootprint128'] == 'PASS' for r in reports) else 1)
