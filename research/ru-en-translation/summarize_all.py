#!/usr/bin/env python3
"""Decode the unified blind re-score (all participants) and build the final table.

The key is opened only after all six score files validate. Variants shared by several
models (identical outputs) give the same score to each of those models.
"""
import json
from pathlib import Path
import shutil
import statistics

import numpy as np
from sacrebleu.metrics import CHRF

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORK = ROOT / "dist/translation-screening"
REVIEW = WORK / "review-all"
SOURCES = {"apple": "apple", "yandex": "yandex", "hy": "hy", "opus": "opus", "t5": "t5-mps",
           "madlad": "madlad-mps", "hymt3-1.8b": "hymt3-1.8b", "hymt3-7b": "hymt3-7b", "hymt3-30b": "hymt3-30b"}


def stats(values):
    return {"median_s": round(statistics.median(values), 3), "p95_s": round(float(np.percentile(values, 95)), 3)}


if __name__ == "__main__":
    corpus = json.loads((HERE / "corpus.json").read_text())
    cases = {x["id"]: x for x in corpus["cases"]}
    judgments = []
    for i in range(1, 7):
        batch = json.loads((HERE / "scores-all" / f"batch-{i}.json").read_text())
        review = {x["id"]: x for x in json.loads((REVIEW / f"batch-{i}.json").read_text())}
        assert len(batch) == 10
        for row in batch:
            assert set(row["scores"]) == set(review[row["id"]]["variants"]), row["id"]
            for letter, score in row["scores"].items():
                assert isinstance(score, int) and 0 <= score <= 3
                assert score == 0 or row.get("notes", {}).get(letter), (row["id"], letter)
        judgments.extend(batch)
    assert {x["id"] for x in judgments} == set(cases) and len(judgments) == 60
    key = json.loads((REVIEW / "key.json").read_text())
    decoded = []
    for r in judgments:
        scores, notes = {}, {}
        for letter, score in r["scores"].items():
            for model in key[r["id"]][letter]:
                scores[model] = score
                if letter in r.get("notes", {}):
                    notes[model] = r["notes"][letter]
        assert set(scores) == set(SOURCES), r["id"]
        decoded.append({"id": r["id"], "category": cases[r["id"]]["category"], "scores": scores, "notes": notes})
    dest = HERE / "results-all"
    dest.mkdir(exist_ok=True)
    (dest / "quality.json").write_text(json.dumps(decoded, ensure_ascii=False, indent=2) + "\n")
    shutil.copyfile(REVIEW / "key.json", dest / "review-key.json")
    for i in range(1, 7):
        shutil.copyfile(REVIEW / f"batch-{i}.json", dest / f"review-batch-{i}.json")
    chrf = CHRF(word_order=2)
    summary = {}
    for name, stem in SOURCES.items():
        rows = [json.loads(l) for l in (WORK / "results" / f"{stem}.jsonl").read_text().splitlines()]
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
            "clean": sc.count(0), "major_or_critical": sum(s >= 2 for s in sc), "critical": sc.count(3),
            "penalty_sum": sum(sc),
            "vs_apple": {"better": wins, "same": 60 - wins - losses, "worse": losses},
            "critical_ids": [r["id"] for r in decoded if r["scores"][name] == 3],
            "chrfpp": round(chrf.corpus_score([first[i].get("output", "") for i in cases],
                                              [[cases[i]["reference"] for i in cases]]).score, 2),
            "peak_rss_bytes": rows[-1].get("peak_rss_bytes"),
        }
    (dest / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    for name, x in sorted(summary.items(), key=lambda kv: kv[1]["penalty_sum"]):
        print(f"{name:11} pen={x['penalty_sum']:3} clean={x['clean']:2} maj+crit={x['major_or_critical']:2} "
              f"crit={x['critical']:2} {x['critical_ids']} vsApple={x['vs_apple']} chrF={x['chrfpp']} "
              f"short={x['short']['median_s']}/{x['short']['p95_s']} para={x['paragraph']['median_s']} "
              f"rss={round((x['peak_rss_bytes'] or 0) / 1e9, 2)}")
