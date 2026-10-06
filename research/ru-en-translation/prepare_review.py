#!/usr/bin/env python3
"""Export anonymized first-pass responses; keep model key separate until scoring."""
import json
from pathlib import Path
import secrets

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "dist/translation-screening"
SOURCES = {"apple": "apple", "yandex": "yandex", "hy": "hy", "opus": "opus", "t5": "t5-mps", "madlad": "madlad-mps"}

if __name__ == "__main__":
    corpus = json.loads(Path(__file__).with_name("corpus.json").read_text())
    results = {}
    for name, stem in SOURCES.items():
        rows = [json.loads(line) for line in (WORK / "results" / (stem + ".jsonl")).read_text().splitlines()]
        assert rows[-1]["type"] == "summary", f"Incomplete run: {name}"
        assert not any(row.get("error") for row in rows), f"Errors: {name}"
        selected = [r for r in rows if r.get("phase") == "measured" and r["repetition"] == 1]
        assert len(selected) == 60
        results[name] = {r["id"]: r["output"] for r in selected}
    destination = WORK / "review"
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
    print("Created six anonymized batches. Do not read key.json before completing all scores.")
