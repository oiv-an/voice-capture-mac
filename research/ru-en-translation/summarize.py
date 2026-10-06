#!/usr/bin/env python3
"""Join completed blind scores to models only AFTER all six batches are scored."""
import json
from pathlib import Path
import shutil
import statistics

import numpy as np
from sacrebleu.metrics import BLEU, CHRF

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORK = ROOT / "dist/translation-screening"
SOURCES = {"apple": "apple", "yandex": "yandex", "hy": "hy", "opus": "opus", "t5": "t5-mps", "madlad": "madlad-mps"}


def stats(values):
    return {"n": len(values), "median_s": statistics.median(values),
            "p95_s": float(np.percentile(values, 95)), "max_s": max(values)}


if __name__ == "__main__":
    corpus = json.loads((HERE / "corpus.json").read_text())
    cases = {x["id"]: x for x in corpus["cases"]}
    judgments = []
    for i in range(1, 7):
        batch = json.loads((HERE / "scores" / f"batch-{i}.json").read_text())
        assert len(batch) == 10
        judgments.extend(batch)
    assert {x["id"] for x in judgments} == set(cases)
    assert len(judgments) == len(cases)
    for row in judgments:
        assert set(row["scores"]) == set("ABCDEF")
        for letter, score in row["scores"].items():
            assert isinstance(score, int) and 0 <= score <= 3
            assert score == 0 or row.get("notes", {}).get(letter), (row["id"], letter)
    # Opening the key is deliberately delayed until validation of ALL scores.
    key = json.loads((WORK / "review/key.json").read_text())
    dest = HERE / "results"
    dest.mkdir(exist_ok=True)
    decoded = []
    for row in judgments:
        decoded.append({"id": row["id"], "category": cases[row["id"]]["category"],
                        "scores": {key[row["id"]][letter]: score for letter, score in row["scores"].items()},
                        "notes": {key[row["id"]][letter]: note for letter, note in row.get("notes", {}).items()}})
    (dest / "quality.json").write_text(json.dumps(decoded, ensure_ascii=False, indent=2) + "\n")
    shutil.copyfile(WORK / "review/key.json", dest / "review-key.json")
    for i in range(1, 7):
        shutil.copyfile(WORK / "review" / f"batch-{i}.json", dest / f"review-batch-{i}.json")
    summary = {}
    bleu, chrf = BLEU(), CHRF(word_order=2)
    for name, stem in SOURCES.items():
        source = WORK / "results" / (stem + ".jsonl")
        rows = [json.loads(line) for line in source.read_text().splitlines()]
        assert rows[-1]["type"] == "summary", name
        measured = [r for r in rows if r.get("phase") == "measured"]
        assert len(measured) == 180, name
        first = {r["id"]: r for r in measured if r["repetition"] == 1}
        assert set(first) == set(cases)
        outputs = [first[i].get("output", "") for i in cases]
        refs = [[cases[i]["reference"] for i in cases]]
        by_case_scores = [r["scores"][name] for r in decoded]
        wins = sum(r["scores"][name] < r["scores"]["apple"] for r in decoded)
        losses = sum(r["scores"][name] > r["scores"]["apple"] for r in decoded)
        item = {
            "latency_all": stats([r["seconds"] for r in measured]),
            "latency_first_pass": stats([r["seconds"] for r in first.values()]),
            "short": stats([r["seconds"] for r in measured if cases[r["id"]]["category"] != "paragraph"]),
            "paragraph": stats([r["seconds"] for r in measured if cases[r["id"]]["category"] == "paragraph"]),
            "error_count": sum(bool(r.get("error")) for r in measured),
            "truncated_count": sum(bool(r.get("truncated")) or r.get("stop_type") == "limit" for r in measured),
            "changed_on_repeat": len({r["id"] for r in measured if r.get("output") != first[r["id"]].get("output")}),
            "quality_counts": {str(k): by_case_scores.count(k) for k in range(4)},
            "quality_penalty_sum": sum(by_case_scores),
            "vs_apple": {"better": wins, "same_score": 60 - wins - losses, "worse": losses},
            "bleu": bleu.corpus_score(outputs, refs).score,
            "chrfpp": chrf.corpus_score(outputs, refs).score,
            "bleu_signature": str(bleu.get_signature()), "chrf_signature": str(chrf.get_signature()),
            "categories": {cat: {"penalty_sum": sum(r["scores"][name] for r in decoded if r["category"] == cat),
                                  "major_or_critical": sum(r["scores"][name] >= 2 for r in decoded if r["category"] == cat)}
                           for cat in sorted({c["category"] for c in cases.values()})},
            "loaded": next((r for r in rows if r["type"] == "loaded"), None),
            "resources": rows[-1],
        }
        summary[name] = item
        shutil.copyfile(source, dest / (name + ".jsonl"))
    (dest / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({name: {k: x[k] for k in ["short", "paragraph", "quality_counts", "vs_apple", "chrfpp", "changed_on_repeat"]}
                      for name, x in summary.items()}, ensure_ascii=False, indent=2))
