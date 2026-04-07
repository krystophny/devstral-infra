#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import http.client
import json
import os
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO_ROOT / "scripts"

SYSTEM_PROMPT_NO_THINKING = (
    "You are benchmarking a local inference server. "
    "Respond concisely and do not include chain-of-thought."
)
SYSTEM_PROMPT_THINKING = (
    "You are benchmarking a local inference server. "
    "Think carefully and then answer concisely."
)
SHORT_PROMPT = (
    "Summarize what a local LLM benchmark should report in exactly three bullets. "
    "Keep each bullet short."
)
LONG_PROMPT_CHUNK = (
    "Repository audit context: benchmark TTFT, prefill throughput, sustained decode throughput, "
    "and end-to-end latency for local OpenAI-compatible servers on Apple Silicon. "
    "Track consistent prompt formatting, stable sampling, and token usage. "
)


@dataclass(frozen=True)
class StackSpec:
    slug: str
    label: str
    port: int
    start_script: str
    stop_script: str
    env: dict[str, str]
    start_args: tuple[str, ...] = ()
    stop_args: tuple[str, ...] = ()
    expected_model: str | None = None


@dataclass(frozen=True)
class ScenarioSpec:
    slug: str
    prompt: str


@dataclass(frozen=True)
class SystemInfo:
    platform: str
    gpu: str
    gpu_count: int
    ram_mb: int
    vram_mb: int


def build_long_prompt(repeats: int) -> str:
    return LONG_PROMPT_CHUNK * repeats + "Return four short bullets and nothing else."


def check_output(cmd: list[str], env: dict[str, str] | None = None) -> str:
    result = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        env=env,
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout


def iteration_prompt(prompt: str, iteration: int) -> str:
    return f"Benchmark iteration marker: {iteration}.\n\n{prompt}"


def run(cmd: list[str], env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        env=env,
        check=check,
        text=True,
        capture_output=True,
    )


def resolve_model_path(key: str) -> str:
    return check_output([sys.executable, str(SCRIPTS_DIR / "benchmark_model_paths.py"), "resolve", key]).strip()


def collect_system_info() -> SystemInfo:
    output = check_output(["bash", str(SCRIPTS_DIR / "detect_hardware.sh")])
    values: dict[str, str] = {}
    for line in output.splitlines():
        if line.startswith("platform: "):
            values["platform"] = line.split(": ", 1)[1]
        elif line.startswith("gpu: "):
            values["gpu"] = line.split(": ", 1)[1]
        elif line.startswith("gpu_count: "):
            values["gpu_count"] = line.split(": ", 1)[1]
        elif line.startswith("vram_mb: "):
            values["vram_mb"] = line.split(": ", 1)[1]
        elif line.startswith("ram_mb: "):
            values["ram_mb"] = line.split(": ", 1)[1]
    return SystemInfo(
        platform=values.get("platform", "unknown"),
        gpu=values.get("gpu", "unknown"),
        gpu_count=int(values.get("gpu_count", "0")),
        ram_mb=int(values.get("ram_mb", "0")),
        vram_mb=int(values.get("vram_mb", "0")),
    )


