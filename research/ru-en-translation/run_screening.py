#!/usr/bin/env python3
"""Sequential, local RU→EN screening. Run from the repository root.

No model downloads happen here. Each invocation loads one explicitly supplied
artifact, writes append-only JSONL, and stops its own server on exit.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import subprocess
import threading
import time

import psutil
import requests

ROOT = Path(__file__).resolve().parents[2]
CORPUS = Path(__file__).with_name("corpus.json")


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def jobs(corpus, repetitions):
    for i, text in enumerate(corpus["warmup"]):
        yield {"id": f"warmup-{i}", "source": text, "phase": "warmup", "repetition": 0}
    for rep in range(1, repetitions + 1):
        offset = (rep - 1) * 17 % len(corpus["cases"])
        ordered = corpus["cases"][offset:] + corpus["cases"][:offset]
        for item in ordered:
            yield {"id": item["id"], "source": item["source"], "phase": "measured", "repetition": rep}


class MemorySampler:
    def __init__(self, pid):
        self.process = psutil.Process(pid)
        self.peak_rss = 0
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        while not self.stop_event.wait(0.05):
            try:
                self.peak_rss = max(self.peak_rss, self.process.memory_info().rss)
            except psutil.Error:
                break

    def stop(self):
        self.stop_event.set()
        self.thread.join()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, choices=["yandex", "hy", "madlad", "opus", "t5"])
    parser.add_argument("--path", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--server", default="dist/translation-screening/llama/llama-b11433/llama-server")
    parser.add_argument("--engine", choices=["llama", "transformers"], required=True)
    parser.add_argument("--device", choices=["cpu", "mps"], default="mps")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--port", type=int, default=18765)
    args = parser.parse_args()
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    corpus = json.loads(CORPUS.read_text())
    child = None
    memory = None
    server_log = None
    model = None
    torch = None
    with output.open("x") as f:
        def emit(row):
            f.write(json.dumps({"model": args.model, **row}, ensure_ascii=False) + "\n")
            f.flush()
        try:
            weights = Path(args.path)
            weight_files = [weights] if weights.is_file() else sorted(weights.glob("*.safetensors")) or sorted(weights.glob("pytorch_model*.bin"))
            artifacts = [{"file": p.name, "bytes": p.stat().st_size, "sha256": digest(p)} for p in weight_files]
            emit({"type": "metadata", "engine": args.engine, "device": args.device if args.engine == "transformers" else "Metal",
                  "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "platform": platform.platform(),
                  "corpus_sha256": digest(CORPUS), "weights": artifacts,
                  "generation": {"sampling": False, "max_new_tokens": 512, "prompt_cache": False, "beam_size": 1},
                  "packages": {p: importlib.metadata.version(p) for p in ["torch", "transformers", "requests"]},
                  "note": "Artifact hashing warms filesystem cache before load; load_s is process/model readiness, not uncached disk boot. Peak RSS is not full unified-memory usage."})
            load_start = time.perf_counter()
            if args.engine == "llama":
                # Refuse to use someone else's listener.
                import socket
                with socket.socket() as sock:
                    if sock.connect_ex(("127.0.0.1", args.port)) == 0:
                        raise RuntimeError(f"Port {args.port} is already occupied")
                server_log = output.with_suffix(".server.log").open("x")
                command = [args.server, "-m", args.path, "--host", "127.0.0.1", "--port", str(args.port),
                           "-ngl", "99", "-c", "4096", "-np", "1", "-t", "8", "--jinja", "--no-warmup"]
                child = subprocess.Popen(command, stdout=server_log, stderr=subprocess.STDOUT)
                memory = MemorySampler(child.pid)
                base = f"http://127.0.0.1:{args.port}"
                client = requests.Session()
                deadline = time.monotonic() + 180
                while True:
                    if child.poll() is not None:
                        raise RuntimeError(f"Server exited with {child.returncode}; see server log")
                    try:
                        if client.get(base + "/health", timeout=2).status_code == 200:
                            break
                    except requests.RequestException:
                        pass
                    if time.monotonic() > deadline:
                        raise TimeoutError("Model server did not become ready")
                    time.sleep(0.25)
                props = client.get(base + "/props", timeout=5).json()
                emit({"type": "loaded", "load_s": time.perf_counter() - load_start,
                      "chat_template": props.get("chat_template"), "command": command})

                def translate(text):
                    # Timing includes formatting/tokenization and full output, not model startup.
                    if args.model == "madlad":
                        prompt = "<2en> " + text
                    else:
                        instruction = ("Переведи следующий текст с русского на английский. Сохрани весь смысл, числа и имена. "
                                       "Выведи только перевод, без пояснений.\n\n" + text) if args.model == "yandex" else (
                                       "Translate the following segment into English, without additional explanation.\n\n" + text)
                        if args.model == "yandex":
                            instruction = instruction.replace("\n", "[NL]")
                        response = client.post(base + "/apply-template", json={"messages": [{"role": "user", "content": instruction}],
                                                "add_generation_prompt": True}, timeout=10)
                        response.raise_for_status()
                        prompt = response.json()["prompt"]
                    response = client.post(base + "/completion", json={"prompt": prompt, "n_predict": 512,
                                           "temperature": 0, "seed": 42, "cache_prompt": False,
                                           "repeat_penalty": 1.0, "stream": False}, timeout=120)
                    response.raise_for_status()
                    result = response.json()
                    return result.get("content", "").strip(), {"tokens": result.get("tokens_predicted"),
                        "input_tokens": result.get("tokens_evaluated"), "timings": result.get("timings"),
                        "stop_type": result.get("stop_type"), "truncated": result.get("truncated", False),
                        "prompt": prompt if text == corpus["warmup"][0] else None}
            else:
                import torch as torch_module
                from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
                torch = torch_module
                torch.set_num_threads(8)
                tokenizer = AutoTokenizer.from_pretrained(args.path, local_files_only=True)
                # FP32 for small encoder-decoders: avoid half-precision numeric differences in screening.
                model = AutoModelForSeq2SeqLM.from_pretrained(args.path, local_files_only=True, torch_dtype=torch.float32)
                model.to(args.device).eval()
                if args.device == "mps":
                    torch.mps.synchronize()
                memory = MemorySampler(os.getpid())
                emit({"type": "loaded", "load_s": time.perf_counter() - load_start,
                      "parameter_count": sum(p.numel() for p in model.parameters()), "dtype": "float32"})

                def translate(text):
                    prefix = "translate to en: " if args.model == "t5" else "<2en> " if args.model == "madlad" else ""
                    encoded = tokenizer(prefix + text, return_tensors="pt", truncation=False).to(args.device)
                    with torch.inference_mode():
                        generated = model.generate(**encoded, max_new_tokens=512, do_sample=False, num_beams=1)
                    if args.device == "mps":
                        torch.mps.synchronize()
                    return tokenizer.decode(generated[0], skip_special_tokens=True).strip(), {
                        "tokens": generated.shape[-1], "input_tokens": encoded["input_ids"].shape[-1],
                        "truncated": generated.shape[-1] >= 513}

            for job in jobs(corpus, args.repetitions):
                start = time.perf_counter()
                row = {"type": "result", **{k: v for k, v in job.items() if k != "source"}}
                try:
                    text, extra = translate(job["source"])
                    row.update(output=text, **extra)
                    if not text:
                        row["error"] = "empty output"
                except Exception as exc:
                    row["error"] = f"{type(exc).__name__}: {exc}"
                row["seconds"] = time.perf_counter() - start
                emit(row)
                print(args.model, job["id"], job["repetition"], round(row["seconds"], 3), row.get("error", ""), flush=True)
                if "error" in row:
                    # Do not send overlapping requests after a timeout and corrupt latency measurements.
                    raise RuntimeError("Stopping after first error; partial result retained")
            summary = {"type": "summary", "peak_rss_bytes": memory.peak_rss if memory else None}
            if torch and args.device == "mps":
                summary.update(mps_current_allocated_bytes=torch.mps.current_allocated_memory(),
                               mps_driver_allocated_bytes=torch.mps.driver_allocated_memory())
            emit(summary)
        finally:
            if memory:
                memory.stop()
            if child and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            if server_log:
                server_log.close()


if __name__ == "__main__":
    main()
