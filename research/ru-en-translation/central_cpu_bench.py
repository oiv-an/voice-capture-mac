#!/usr/bin/env python3
"""Hy-MT3 CPU benchmark on central: same corpus/prompt/params as research/ru-en-translation/run_screening.py.

Starts a temporary llama.cpp container on 127.0.0.1, runs warmup + 3 reps x 60 cases, records
latency, load time and peak memory (VmHWM of llama-server + cgroup memory.peak), then removes the container.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

import requests

DIR = Path(__file__).resolve().parent  # must contain corpus.json and the .gguf file (on central: /www/hy-mt3-test)
IMAGE = sys.argv[1]
MODEL = sys.argv[2]
THREADS = sys.argv[3] if len(sys.argv) > 3 else "16"
NAME = "hymt3-bench"
PORT = 18766
OUT = DIR / f"result-{Path(MODEL).stem}-t{THREADS}.jsonl"
corpus = json.loads((DIR / "corpus.json").read_text())


def jobs():
    for i, text in enumerate(corpus["warmup"]):
        yield {"id": f"warmup-{i}", "source": text, "phase": "warmup", "repetition": 0}
    for rep in range(1, 4):
        offset = (rep - 1) * 17 % len(corpus["cases"])
        for item in corpus["cases"][offset:] + corpus["cases"][:offset]:
            yield {"id": item["id"], "source": item["source"], "phase": "measured", "repetition": rep}


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout.strip()


def memory(pid, cid):
    status = Path(f"/proc/{pid}/status").read_text()
    vals = {l.split(":")[0]: l.split(":")[1].strip() for l in status.splitlines() if l.startswith(("VmHWM", "VmRSS"))}
    peak = None
    for p in [f"/sys/fs/cgroup/system.slice/docker-{cid}.scope/memory.peak", f"/sys/fs/cgroup/docker/{cid}/memory.peak"]:
        if Path(p).exists():
            peak = int(Path(p).read_text())
    return {"vm_hwm": vals.get("VmHWM"), "vm_rss": vals.get("VmRSS"), "cgroup_memory_peak_bytes": peak}


subprocess.run(["docker", "rm", "-f", NAME], capture_output=True)
with OUT.open("x") as f:
    def emit(row):
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
        f.flush()
    emit({"type": "metadata", "image": IMAGE, "model": MODEL, "threads": THREADS, "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
          "cpu": sh("sh", "-c", "lscpu | grep 'Model name' | head -1"), "nproc": sh("nproc")})
    load_start = time.perf_counter()
    cid = sh("docker", "run", "-d", "--name", NAME, f"--cpus={THREADS}", "--memory=26g", "-p", f"127.0.0.1:{PORT}:8080",
             "-v", f"{DIR}:/models:ro", IMAGE, "-m", f"/models/{MODEL}", "--host", "0.0.0.0", "--port", "8080",
             "-c", "4096", "-np", "1", "-t", THREADS, "--jinja", "--no-warmup")
    try:
        base = f"http://127.0.0.1:{PORT}"
        client = requests.Session()
        deadline = time.monotonic() + 600
        while True:
            try:
                if client.get(base + "/health", timeout=2).status_code == 200:
                    break
            except requests.RequestException:
                pass
            if time.monotonic() > deadline or sh("docker", "inspect", "-f", "{{.State.Running}}", NAME) != "true":
                raise RuntimeError("server not ready: " + sh("sh", "-c", f"docker logs --tail 30 {NAME} 2>&1"))
            time.sleep(0.5)
        pid = sh("docker", "inspect", "-f", "{{.State.Pid}}", NAME)
        emit({"type": "loaded", "load_s": time.perf_counter() - load_start, "container_id": cid, **memory(pid, cid)})
        for job in jobs():
            instruction = ("Translate the following text into English. Note that you should only output "
                           "the translated result without any additional explanation:\n\n" + job["source"])
            start = time.perf_counter()
            r = client.post(base + "/apply-template", json={"messages": [{"role": "user", "content": instruction}],
                            "add_generation_prompt": True}, timeout=30)
            r.raise_for_status()
            r = client.post(base + "/completion", json={"prompt": r.json()["prompt"], "n_predict": 512, "temperature": 0,
                            "seed": 42, "cache_prompt": False, "repeat_penalty": 1.0, "stream": False}, timeout=300)
            r.raise_for_status()
            res = r.json()
            row = {"type": "result", **{k: v for k, v in job.items() if k != "source"},
                   "output": res.get("content", "").strip(), "tokens": res.get("tokens_predicted"),
                   "input_tokens": res.get("tokens_evaluated"), "timings": res.get("timings"),
                   "stop_type": res.get("stop_type"), "seconds": time.perf_counter() - start}
            emit(row)
            print(job["id"], job["repetition"], round(row["seconds"], 2), flush=True)
        emit({"type": "summary", **memory(pid, cid),
              "docker_stats": sh("docker", "stats", "--no-stream", "--format", "{{.MemUsage}} {{.CPUPerc}}", NAME)})
    finally:
        subprocess.run(["docker", "rm", "-f", NAME], capture_output=True)
print("done", OUT)