def build_stacks(thinking_enabled: bool) -> list[StackSpec]:
    gguf_path = resolve_model_path("gguf-qwen3.5-9b-q4")
    mlx_path = resolve_model_path("mlx-qwen3.5-9b-4bit")
    common_no_smoke = {"LLAMACPP_SMOKE_TEST": "false", "VLLM_MLX_SMOKE_TEST": "false", "MLX_LM_SMOKE_TEST": "false", "VLLM_METAL_SMOKE_TEST": "false", "OMLX_SMOKE_TEST": "false"}
    thinking_value = "true" if thinking_enabled else "false"

    return [
        StackSpec(
            slug="llamacpp",
            label="llama.cpp",
            port=8090,
            start_script="server_start_llamacpp.sh",
            stop_script="server_stop_llamacpp.sh",
            start_args=("local",),
            stop_args=("local",),
            expected_model="qwen",
            env={
                **common_no_smoke,
                "DEVSTRAL_HOST": "127.0.0.1",
                "DEVSTRAL_PORT": "8090",
                "LLAMACPP_MODEL": gguf_path,
                "LLAMACPP_MODEL_ALIAS": "qwen3.5-9b-q4",
                "LLAMACPP_BATCH": "2048",
                "LLAMACPP_UBATCH": "2048",
                "LLAMACPP_ENABLE_THINKING": thinking_value,
            },
        ),
        StackSpec(
            slug="mlx-lm",
            label="mlx-lm",
            port=8091,
            start_script="server_start_mlx_lm.sh",
            stop_script="server_stop_mlx_lm.sh",
            env={
                **common_no_smoke,
                "DEVSTRAL_HOST": "127.0.0.1",
                "DEVSTRAL_PORT": "8091",
                "MLX_LM_MODEL": mlx_path,
                "MLX_LM_MAX_TOKENS": "32768",
                "MLX_LM_DECODE_CONCURRENCY": "2",
                "MLX_LM_PROMPT_CONCURRENCY": "2",
                "MLX_LM_PREFILL_STEP_SIZE": "4096",
                "MLX_LM_PROMPT_CACHE_SIZE": "32",
                "MLX_LM_PROMPT_CACHE_BYTES": "8GB",
            },
        ),
        StackSpec(
            slug="vllm-mlx",
            label="vllm-mlx",
            port=8092,
            start_script="server_start_vllm_mlx.sh",
            stop_script="server_stop_vllm_mlx.sh",
            start_args=("local",),
            stop_args=("local",),
            expected_model="qwen",
            env={
                **common_no_smoke,
                "DEVSTRAL_HOST": "127.0.0.1",
                "DEVSTRAL_HEALTHCHECK_HOST": "127.0.0.1",
                "DEVSTRAL_PORT": "8092",
                "VLLM_MLX_MODEL_ALIAS": "qwen3.5-9b-4bit",
                "VLLM_MLX_CONTINUOUS_BATCHING": "false",
                "VLLM_MLX_MAX_NUM_SEQS": "2",
                "VLLM_MLX_PREFILL_BATCH_SIZE": "2",
                "VLLM_MLX_COMPLETION_BATCH_SIZE": "2",
                "VLLM_MLX_STREAM_INTERVAL": "1",
                "VLLM_MLX_PREFILL_STEP_SIZE": "4096",
                "VLLM_MLX_CHUNKED_PREFILL_TOKENS": "0",
                "VLLM_MLX_ENABLE_PREFIX_CACHE": "true",
                "VLLM_MLX_ENABLE_THINKING": thinking_value,
            },
        ),
        StackSpec(
            slug="vllm-metal",
            label="vllm-metal",
            port=8093,
            start_script="server_start_vllm_metal.sh",
            stop_script="server_stop_vllm_metal.sh",
            env={
                **common_no_smoke,
                "DEVSTRAL_HOST": "127.0.0.1",
                "DEVSTRAL_PORT": "8093",
                "VLLM_METAL_MODEL": "mlx-community/Qwen3.5-9B-4bit",
            },
        ),
        StackSpec(
            slug="omlx",
            label="oMLX",
            port=8094,
            start_script="server_start_omlx.sh",
            stop_script="server_stop_omlx.sh",
            env={
                **common_no_smoke,
                "DEVSTRAL_HOST": "127.0.0.1",
                "DEVSTRAL_PORT": "8094",
                "OMLX_MODEL_PATH": mlx_path,
                "OMLX_MODEL_ID": "qwen3.5-9b-4bit",
                "OMLX_MAX_NUM_SEQS": "2",
                "OMLX_COMPLETION_BATCH_SIZE": "2",
                "OMLX_HOT_CACHE_MAX_SIZE": "4GB",
                "OMLX_INITIAL_CACHE_BLOCKS": "1024",
            },
            expected_model="qwen3.5-9b-4bit",
        ),
    ]


def list_models(host: str, port: int) -> list[str]:
    conn = http.client.HTTPConnection(host, port, timeout=60)
    conn.request("GET", "/v1/models")
    response = conn.getresponse()
    payload = response.read()
    conn.close()
    if response.status != 200:
        raise RuntimeError(f"/v1/models returned {response.status}: {payload.decode(errors='replace')}")
    data = json.loads(payload)
    return [item["id"] for item in data.get("data", []) if "id" in item]


def pick_model(host: str, port: int, preferred: str | None) -> str:
    models = list_models(host, port)
    if not models:
        raise RuntimeError("server returned no models")
    if preferred and preferred in models:
        return preferred
    return models[0]


def payload(model: str, prompt: str, max_tokens: int, stream: bool, thinking_enabled: bool) -> dict[str, Any]:
    data = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": SYSTEM_PROMPT_THINKING if thinking_enabled else SYSTEM_PROMPT_NO_THINKING,
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.0,
        "max_tokens": max_tokens,
        "stream": stream,
        "chat_template_kwargs": {"enable_thinking": thinking_enabled},
    }
    if stream:
        data["stream_options"] = {"include_usage": True}
    return data


