#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


HOME = Path.home()


@dataclass(frozen=True)
class ModelPathSpec:
    key: str
    kind: str
    description: str
    env_var: str
    candidates: tuple[str, ...]


MODEL_SPECS: tuple[ModelPathSpec, ...] = (
    ModelPathSpec(
        key="gguf-qwen3.5-9b-q4",
        kind="gguf",
        description="Qwen3.5-9B Q4_K_M GGUF for llama.cpp",
        env_var="BENCHMARK_GGUF_MODEL",
        candidates=(
            "~/.lmstudio/models/lmstudio-community/Qwen3.5-9B-GGUF/Qwen3.5-9B-Q4_K_M.gguf",
            "~/Library/Caches/llama.cpp/lmstudio-community_Qwen3.5-9B-GGUF/**/*.gguf",
        ),
    ),
    ModelPathSpec(
        key="mlx-qwen3.5-9b-4bit",
        kind="mlx",
        description="Qwen3.5-9B 4bit MLX snapshot for mlx-lm, vllm-mlx, vllm-metal, and omlx",
        env_var="BENCHMARK_MLX_MODEL",
        candidates=(
            "~/.cache/huggingface/hub/models--mlx-community--Qwen3.5-9B-4bit/snapshots/*",
            "~/.lmstudio/models/mlx-community/Qwen3.5-9B-4bit",
        ),
    ),
)

MODEL_BY_KEY = {spec.key: spec for spec in MODEL_SPECS}


def existing_path(path: Path, kind: str) -> bool:
    if kind == "gguf":
        return path.is_file() and path.suffix == ".gguf"
    return path.is_dir() and (path / "config.json").is_file()


def resolve_candidate(pattern: str, kind: str) -> Path | None:
    expanded = Path(pattern).expanduser()
    base = expanded.anchor if expanded.anchor else "."
    root = Path(base)
    parts = expanded.parts[len(root.parts):]
    if not parts:
        return expanded if existing_path(expanded, kind) else None
    matches = sorted(root.glob(str(Path(*parts))))
    for match in matches:
        if existing_path(match, kind):
            return match
    return None


def resolve_model(spec: ModelPathSpec) -> Path | None:
    raw_override = os.environ.get(spec.env_var)
    if raw_override:
        override_path = Path(raw_override).expanduser()
        if existing_path(override_path, spec.kind):
            return override_path
    for candidate in spec.candidates:
        resolved = resolve_candidate(candidate, spec.kind)
        if resolved:
            return resolved
    return None


def inventory(json_output: bool) -> int:
    records = []
    for spec in MODEL_SPECS:
        resolved = resolve_model(spec)
        record = asdict(spec)
        record["resolved_path"] = str(resolved) if resolved else ""
        record["present"] = resolved is not None
        records.append(record)
    if json_output:
        print(json.dumps(records, indent=2))
    else:
        for record in records:
            state = "present" if record["present"] else "missing"
            print(f"{record['key']}: {state}")
            print(f"  kind: {record['kind']}")
            print(f"  path: {record['resolved_path'] or '-'}")
    return 0


def resolve(key: str) -> int:
    spec = MODEL_BY_KEY[key]
    resolved = resolve_model(spec)
    if resolved is None:
        return 1
    print(resolved)
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    inventory_parser = sub.add_parser("inventory")
    inventory_parser.add_argument("--json", action="store_true")

    resolve_parser = sub.add_parser("resolve")
    resolve_parser.add_argument("key", choices=sorted(MODEL_BY_KEY))

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "inventory":
        return inventory(args.json)
    if args.command == "resolve":
        return resolve(args.key)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
