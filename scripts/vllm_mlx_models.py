#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class ModelSpec:
    alias: str
    family: str
    repo_id: str
    codex_model: str
    default_served_model_name: str
    default_max_tokens: int
    tool_call_parser: str | None
    reasoning_parser: str | None
    continuous_batching: bool
    benchmark_enabled: bool
    size_gb: float
    default: bool = False


MODEL_SPECS: tuple[ModelSpec, ...] = (
    ModelSpec("qwen3.5-0.8b", "qwen", "mlx-community/Qwen3.5-0.8B-MLX-8bit", "Qwen3.5-0.8B", "qwen", 32768, "qwen", "qwen3", True, True, 1.0),
    ModelSpec("qwen3.5-2b", "qwen", "mlx-community/Qwen3.5-2B-MLX-8bit", "Qwen3.5-2B", "qwen", 32768, "qwen", "qwen3", True, True, 2.5),
    ModelSpec("qwen3.5-4b", "qwen", "mlx-community/Qwen3.5-4B-MLX-8bit", "Qwen3.5-4B", "qwen", 32768, "qwen", "qwen3", True, True, 4.8),
    ModelSpec("qwen3.5-9b-4bit", "qwen", "mlx-community/Qwen3.5-9B-4bit", "Qwen3.5-9B-4bit", "qwen", 32768, "qwen", "qwen3", True, True, 5.6),
    ModelSpec("qwen3.5-9b", "qwen", "mlx-community/Qwen3.5-9B-MLX-8bit", "Qwen3.5-9B", "qwen", 32768, "qwen", "qwen3", True, True, 10.5),
    ModelSpec("qwen3.5-27b", "qwen", "mlx-community/Qwen3.5-27B-8bit", "Qwen3.5-27B", "qwen", 32768, "qwen", "qwen3", True, True, 31.0),
    ModelSpec("qwen3.5-35b-a3b", "qwen", "mlx-community/Qwen3.5-35B-A3B-8bit", "Qwen3.5-35B-A3B", "qwen", 32768, "qwen", "qwen3", True, True, 24.0, True),
    ModelSpec("qwen3.5-122b-a10b", "qwen", "mlx-community/Qwen3.5-122B-A10B-8bit", "Qwen3.5-122B-A10B", "qwen", 262144, "qwen3_coder", "qwen3", False, True, 82.0),
    ModelSpec("qwen3-coder-30b-a3b", "qwen-coder", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit", "Qwen3-Coder-30B-A3B-Instruct", "qwen", 32768, "qwen3_coder", "qwen3", True, True, 22.0),
    ModelSpec("qwen3-coder-next", "qwen-coder", "mlx-community/Qwen3-Coder-Next-8bit", "Qwen3-Coder-Next", "qwen", 262144, "qwen3_coder", "qwen3", True, True, 140.0),
    ModelSpec("gpt-oss-20b", "gpt-oss", "lmstudio-community/gpt-oss-20b-MLX-8bit", "GPT-OSS-20B", "qwen", 32768, "harmony", "gpt_oss", True, True, 13.0),
    ModelSpec("gpt-oss-120b", "gpt-oss", "lmstudio-community/gpt-oss-120b-MLX-8bit", "GPT-OSS-120B", "qwen", 32768, "harmony", "gpt_oss", True, True, 78.0),
    ModelSpec("nemotron-120b-a12b", "nemotron", "inferencerlabs/NVIDIA-Nemotron-3-Super-120B-A12B-MLX-9bit", "NVIDIA-Nemotron-3-Super-120B-A12B", "qwen", 32768, "nemotron", None, True, True, 95.0),
    ModelSpec("devstral-small-2-24b", "devstral", "mlx-community/Devstral-Small-2-24B-Instruct-2512-8bit", "Devstral-Small-2-24B-Instruct-2512", "qwen", 32768, "mistral", None, True, True, 18.0),
    ModelSpec("devstral-2-123b", "devstral", "mlx-community/Devstral-2-123B-Instruct-2512-8bit", "Devstral-2-123B-Instruct-2512", "qwen", 32768, "mistral", None, True, True, 88.0),
)

MODEL_BY_ALIAS = {model.alias: model for model in MODEL_SPECS}
MODEL_BY_CODEX = {model.codex_model: model for model in MODEL_SPECS}


def find_cli() -> str:
    for candidate in ("hf", "huggingface-cli"):
        path = shutil.which(candidate)
        if path:
            return path
    raise RuntimeError("missing hf or huggingface-cli in PATH")


def selected_models(mode: str, aliases: list[str]) -> list[ModelSpec]:
    if aliases:
        return [MODEL_BY_ALIAS[alias] for alias in aliases]
    if mode == "benchmark":
        return [model for model in MODEL_SPECS if model.benchmark_enabled]
    return list(MODEL_SPECS)


def inventory_records(mode: str, aliases: list[str]) -> list[dict]:
    models = sorted(selected_models(mode, aliases), key=lambda item: item.size_gb)
    return [asdict(model) for model in models]


def print_inventory(mode: str, aliases: list[str], json_output: bool) -> int:
    records = inventory_records(mode, aliases)
    if json_output:
        print(json.dumps(records, indent=2))
        return 0
    for record in records:
        flags: list[str] = []
        if record["default"]:
            flags.append("default")
        if record["benchmark_enabled"]:
            flags.append("benchmark")
        print(
            f"{record['alias']}: {record['repo_id']} "
            f"[{' '.join(flags) or 'cache-only'}] size≈{record['size_gb']:.1f}GB"
        )
    return 0


def prefetch(mode: str, aliases: list[str]) -> int:
    cli = find_cli()
    for model in selected_models(mode, aliases):
        print(f"prefetching {model.alias} -> {model.repo_id}")
        result = subprocess.run([cli, "download", model.repo_id], text=True)
        if result.returncode != 0:
            return result.returncode
    return 0


def resolve(alias: str, field: str | None, json_output: bool) -> int:
    record = asdict(MODEL_BY_ALIAS[alias])
    if field:
        value = record.get(field, "")
        if isinstance(value, bool):
            print("true" if value else "false")
        elif value is None:
            print("")
        else:
            print(value)
        return 0
    if json_output:
        print(json.dumps(record, indent=2))
    else:
        print(record["repo_id"])
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    inventory_parser = sub.add_parser("inventory")
    inventory_parser.add_argument("--mode", default="all", choices=("all", "benchmark"))
    inventory_parser.add_argument("--json", action="store_true")
    inventory_parser.add_argument("aliases", nargs="*")

    prefetch_parser = sub.add_parser("prefetch")
    prefetch_parser.add_argument("--mode", default="benchmark", choices=("all", "benchmark"))
    prefetch_parser.add_argument("aliases", nargs="*")

    resolve_parser = sub.add_parser("resolve")
    resolve_parser.add_argument("alias")
    resolve_parser.add_argument("--field")
    resolve_parser.add_argument("--json", action="store_true")

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "inventory":
        return print_inventory(args.mode, args.aliases, args.json)
    if args.command == "prefetch":
        return prefetch(args.mode, args.aliases)
    if args.command == "resolve":
        return resolve(args.alias, args.field, args.json)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
