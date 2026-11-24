#!/usr/bin/env python3
"""Decode Hy-MT3 blind scores (opened only after all six batches validate) and summarize."""
import json
from pathlib import Path
import shutil
import statistics

import numpy as np
from sacrebleu.metrics import CHRF

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORK = ROOT / "dist/translation-screening"
REVIEW = WORK / "review-hymt3"
NAMES = ["apple", "yandex", "hy", "hymt3-1.8b", "hymt3-7b", "hymt3-30b"]


def stats(values):
    return {"n": len(values), "median_s": round(statistics.median(values), 3),
            "p95_s": round(float(np.percentile(values, 95)), 3), "max_s": round(max(values), 3)}


if __name__ == "__main__":
    corpus = json.loads((HERE / "corpus.json").read_text())
    cases = {x["id"]: x for x in corpus["cases"]}
    judgments = []
    for i in range(1, 7):
        batch = json.loads((HERE / "scores-hymt3" / f"batch-{i}.json").read_text())
        assert len(batch) == 10
        judgments.extend(batch)
    assert {x["id"] for x in judgments} == set(cases) and len(judgments) == 60
    for row in judgments:
        assert set(row["scores"]) == set("ABCDEF")
        for letter, score in row["scores"].items():
            assert isinstance(score, int) and 0 <= score <= 3
            assert score == 0 or row.get("notes", {}).get(letter), (row["id"], letter)
    key = json.loads((REVIEW / "key.json").read_text())
    dest = HERE / "results-hymt3"
    dest.mkdir(exist_ok=True)
    decoded = [{"id": r["id"], "category": cases[r["id"]]["category"],
                "scores": {key[r["id"]][l]: s for l, s in r["scores"].items()},
                "notes": {key[r["id"]][l]: n for l, n in r.get("notes", {}).items()}} for r in judgments]
    (dest / "quality.json").write_text(json.dumps(decoded, ensure_ascii=False, indent=2) + "\n")
    shutil.copyfile(REVIEW / "key.json", dest / "review-key.json")
    for i in range(1, 7):
        shutil.copyfile(REVIEW / f"batch-{i}.json", dest / f"review-batch-{i}.json")
    chrf = CHRF(word_order=2)
    summary = {}
    for name in NAMES:
        rows = [json.loads(l) for l in (WORK / "results" / f"{name}.jsonl").read_text().splitlines()]
        measured = [r for r in rows if r.get("phase") == "measured"]
        assert len(measured) == 180, name
        first = {r["id"]: r for r in measured if r["repetition"] == 1}
        sc = [r["scores"][name] for r in decoded]
        wins = sum(r["scores"][name] < r["scores"]["apple"] for r in decoded)
        losses = sum(r["scores"][name] > r["scores"]["apple"] for r in decoded)
        summary[name] = {
            "short": stats([r["seconds"] for r in measured if cases[r["id"]]["category"] != "paragraph"]),
            "paragraph": stats([r["seconds"] for r in measured if cases[r["id"]]["category"] == "paragraph"]),
            "quality_counts": {str(k): sc.count(k) for k in range(4)},
            "major_or_critical": sum(s >= 2 for s in sc), "critical": sc.count(3), "penalty_sum": sum(sc),
            "vs_apple": {"better": wins, "same": 60 - wins - losses, "worse": losses},
            "critical_ids": [r["id"] for r in decoded if r["scores"][name] == 3],
            "chrfpp": round(chrf.corpus_score([first[i].get("output", "") for i in cases],
                                              [[cases[i]["reference"] for i in cases]]).score, 2),
            "changed_on_repeat": len({r["id"] for r in measured if r.get("output") != first[r["id"]].get("output")}),
            "peak_rss_bytes": rows[-1].get("peak_rss_bytes"),
            "load_s": next((round(r["load_s"], 3) for r in rows if r["type"] == "loaded"), None),
        }
        if name.startswith("hymt3"):
            shutil.copyfile(WORK / "results" / f"{name}.jsonl", dest / f"{name}.jsonl")
    (dest / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=1))