def _delta_has_token(delta: dict[str, Any]) -> bool:
    for field in ("content", "reasoning", "reasoning_content"):
        value = delta.get(field)
        if isinstance(value, str) and value != "":
            return True
    tool_calls = delta.get("tool_calls")
    return isinstance(tool_calls, list) and len(tool_calls) > 0


def _parse_stream_json_line(line: str) -> dict[str, Any] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith(":"):
        return None
    if stripped.startswith("data: "):
        return json.loads(stripped[6:])
    if all(ch in "0123456789abcdefABCDEF" for ch in stripped):
        return None
    if stripped.startswith("{"):
        return json.loads(stripped)
    return None


def _is_transient_http_error(exc: BaseException) -> bool:
    return isinstance(
        exc,
        (
            http.client.RemoteDisconnected,
            ConnectionResetError,
            BrokenPipeError,
            TimeoutError,
        ),
    )


def stream_completion(host: str, port: int, model: str, prompt: str, max_tokens: int, thinking_enabled: bool) -> tuple[float, float, dict[str, Any]]:
    body = json.dumps(payload(model, prompt, max_tokens, True, thinking_enabled))
    last_error: BaseException | None = None
    for attempt in range(2):
        conn = http.client.HTTPConnection(host, port, timeout=600)
        start = time.perf_counter()
        try:
            conn.request("POST", "/v1/chat/completions", body=body, headers={"Content-Type": "application/json"})
            response = conn.getresponse()
            content_type = response.getheader("Content-Type", "")
            if response.status != 200:
                data = response.read().decode(errors="replace")
                raise RuntimeError(f"stream request failed with {response.status}: {data}")

            if "text/event-stream" not in content_type:
                raw = response.read()
                elapsed = time.perf_counter() - start
                data = json.loads(raw)
                return elapsed, elapsed, data

            ttft = None
            usage: dict[str, Any] = {}
            done_elapsed = None
            while True:
                raw_line = response.fp.readline()
                if not raw_line:
                    break
                line = raw_line.decode("utf-8", errors="replace").strip()
                if line == "data: [DONE]" or line == "[DONE]":
                    done_elapsed = time.perf_counter() - start
                    break
                parsed = _parse_stream_json_line(line)
                if parsed is None:
                    continue
                if parsed.get("usage"):
                    usage = parsed["usage"]
                choices = parsed.get("choices", [])
                if choices:
                    delta = choices[0].get("delta", {})
                    if ttft is None and _delta_has_token(delta):
                        ttft = time.perf_counter() - start
            elapsed = done_elapsed if done_elapsed is not None else (time.perf_counter() - start)
            if ttft is None:
                ttft = elapsed
            return ttft, elapsed, {"usage": usage}
        except BaseException as exc:
            conn.close()
            if attempt == 1 or not _is_transient_http_error(exc):
                raise
            last_error = exc
            time.sleep(0.25)
        finally:
            try:
                conn.close()
            except Exception:
                pass
    if last_error is not None:
        raise last_error
    raise RuntimeError("stream request failed without an explicit error")


def completion(host: str, port: int, model: str, prompt: str, max_tokens: int, thinking_enabled: bool) -> tuple[float, dict[str, Any]]:
    body = json.dumps(payload(model, prompt, max_tokens, False, thinking_enabled))
    last_error: BaseException | None = None
    for attempt in range(2):
        conn = http.client.HTTPConnection(host, port, timeout=600)
        start = time.perf_counter()
        try:
            conn.request("POST", "/v1/chat/completions", body=body, headers={"Content-Type": "application/json"})
            response = conn.getresponse()
            data = response.read()
            elapsed = time.perf_counter() - start
            if response.status != 200:
                raise RuntimeError(f"completion request failed with {response.status}: {data.decode(errors='replace')}")
            return elapsed, json.loads(data)
        except BaseException as exc:
            conn.close()
            if attempt == 1 or not _is_transient_http_error(exc):
                raise
            last_error = exc
            time.sleep(0.25)
        finally:
            try:
                conn.close()
            except Exception:
                pass
    if last_error is not None:
        raise last_error
    raise RuntimeError("completion request failed without an explicit error")


