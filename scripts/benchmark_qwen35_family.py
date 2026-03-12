#!/usr/bin/env python3
"""Benchmark Qwen3.5 instruct variants under llama.cpp and write reports."""

from __future__ import annotations

import argparse
import csv
import http.client
import json
import os
import platform
import fnmatch
import shutil
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

@dataclass(frozen=True)
class ModelSpec:
    slug: str
    label: str
    repo_candidates: tuple[str, ...]

@dataclass(frozen=True)
class ProfileSpec:
    slug: str
    label: str
    enable_thinking: bool
    temperature: float
    top_p: float
    top_k: int
    min_p: float
    presence_penalty: float
    repeat_penalty: float

MODELS: tuple[ModelSpec, ...] = (
    ModelSpec(
        slug="qwen3.5-0.8b",
        label="Qwen3.5-0.8B",
        repo_candidates=(
            "lmstudio-community/Qwen3.5-0.8B-GGUF",
            "bartowski/Qwen3.5-0.8B-GGUF",
        ),
    ),
    ModelSpec(
        slug="qwen3.5-2b",
        label="Qwen3.5-2B",
        repo_candidates=(
            "lmstudio-community/Qwen3.5-2B-GGUF",
            "bartowski/Qwen3.5-2B-GGUF",
        ),
    ),
    ModelSpec(
        slug="qwen3.5-4b",
        label="Qwen3.5-4B",
        repo_candidates=(
            "lmstudio-community/Qwen3.5-4B-GGUF",
            "bartowski/Qwen3.5-4B-GGUF",
        ),
    ),
    ModelSpec(
        slug="qwen3.5-9b",
        label="Qwen3.5-9B",
        repo_candidates=(
            "lmstudio-community/Qwen3.5-9B-GGUF",
            "bartowski/Qwen3.5-9B-GGUF",
        ),
    ),
    ModelSpec(
        slug="qwen3.5-27b",
        label="Qwen3.5-27B",
        repo_candidates=(
            "lmstudio-community/Qwen3.5-27B-GGUF",
            "bartowski/Qwen3.5-27B-GGUF",
        ),
    ),
    ModelSpec(
        slug="qwen3.5-35b-a3b",
        label="Qwen3.5-35B-A3B",
        repo_candidates=(
            "lmstudio-community/Qwen3.5-35B-A3B-GGUF",
            "bartowski/Qwen3.5-35B-A3B-GGUF",
        ),
    ),
    ModelSpec(
        slug="qwen3.5-122b-a10b",
        label="Qwen3.5-122B-A10B",
        repo_candidates=(
            "lmstudio-community/Qwen3.5-122B-A10B-GGUF",
            "bartowski/Qwen3.5-122B-A10B-GGUF",
        ),
    ),
)

PROFILES: tuple[ProfileSpec, ...] = (
    ProfileSpec(
        slug="thinking_general",
        label="Thinking / general",
        enable_thinking=True,
        temperature=1.0,
        top_p=0.95,
        top_k=20,
        min_p=0.0,
        presence_penalty=1.5,
        repeat_penalty=1.0,
    ),
    ProfileSpec(
        slug="thinking_precise_coding",
        label="Thinking / precise coding",
        enable_thinking=True,
        temperature=0.6,
        top_p=0.95,
        top_k=20,
        min_p=0.0,
        presence_penalty=0.0,
        repeat_penalty=1.0,
    ),
    ProfileSpec(
        slug="non_thinking_general",
        label="Non-thinking / general",
        enable_thinking=False,
        temperature=0.7,
        top_p=0.8,
        top_k=20,
        min_p=0.0,
        presence_penalty=1.5,
        repeat_penalty=1.0,
    ),
    ProfileSpec(
        slug="non_thinking_reasoning",
        label="Non-thinking / reasoning",
        enable_thinking=False,
        temperature=1.0,
        top_p=1.0,
        top_k=40,
        min_p=0.0,
        presence_penalty=2.0,
        repeat_penalty=1.0,
    ),
)

SYSTEM_PROMPT = (
    "You are benchmarking a local coding assistant for repository analysis. "
    "Be concise and follow the requested structure exactly."
)
USER_PROMPT = (
    "You are reviewing a software repository for a coding agent. "
    "In under 120 words, provide a one-sentence project summary, three concise bullets "
    "naming the subsystems you would inspect first, and one short risk note."
)

def run(cmd: list[str], *, env: dict[str, str] | None = None, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        check=True,
        text=True,
        capture_output=True,
    )

