#!/usr/bin/env python3
"""Pinned public artifacts for the approved quick screening, no gated model bypass."""
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "dist/translation-screening"
os.environ.setdefault("HF_HOME", str(WORK / "hf-cache"))
from huggingface_hub import hf_hub_download, snapshot_download

MODELS = [
    {"id": "yandex", "repo": "yandex/YandexGPT-5-Lite-8B-instruct-GGUF",
     "revision": "9fe287d2f512503046bb008aed350f2b4bbb903d",
     "file": "YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf", "license": "YandexGPT-5-Lite-8B"},
    {"id": "hy", "repo": "tencent/HY-MT1.5-1.8B-GGUF",
     "revision": "265b2e615a7dc9b06c435dc878829ad99a512ba2",
     "file": "HY-MT1.5-1.8B-Q4_K_M.gguf", "license": "Tencent HY Community; territory restrictions"},
    {"id": "madlad-fp32", "repo": "google/madlad400-3b-mt",
     "revision": "fa184c675da0b5c9e1c8694fccd4e12e2d422094", "license": "Apache-2.0"},
    {"id": "opus", "repo": "Helsinki-NLP/opus-mt-ru-en",
     "revision": "fbd6dc73284f95536648512cc21d57f19191961a", "license": "CC-BY-4.0"},
    {"id": "t5", "repo": "utrobinmv/t5_translate_en_ru_zh_small_1024",
     "revision": "bb215079c5910bee0154f7f6c1350d57502c5d97", "license": "Apache-2.0"},
]

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", nargs="*", choices=[m["id"] for m in MODELS])
    args = parser.parse_args()
    for model in MODELS:
        if args.only and model["id"] not in args.only:
            continue
        dest = WORK / "models" / model["id"]
        print("Downloading", model["id"], model["revision"], flush=True)
        if "file" in model:
            hf_hub_download(model["repo"], model["file"], revision=model["revision"], local_dir=dest)
        else:
            snapshot_download(model["repo"], revision=model["revision"], local_dir=dest,
                              allow_patterns=["*.json", "*.spm", "*.model", "*.safetensors", "pytorch_model.bin", "README.md", "LICENSE*"],
                              max_workers=3)
        (dest / "screening-artifact.json").write_text(json.dumps(model, indent=2) + "\n")
        print("Ready", model["id"], flush=True)
