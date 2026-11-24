#!/usr/bin/env python3
"""Unified blind review of ALL participants (2026-11-24 re-score).

Identical outputs for one case are merged into one variant, so each distinct translation
is scored once. Variant order is shuffled; the key (variant -> models) stays in key.json
and must not be read before all scores are saved.
"""
import json
from pathlib import Path
import secrets

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "dist/translation-screening"
SOURCES = {"apple": "apple", "yandex": "yandex", "hy": "hy", "opus": "opus", "t5": "t5-mps",
           "madlad": "madlad-mps", "hymt3-1.8b": "hymt3-1.8b", "hymt3-7b": "hymt3-7b", "hymt3-30b": "hymt3-30b"}
LETTERS = "ABCDEFGHI"

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
    destination = WORK / "review-all"
    destination.mkdir(exist_ok=True)
    key = {}
    batches = [[] for _ in range(6)]
    rng = secrets.SystemRandom()
    for index, item in enumerate(corpus["cases"]):
        groups = {}
        for name in SOURCES:
            groups.setdefault(results[name][item["id"]], []).append(name)
        texts = list(groups)
        rng.shuffle(texts)
        variants = {}
        key[item["id"]] = {}
        for letter, text in zip(LETTERS, texts):
            variants[letter] = text
            key[item["id"]][letter] = groups[text]
        batches[index // 10].append({"id": item["id"], "source": item["source"], "check": item["check"], "variants": variants})
    for index, batch in enumerate(batches, 1):
        with (destination / f"batch-{index}.json").open("x") as f:
            json.dump(batch, f, ensure_ascii=False, indent=2)
            f.write("\n")
    with (destination / "key.json").open("x") as f:
        json.dump(key, f, indent=2)
        f.write("\n")
    print("Created six anonymized batches in", destination, "- do not read key.json before all scores are saved.")