def repo_cache_dir(cache_root: Path, repo_id: str) -> Path:
    return cache_root / repo_id.replace("/", "_")

def find_local_q8_files(local_dir: Path) -> list[Path]:
    return sorted(
        path
        for path in local_dir.rglob("*.gguf")
        if fnmatch.fnmatch(path.name, "*Q8_0*.gguf") and "mmproj" not in path.name.lower()
    )

def ensure_model(cache_root: Path, model: ModelSpec) -> tuple[str, Path, list[str]]:
    for repo_id in model.repo_candidates:
        local_dir = repo_cache_dir(cache_root, repo_id)
        files = find_local_q8_files(local_dir)
        if not files:
            try:
                result = run(
                    [
                        "hf",
                        "download",
                        repo_id,
                        "--include",
                        "*Q8_0*.gguf",
                        "--local-dir",
                        str(local_dir),
                    ]
                )
                sys.stdout.write(result.stdout)
                sys.stderr.write(result.stderr)
            except subprocess.CalledProcessError:
                continue
            files = find_local_q8_files(local_dir)
        if files:
            return repo_id, files[0], [str(path.relative_to(local_dir)) for path in files]
    raise RuntimeError(f"could not download a Q8_0 GGUF repo for {model.label}")

def start_server(scripts_dir: Path, model_path: Path, context: int, ctx_checkpoints: int, checkpoint_every: int) -> None:
    env = os.environ.copy()
    env.update(
        {
            "LLAMACPP_MODEL": str(model_path),
            "LLAMACPP_CONTEXT": str(context),
            "LLAMACPP_CTX_CHECKPOINTS": str(ctx_checkpoints),
            "LLAMACPP_CHECKPOINT_EVERY_N_TOKENS": str(checkpoint_every),
            "LLAMACPP_SMOKE_TEST": "false",
        }
    )
    result = run(["bash", str(scripts_dir / "server_start_llamacpp.sh")], env=env, cwd=scripts_dir.parent)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)

def stop_server(scripts_dir: Path) -> None:
    try:
        result = run(["bash", str(scripts_dir / "server_stop_llamacpp.sh")], cwd=scripts_dir.parent)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
    except subprocess.CalledProcessError as exc:
        sys.stdout.write(exc.stdout)
        sys.stderr.write(exc.stderr)

def base_payload(profile: ProfileSpec, max_tokens: int) -> dict[str, Any]:
    return {
        "model": "local",
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": USER_PROMPT},
        ],
        "max_tokens": max_tokens,
        "temperature": profile.temperature,
        "top_p": profile.top_p,
        "top_k": profile.top_k,
        "min_p": profile.min_p,
        "presence_penalty": profile.presence_penalty,
        "repeat_penalty": profile.repeat_penalty,
        "seed": 1234,
        "chat_template_kwargs": {"enable_thinking": profile.enable_thinking},
    }

def stream_ttft(host: str, port: int, profile: ProfileSpec, max_tokens: int) -> float:
    payload = base_payload(profile, max_tokens)
    payload["stream"] = True

    conn = http.client.HTTPConnection(host, port, timeout=600)
    body = json.dumps(payload)
    start = time.perf_counter()
    conn.request("POST", "/v1/chat/completions", body=body, headers={"Content-Type": "application/json"})
    response = conn.getresponse()
    if response.status != 200:
        raise RuntimeError(f"stream request failed: {response.status} {response.read().decode('utf-8', errors='replace')}")

    ttft_ms: float | None = None
    while True:
        raw = response.readline()
        if not raw:
            break
        line = raw.decode("utf-8", errors="replace").strip()
        if not line or not line.startswith("data: "):
            continue
        data = line[6:]
        if data == "[DONE]":
            break
        try:
            chunk = json.loads(data)
        except json.JSONDecodeError:
            continue
        choice = (chunk.get("choices") or [{}])[0]
        delta = choice.get("delta") or {}
        piece = delta.get("content") or delta.get("reasoning_content") or ""
        if piece:
            ttft_ms = (time.perf_counter() - start) * 1000.0
            break
    conn.close()
    if ttft_ms is None:
        raise RuntimeError(f"stream did not emit content for profile {profile.slug}")
    return ttft_ms