def parallel_completion(
    host: str,
    port: int,
    model: str,
    prompt: str,
    max_tokens: int,
    concurrency: int,
    thinking_enabled: bool,
) -> dict[str, float | int | None]:
    start = time.perf_counter()
    latencies: list[float] = []
    prompt_tokens = 0
    completion_tokens = 0

    def worker() -> tuple[float, dict[str, Any]]:
        return completion(host, port, model, prompt, max_tokens, thinking_enabled)

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(worker) for _ in range(concurrency)]
        for future in as_completed(futures):
            elapsed, data = future.result()
            latencies.append(elapsed)
            usage = data.get("usage", {})
            prompt_tokens += int(usage.get("prompt_tokens") or 0)
            completion_tokens += int(usage.get("completion_tokens") or 0)

    wall = time.perf_counter() - start
    return {
        "parallel_requests": concurrency,
        "parallel_wall_ms": wall * 1000.0,
        "parallel_mean_latency_ms": statistics.mean(latencies) * 1000.0 if latencies else None,
        "parallel_request_throughput_rps": concurrency / wall if wall > 0 else None,
        "parallel_prompt_tokens": prompt_tokens,
        "parallel_completion_tokens": completion_tokens,
        "parallel_prompt_tokens_per_s": prompt_tokens / wall if wall > 0 else None,
        "parallel_completion_tokens_per_s": completion_tokens / wall if wall > 0 else None,
    }


def summarize_record(stack: StackSpec, scenario: ScenarioSpec, iteration: int, model: str, ttft: float, elapsed: float, data: dict[str, Any]) -> dict[str, Any]:
    usage = data.get("usage", {})
    prompt_tokens = int(usage.get("prompt_tokens") or 0)
    completion_tokens = int(usage.get("completion_tokens") or 0)
    e2e_ms = elapsed * 1000.0
    ttft_ms = ttft * 1000.0
    effective_prefill_tps = (prompt_tokens / ttft) if prompt_tokens and ttft > 0 else None

    tpot_ms = None
    decode_tps = None
    if completion_tokens > 1 and elapsed > ttft:
        decode_window = elapsed - ttft
        tpot_ms = (decode_window / (completion_tokens - 1)) * 1000.0
        decode_tps = (completion_tokens - 1) / decode_window if decode_window > 0 else None

    return {
        "stack": stack.slug,
        "scenario": scenario.slug,
        "iteration": iteration,
        "model": model,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "ttft_ms": ttft_ms,
        "e2e_ms": e2e_ms,
        "prefill_tokens_per_s": effective_prefill_tps,
        "tpot_ms": tpot_ms,
        "decode_tokens_per_s": decode_tps,
        "total_completion_tokens_per_s": (completion_tokens / elapsed) if completion_tokens and elapsed > 0 else None,
    }


