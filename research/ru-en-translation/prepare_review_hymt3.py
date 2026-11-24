#!/usr/bin/env python3
"""Blind review for Hy-MT3 (2026-11-24): 3 new checkpoints + 3 anchors from the October run.

Anchors (apple, yandex, hy = HY-MT1.5 1.8B) are re-scored blind together with the new models,
so the new rows are comparable with the old table and scorer drift is visible.
"""
import json
from pathlib import Path
import secrets

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "dist/translation-screening"
SOURCES = {"apple": "apple", "yandex": "yandex", "hy": "hy",
           "hymt3-1.8b": "hymt3-1.8b", "hymt3-7b": "hymt3-7b", "hymt3-30b": "hymt3-30b"}

if __name__ == "__main__":
    corpus = json.loads(Path(__file__).with_name("corpus.json").read_text())
    results = {}
    for name, stem in SOURCES.items():
        rows = [json.loads(line) for line in (WORK / "results" / (stem + ".jsonl")).read_text().splitlines()]
        assert rows[-1]["type"] == "summary", f"Incomplete run: {name}"
        assert not any(row.get("error") for row in rows), f"Errors: {name}"
        selected = [r for r in rows if r.get("phase") == "measured" and r["repetition"] == 1]
        assert len(selected) == 60, name
        results[name] = {r["id"]: r["output"] for r in selected}
    destination = WORK / "review-hymt3"
    destination.mkdir(exist_ok=True)
    key = {}
    batches = [[] for _ in range(6)]
    rng = secrets.SystemRandom()
    for index, item in enumerate(corpus["cases"]):
        names = list(results)
        rng.shuffle(names)
        variants = {}
        key[item["id"]] = {}
        for letter, name in zip("ABCDEF", names):
            variants[letter] = results[name][item["id"]]
            key[item["id"]][letter] = name
        batches[index // 10].append({"id": item["id"], "source": item["source"], "check": item["check"], "variants": variants})
    for index, batch in enumerate(batches, 1):
        with (destination / f"batch-{index}.json").open("x") as f:
            json.dump(batch, f, ensure_ascii=False, indent=2)
            f.write("\n")
    with (destination / "key.json").open("x") as f:
        json.dump(key, f, indent=2)
        f.write("\n")
    print("Created six anonymized batches in", destination, "- do not read key.json before all scores are saved.")