def nonstream_metrics(host: str, port: int, profile: ProfileSpec, max_tokens: int) -> dict[str, Any]:
    payload = base_payload(profile, max_tokens)
    conn = http.client.HTTPConnection(host, port, timeout=600)
    body = json.dumps(payload)
    conn.request("POST", "/v1/chat/completions", body=body, headers={"Content-Type": "application/json"})
    response = conn.getresponse()
    text = response.read().decode("utf-8", errors="replace")
    conn.close()
    if response.status != 200:
        raise RuntimeError(f"non-stream request failed: {response.status} {text}")
    data = json.loads(text)
    choice = (data.get("choices") or [{}])[0]
    timings = data.get("timings") or {}
    usage = data.get("usage") or {}
    message = choice.get("message") or {}
    return {
        "finish_reason": choice.get("finish_reason"),
        "completion_tokens": usage.get("completion_tokens"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "predicted_per_second": timings.get("predicted_per_second"),
        "predicted_ms": timings.get("predicted_ms"),
        "prompt_ms": timings.get("prompt_ms"),
        "content": message.get("content") or "",
        "reasoning_content": message.get("reasoning_content") or "",
    }

def benchmark_profile(host: str, port: int, profile: ProfileSpec, iterations: int, max_tokens: int) -> list[dict[str, Any]]:
    # Warm the sampler and prompt path once per profile.
    nonstream_metrics(host, port, profile, max_tokens)

    rows: list[dict[str, Any]] = []
    for iteration in range(1, iterations + 1):
        ttft_ms = stream_ttft(host, port, profile, max_tokens)
        metrics = nonstream_metrics(host, port, profile, max_tokens)
        metrics.update({"iteration": iteration, "ttft_ms": ttft_ms})
        rows.append(metrics)
    return rows

def summarize(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for row in records:
        grouped.setdefault((row["model_slug"], row["profile_slug"]), []).append(row)

    summary: list[dict[str, Any]] = []
    for (model_slug, profile_slug), rows in grouped.items():
        summary.append(
            {
                "model_slug": model_slug,
                "model_label": rows[0]["model_label"],
                "repo_id": rows[0]["repo_id"],
                "profile_slug": profile_slug,
                "profile_label": rows[0]["profile_label"],
                "enable_thinking": rows[0]["enable_thinking"],
                "mean_ttft_ms": round(statistics.mean(r["ttft_ms"] for r in rows), 2),
                "stdev_ttft_ms": round(statistics.pstdev(r["ttft_ms"] for r in rows), 2),
                "mean_tokens_per_second": round(statistics.mean(r["predicted_per_second"] for r in rows), 2),
                "stdev_tokens_per_second": round(statistics.pstdev(r["predicted_per_second"] for r in rows), 2),
                "mean_prompt_ms": round(statistics.mean(r["prompt_ms"] for r in rows), 2),
                "mean_completion_tokens": round(statistics.mean(r["completion_tokens"] for r in rows), 2),
                "sample_finish_reason": rows[0]["finish_reason"],
                "sample_content_excerpt": (rows[0]["content"] or rows[0]["reasoning_content"])[:160].replace("\n", " "),
            }
        )
    return sorted(summary, key=lambda item: (item["model_label"], item["profile_label"]))

def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

def write_json(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")

def format_table(summary: list[dict[str, Any]], key: str) -> str:
    profiles = [profile.slug for profile in PROFILES]
    profile_labels = {profile.slug: profile.label for profile in PROFILES}
    rows_by_model: dict[str, dict[str, dict[str, Any]]] = {}
    labels: dict[str, str] = {}
    for row in summary:
        rows_by_model.setdefault(row["model_slug"], {})[row["profile_slug"]] = row
        labels[row["model_slug"]] = row["model_label"]

    lines = ["| Model | " + " | ".join(profile_labels[p] for p in profiles) + " |", "|---" + "|---" * len(profiles) + "|"]
    for model in [model.slug for model in MODELS]:
        cells = [labels.get(model, model)]
        for profile in profiles:
            row = rows_by_model.get(model, {}).get(profile)
            if not row:
                cells.append("n/a")
                continue
            if key == "ttft":
                cells.append(f"{row['mean_ttft_ms']:.2f} ms")
            else:
                cells.append(f"{row['mean_tokens_per_second']:.2f}")
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)

def write_report(path: Path, summary_rows: list[dict[str, Any]], metadata: dict[str, Any]) -> None:
    report = f"""# Qwen3.5 llama.cpp Family Benchmark

## Scope

- Variants: 0.8B, 2B, 4B, 9B, 27B, 35B-A3B, 122B-A10B
- Quant: `Q8_0`
- Runtime: local upstream `llama.cpp` server on the Apple Silicon host used for this repo
- Prompt: fixed coding-agent repository review prompt for all runs
- Iterations per model/profile: {metadata['iterations']}
- Context profile: `{metadata['context']} / {metadata['ctx_checkpoints']} / {metadata['checkpoint_every']}`
- Max generation tokens: `{metadata['max_tokens']}`

## Official Qwen profile source

The four benchmark profiles are taken from the official `Qwen3.5-122B-A10B` model card:

- Thinking mode for general tasks
- Thinking mode for precise coding tasks
- Instruct or non-thinking mode for general tasks
- Instruct or non-thinking mode for reasoning tasks

## Environment

- Timestamp (UTC): `{metadata['timestamp_utc']}`
- Host: `{metadata['host']}`
- Platform: `{metadata['platform']}`
- llama.cpp version: `{metadata['llama_version']}`

## Mean TTFT

{format_table(summary_rows, "ttft")}

## Mean Tokens / Second

{format_table(summary_rows, "tokens")}

## Notes

- TTFT is measured from the streaming request start until the first non-empty `content` or `reasoning_content` delta.
- Tokens per second is taken from the non-stream `timings.predicted_per_second` field for the same prompt/profile.
- Thinking profiles use `chat_template_kwargs.enable_thinking=true`; non-thinking profiles use `false`.
- Reports are generated from the raw JSON and CSV files in the same directory.
"""
    path.write_text(report)

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--cache-root", default=str(Path.home() / "Library/Caches/llama.cpp"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--context", type=int, default=262144)
    parser.add_argument("--ctx-checkpoints", type=int, default=64)
    parser.add_argument("--checkpoint-every", type=int, default=4096)
    parser.add_argument("--iterations", type=int, default=2)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--models", nargs="*", default=[model.slug for model in MODELS])
    parser.add_argument("--keep-model-cache", action="store_true")
    return parser.parse_args()

def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    scripts_dir = repo_root / "scripts"
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    cache_root = Path(args.cache_root)
    llama_repo = repo_root.parent / "llama.cpp-dev" / "llama.cpp"
    try:
        llama_version = run(["git", "-C", str(llama_repo), "rev-parse", "--short", "HEAD"]).stdout.strip()
    except Exception:
        llama_version = "unknown"

    selected_models = [model for model in MODELS if model.slug in set(args.models)]
    raw_rows: list[dict[str, Any]] = []
    resolved_models: list[dict[str, Any]] = []

    stop_server(scripts_dir)

    try:
        for model in selected_models:
            repo_id, model_path, files = ensure_model(cache_root, model)
            resolved_models.append(
                {
                    "model_slug": model.slug,
                    "model_label": model.label,
                    "repo_id": repo_id,
                    "first_file": str(model_path),
                    "files": files,
                }
            )

            print(f"\n== Benchmarking {model.label} ({repo_id}) ==")
            start_server(scripts_dir, model_path, args.context, args.ctx_checkpoints, args.checkpoint_every)
            try:
                for profile in PROFILES:
                    print(f"  -> {profile.label}")
                    rows = benchmark_profile(args.host, args.port, profile, args.iterations, args.max_tokens)
                    for row in rows:
                        row.update(
                            {
                                "model_slug": model.slug,
                                "model_label": model.label,
                                "repo_id": repo_id,
                                "profile_slug": profile.slug,
                                "profile_label": profile.label,
                                "enable_thinking": profile.enable_thinking,
                            }
                        )
                    raw_rows.extend(rows)
            finally:
                stop_server(scripts_dir)

            if not args.keep_model_cache and model.slug != "qwen3.5-122b-a10b":
                shutil.rmtree(repo_cache_dir(cache_root, repo_id), ignore_errors=True)
    finally:
        # Leave the validated 122B default live at the end.
        target = next((item for item in resolved_models if item["model_slug"] == "qwen3.5-122b-a10b"), None)
        if target is not None:
            start_server(
                scripts_dir,
                Path(target["first_file"]),
                args.context,
                args.ctx_checkpoints,
                args.checkpoint_every,
            )

    summary_rows = summarize(raw_rows)
    metadata = {
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": platform.node(),
        "platform": platform.platform(),
        "llama_version": llama_version,
        "context": args.context,
        "ctx_checkpoints": args.ctx_checkpoints,
        "checkpoint_every": args.checkpoint_every,
        "iterations": args.iterations,
        "max_tokens": args.max_tokens,
        "models": resolved_models,
    }

    write_json(output_dir / "system.json", metadata)
    write_json(output_dir / "raw-results.json", raw_rows)
    write_json(output_dir / "summary.json", summary_rows)
    write_csv(output_dir / "raw-results.csv", raw_rows)
    write_csv(output_dir / "summary.csv", summary_rows)
    write_report(output_dir / "report.md", summary_rows, metadata)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