def aggregate(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for record in records:
        grouped.setdefault((record["stack"], record["scenario"]), []).append(record)
    rows = []
    for (stack, scenario), group in sorted(grouped.items()):
        row: dict[str, Any] = {"stack": stack, "scenario": scenario, "runs": len(group)}
        for field in (
            "prompt_tokens",
            "completion_tokens",
            "ttft_ms",
            "e2e_ms",
            "prefill_tokens_per_s",
            "tpot_ms",
            "decode_tokens_per_s",
            "total_completion_tokens_per_s",
        ):
            values = [item[field] for item in group if item[field] is not None]
            row[field] = statistics.mean(values) if values else None
        rows.append(row)
    return rows


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        path.write_text("")
        return
    fields = list(rows[0])
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def render_summary(
    system_info: SystemInfo,
    stacks: list[StackSpec],
    summary_rows: list[dict[str, Any]],
    parallel_rows: list[dict[str, Any]],
    failures: list[dict[str, str]],
    thinking_enabled: bool,
) -> str:
    lines = ["# Local Stack Benchmark", ""]
    lines.append("## System")
    lines.append(f"- platform: `{system_info.platform}`")
    lines.append(f"- gpu: `{system_info.gpu}` x `{system_info.gpu_count}`")
    lines.append(f"- RAM: `{system_info.ram_mb} MB`")
    lines.append(f"- VRAM: `{system_info.vram_mb} MB`")
    lines.append(f"- thinking: `{'on' if thinking_enabled else 'off'}`")
    lines.append("")
    lines.append("## Stacks")
    for stack in stacks:
        lines.append(f"- `{stack.slug}` on port `{stack.port}`")
    lines.append("")
    lines.append("## Single Request")
    lines.append("| stack | scenario | TTFT ms | prefill tok/s | TPOT ms | decode tok/s | e2e ms |")
    lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: |")
    for row in summary_rows:
        lines.append(
            f"| {row['stack']} | {row['scenario']} | {format_num(row['ttft_ms'])} | "
            f"{format_num(row['prefill_tokens_per_s'])} | {format_num(row['tpot_ms'])} | "
            f"{format_num(row['decode_tokens_per_s'])} | {format_num(row['e2e_ms'])} |"
        )
    lines.append("")
    lines.append("## Parallel Throughput")
    lines.append("| stack | requests | wall ms | req/s | prompt tok/s | completion tok/s |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
    for row in parallel_rows:
        lines.append(
            f"| {row['stack']} | {row['parallel_requests']} | {format_num(row['parallel_wall_ms'])} | "
            f"{format_num(row['parallel_request_throughput_rps'])} | {format_num(row['parallel_prompt_tokens_per_s'])} | "
            f"{format_num(row['parallel_completion_tokens_per_s'])} |"
        )
    if failures:
        lines.append("")
        lines.append("## Failures")
        for failure in failures:
            lines.append(f"- `{failure['stack']}`: {failure['error']}")
    lines.append("")
    if thinking_enabled:
        lines.append("Completion-token metrics include reasoning tokens when the runtime emits them.")
    lines.append("Metrics follow the same practical split used by current serving benchmarks: `TTFT`, decode-side token latency/throughput, and prompt-side throughput.")
    return "\n".join(lines)


def format_num(value: float | int | None) -> str:
    if value is None:
        return "-"
    if isinstance(value, int):
        return str(value)
    return f"{value:.2f}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--iterations", type=int, default=2)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--parallel-requests", type=int, default=4)
    parser.add_argument("--long-prompt-repeats", type=int, default=256)
    parser.add_argument("--stacks", nargs="*", default=["llamacpp", "mlx-lm", "vllm-mlx", "vllm-metal", "omlx"])
    parser.add_argument("--thinking", choices=("on", "off"), default="off")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    selected = set(args.stacks)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    thinking_enabled = args.thinking == "on"
    system_info = collect_system_info()

    stacks = [stack for stack in build_stacks(thinking_enabled) if stack.slug in selected]
    scenarios = [
        ScenarioSpec(slug="short", prompt=SHORT_PROMPT),
        ScenarioSpec(slug="long", prompt=build_long_prompt(args.long_prompt_repeats)),
    ]

    if args.dry_run:
        print(json.dumps({
            "output_dir": str(output_dir),
            "stacks": [asdict(stack) for stack in stacks],
            "scenarios": [asdict(scenario) for scenario in scenarios],
        }, indent=2))
        return 0

    raw_rows: list[dict[str, Any]] = []
    parallel_rows: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []

    for stack in stacks:
        merged_env = os.environ.copy()
        merged_env.update(stack.env)
        start_cmd = ["bash", str(SCRIPTS_DIR / stack.start_script), *stack.start_args]
        stop_cmd = ["bash", str(SCRIPTS_DIR / stack.stop_script), *stack.stop_args]
        run(stop_cmd, env=merged_env, check=False)
        try:
            start = run(start_cmd, env=merged_env)
            sys.stdout.write(start.stdout)
            sys.stderr.write(start.stderr)
            model = pick_model("127.0.0.1", stack.port, stack.expected_model)
            completion("127.0.0.1", stack.port, model, SHORT_PROMPT, min(args.max_tokens, 16), thinking_enabled)
            for scenario in scenarios:
                for iteration in range(1, args.iterations + 1):
                    prompt = iteration_prompt(scenario.prompt, iteration)
                    ttft, elapsed, data = stream_completion("127.0.0.1", stack.port, model, prompt, args.max_tokens, thinking_enabled)
                    raw_rows.append(summarize_record(stack, scenario, iteration, model, ttft, elapsed, data))
            parallel = parallel_completion("127.0.0.1", stack.port, model, SHORT_PROMPT, args.max_tokens, args.parallel_requests, thinking_enabled)
            parallel["stack"] = stack.slug
            parallel_rows.append(parallel)
        except Exception as exc:
            failures.append({"stack": stack.slug, "error": str(exc)})
        finally:
            stop = run(stop_cmd, env=merged_env, check=False)
            sys.stdout.write(stop.stdout)
            sys.stderr.write(stop.stderr)

    summary_rows = aggregate(raw_rows)
    summary = render_summary(system_info, stacks, summary_rows, parallel_rows, failures, thinking_enabled)

    (output_dir / "summary.md").write_text(summary)
    (output_dir / "raw.json").write_text(json.dumps(raw_rows, indent=2))
    (output_dir / "summary.json").write_text(json.dumps(summary_rows, indent=2))
    (output_dir / "parallel.json").write_text(json.dumps(parallel_rows, indent=2))
    (output_dir / "failures.json").write_text(json.dumps(failures, indent=2))
    write_csv(output_dir / "raw.csv", raw_rows)
    write_csv(output_dir / "summary.csv", summary_rows)
    write_csv(output_dir / "parallel.csv", parallel_rows)

    print(summary)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
