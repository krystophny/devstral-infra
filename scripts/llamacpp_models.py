#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

def default_agai_root() -> str:
    if sys.platform.startswith("linux") and Path("/temp/AG-AI").exists():
        return "/temp/AG-AI"
    return ""

def cache_root() -> Path:
    explicit = os.environ.get("LLAMACPP_CACHE_ROOT", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    agai_root = os.environ.get("AGAI_ROOT", "").strip() or default_agai_root()
    if agai_root:
        return Path(agai_root) / "data" / "devstral" / "llama.cpp" / "models"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "llama.cpp"
    return Path.home() / ".cache" / "llama.cpp"

CACHE_ROOT = cache_root()

@dataclass(frozen=True)
class ModelSpec:
    alias: str
    family: str
    repo_id: str
    include: tuple[str, ...]
    benchmark_enabled: bool
    default: bool = False

    @property
    def cache_dir(self) -> Path:
        return CACHE_ROOT / self.repo_id.replace("/", "_")

MODEL_SPECS: tuple[ModelSpec, ...] = (
    ModelSpec("qwen3.5-0.8b", "qwen", "lmstudio-community/Qwen3.5-0.8B-GGUF", ("*Q8_0*.gguf",), True),
    ModelSpec("qwen3.5-2b", "qwen", "lmstudio-community/Qwen3.5-2B-GGUF", ("*Q8_0*.gguf",), True),
    ModelSpec("qwen3.5-4b", "qwen", "lmstudio-community/Qwen3.5-4B-GGUF", ("*Q8_0*.gguf",), True),
    ModelSpec("qwen3.5-9b", "qwen", "lmstudio-community/Qwen3.5-9B-GGUF", ("*Q8_0*.gguf",), True),
    ModelSpec("qwen3.5-27b", "qwen", "lmstudio-community/Qwen3.5-27B-GGUF", ("*Q8_0*.gguf",), True),
    ModelSpec("qwen3.5-27b-q4km", "qwen", "lmstudio-community/Qwen3.5-27B-GGUF", ("*Q4_K_M*.gguf",), True),
    ModelSpec("qwen3.5-35b-a3b", "qwen", "lmstudio-community/Qwen3.5-35B-A3B-GGUF", ("*Q8_0*.gguf",), True, True),
    ModelSpec("qwen3.5-35b-a3b-q4km", "qwen", "unsloth/Qwen3.5-35B-A3B-GGUF", ("*Q4_K_M*.gguf",), True),
    ModelSpec("qwen3.5-122b-a10b", "qwen", "lmstudio-community/Qwen3.5-122B-A10B-GGUF", ("*Q8_0*.gguf",), True),
    ModelSpec("gpt-oss-20b", "gpt-oss", "ggml-org/gpt-oss-20b-GGUF", ("*mxfp4*.gguf",), True),
    ModelSpec("gpt-oss-120b", "gpt-oss", "ggml-org/gpt-oss-120b-GGUF", ("*mxfp4*.gguf",), True),
    ModelSpec("nemotron-120b-a12b", "nemotron", "lmstudio-community/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF", ("*Q8_0*.gguf",), True),
    ModelSpec("qwen3-coder-next", "qwen", "lmstudio-community/Qwen3-Coder-Next-GGUF", ("*Q8_0*.gguf",), True),
    ModelSpec("qwen3-coder-30b-a3b", "qwen", "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF", ("*Q8_0*.gguf",), True),
    ModelSpec("qwen3-coder-30b-a3b-q4km", "qwen", "Qwen/Qwen3-Coder-30B-Instruct-GGUF", ("*Q4_K_M*.gguf",), True),
    ModelSpec("devstral-small-2-24b", "devstral", "lmstudio-community/Devstral-Small-2-24B-Instruct-2512-GGUF", ("*Q8_0*.gguf",), True),
    ModelSpec("devstral-small-2-24b-q4km", "devstral", "mistralai/Devstral-Small-2-24B-Instruct-GGUF", ("*Q4_K_M*.gguf",), True),
    ModelSpec("devstral-2-123b", "devstral", "lmstudio-community/Devstral-2-123B-Instruct-2512-GGUF", ("*Q8_0*.gguf",), True),
)

MODEL_BY_ALIAS = {model.alias: model for model in MODEL_SPECS}
KEEP_DIRS = {"gguf-headers"}
AGAI_SUPPORTED_ALIASES = (
    "qwen3.5-0.8b",
    "qwen3.5-2b",
    "qwen3.5-4b",
    "qwen3.5-9b",
    "gpt-oss-20b",
    "devstral-small-2-24b-q4km",
    "qwen3.5-27b-q4km",
    "qwen3-coder-30b-a3b-q4km",
    "qwen3.5-35b-a3b-q4km",
)

def find_cli() -> str:
    for candidate in ("hf", "huggingface-cli"):
        path = shutil.which(candidate)
        if path:
            return path
    raise RuntimeError("missing huggingface-cli or hf in PATH")

def selected_models(mode: str, aliases: list[str]) -> list[ModelSpec]:
    if aliases:
        return [MODEL_BY_ALIAS[alias] for alias in aliases]
    if mode == "benchmark":
        return [model for model in MODEL_SPECS if model.benchmark_enabled]
    if mode == "agai":
        return [MODEL_BY_ALIAS[alias] for alias in AGAI_SUPPORTED_ALIASES]
    if mode == "qwen":
        return [model for model in MODEL_SPECS if model.family == "qwen"]
    if mode == "gpt-oss":
        return [model for model in MODEL_SPECS if model.family == "gpt-oss"]
    return list(MODEL_SPECS)

def matching_files(model: ModelSpec) -> list[Path]:
    files: list[Path] = []
    if model.cache_dir.exists():
        for path in sorted(model.cache_dir.rglob("*.gguf")):
            rel = path.relative_to(model.cache_dir).as_posix()
            if any(fnmatch.fnmatch(rel, pattern) or fnmatch.fnmatch(path.name, pattern) for pattern in model.include):
                files.append(path)
    flat_prefix = model.repo_id.replace("/", "_") + "_"
    for path in sorted(CACHE_ROOT.glob(f"{flat_prefix}*.gguf")):
        if any(fnmatch.fnmatch(path.name, f"{flat_prefix}{pattern}") or fnmatch.fnmatch(path.name, pattern) for pattern in model.include):
            files.append(path)
    return files

def to_inventory_record(model: ModelSpec) -> dict:
    files = matching_files(model)
    return {
        "alias": model.alias,
        "family": model.family,
        "repo_id": model.repo_id,
        "benchmark_enabled": model.benchmark_enabled,
        "default": model.default,
        "cache_dir": str(model.cache_dir),
        "present": bool(files),
        "files": [str(path) for path in files],
        "size_bytes": sum(path.stat().st_size for path in files),
        "primary_path": str(files[0]) if files else "",
    }

def print_inventory(mode: str, aliases: list[str], json_output: bool) -> int:
    records = [to_inventory_record(model) for model in selected_models(mode, aliases)]
    if json_output:
        print(json.dumps(records, indent=2))
        return 0
    for record in records:
        size_gb = record["size_bytes"] / (1024 ** 3)
        status = "present" if record["present"] else "missing"
        flags = []
        if record["default"]:
            flags.append("default")
        if record["benchmark_enabled"]:
            flags.append("benchmark")
        print(f"{record['alias']}: {status} ({size_gb:.1f} GiB) [{' '.join(flags) or 'cache-only'}]")
        print(f"  repo: {record['repo_id']}")
        if record["primary_path"]:
            print(f"  path: {record['primary_path']}")
    return 0

def download_model(model: ModelSpec) -> int:
    files = matching_files(model)
    if files:
        print(f"{model.alias}: already present")
        return 0
    cli = find_cli()
    command = [
        cli,
        "download",
        model.repo_id,
        "--local-dir",
        str(model.cache_dir),
    ]
    for pattern in model.include:
        command.extend(["--include", pattern])
    print(f"downloading {model.alias} from {model.repo_id}")
    proc = subprocess.run(command, text=True)
    return proc.returncode

def prefetch(mode: str, aliases: list[str]) -> int:
    rc = 0
    for model in selected_models(mode, aliases):
        result = download_model(model)
        if result != 0:
            rc = result
            print(f"failed to download {model.alias}", file=sys.stderr)
            break
    return rc

def cleanup() -> int:
    keep_files = {path.resolve() for model in MODEL_SPECS for path in matching_files(model)}
    removed = 0
    if not CACHE_ROOT.exists():
        return 0
    for path in sorted(CACHE_ROOT.iterdir()):
        if path.name in KEEP_DIRS:
            continue
        if path.is_dir():
            if path.resolve() in {model.cache_dir.resolve() for model in MODEL_SPECS}:
                for child in sorted(path.rglob("*"), reverse=True):
                    if child.is_file() and child.resolve() not in keep_files:
                        child.unlink()
                        removed += 1
                for child in sorted(path.rglob("*"), reverse=True):
                    if child.is_dir():
                        try:
                            child.rmdir()
                        except OSError:
                            pass
                try:
                    path.rmdir()
                except OSError:
                    pass
            else:
                shutil.rmtree(path)
                removed += 1
        elif path.is_file():
            path.unlink()
            removed += 1
    print(f"cleanup removed {removed} non-standard cache entries")
    return 0

def resolve(alias: str, json_output: bool) -> int:
    model = MODEL_BY_ALIAS[alias]
    record = to_inventory_record(model)
    if json_output:
        print(json.dumps(record, indent=2))
    else:
        print(record["primary_path"])
    return 0 if record["present"] else 1

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    inventory_parser = sub.add_parser("inventory")
    inventory_parser.add_argument("--mode", default="all", choices=("all", "benchmark", "agai", "qwen", "gpt-oss"))
    inventory_parser.add_argument("--json", action="store_true")
    inventory_parser.add_argument("aliases", nargs="*")

    prefetch_parser = sub.add_parser("prefetch")
    prefetch_parser.add_argument("--mode", default="benchmark", choices=("all", "benchmark", "agai", "qwen", "gpt-oss"))
    prefetch_parser.add_argument("aliases", nargs="*")

    sub.add_parser("cleanup")

    resolve_parser = sub.add_parser("resolve")
    resolve_parser.add_argument("alias")
    resolve_parser.add_argument("--json", action="store_true")

    return parser.parse_args()

def main() -> int:
    args = parse_args()
    if args.command == "inventory":
        return print_inventory(args.mode, args.aliases, args.json)
    if args.command == "prefetch":
        return prefetch(args.mode, args.aliases)
    if args.command == "cleanup":
        return cleanup()
    if args.command == "resolve":
        return resolve(args.alias, args.json)
    return 1

if __name__ == "__main__":
    raise SystemExit(main())
