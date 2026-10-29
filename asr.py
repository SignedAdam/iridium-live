from __future__ import annotations

import importlib.metadata
import json
import time
from pathlib import Path

import downloads

PARAKEET_REPO = "mlx-community/parakeet-tdt-0.6b-v3"
MODELS = {"phonon-2": "FermionResearch/Phonon-2", "parakeet": PARAKEET_REPO}


def _parakeet_module():
    """mlx_audio's model package imports seventeen speech models (2.4 s); only parakeet is wanted."""
    import importlib
    import importlib.util
    import sys

    package = "mlx_audio.stt.models"
    if package not in sys.modules:
        sys.modules[package] = importlib.util.module_from_spec(importlib.util.find_spec(package))
    return importlib.import_module(package + ".parakeet")


def _engine():
    _parakeet_module()
    from fermion._speech._engine_phonon2 import load as engine_module

    lp, fd = engine_module("load_parakeet"), engine_module("fast_decode")
    lp._install_fp32_frontend()
    return fd


def _wrap(model, path, key: str, decode: dict, seconds: float):
    from fermion._speech.engine_phonon2 import Phonon2SpeechModel

    return Phonon2SpeechModel(model, path=Path(path), profile=key, backend="mlx-audio-parakeet",
                              decode=decode, load_seconds=seconds)


def ensure(key: str, report) -> None:
    if key == "phonon-2":
        from fermion._speech import fetch
        from fermion.transcribe import _resolve

        repo, profile, pin, _ = _resolve("phonon-2")
        if fetch.installed(repo, pin["unpack_dir"]):
            return
        report(0.0)
        with downloads.Progress([downloads.hub_dir(repo), fetch.profile_dir(repo, pin["unpack_dir"])],
                                pin["download_bytes"] + pin["unpacked_bytes"], report):
            fetch.ensure(repo, profile, pin, quiet=True)
        return

    from huggingface_hub import snapshot_download

    if _parakeet_dir(local=True):
        return
    report(0.0)
    with downloads.Progress([downloads.hub_dir(PARAKEET_REPO)], downloads.hub_bytes(PARAKEET_REPO), report):
        snapshot_download(PARAKEET_REPO, allow_patterns=["config.json", "model.safetensors"])


def _parakeet_dir(local: bool = False) -> Path | None:
    from huggingface_hub import snapshot_download

    try:
        return Path(snapshot_download(PARAKEET_REPO, allow_patterns=["config.json", "model.safetensors"],
                                      local_files_only=local))
    except Exception:
        return None


def _parakeet_weights(directory: Path, cache_dir: Path):
    """The hub ships fp32 (2.4 GB); keep a bf16 copy so a load reads half the bytes and casts nothing."""
    import mlx.core as mx

    cache = cache_dir / f"parakeet-v3-bf16-{directory.name[:16]}.safetensors"
    if cache.exists():
        return mx.load(str(cache))
    weights = {k: v.astype(mx.bfloat16) for k, v in mx.load(str(directory / "model.safetensors")).items()}
    mx.eval(list(weights.values()))
    cache_dir.mkdir(parents=True, exist_ok=True)
    for stale in cache_dir.glob("parakeet-v3-bf16-*"):
        stale.unlink()
    partial = cache.with_suffix(".partial.safetensors")
    mx.save_safetensors(str(partial), weights)
    partial.rename(cache)
    return weights


def load(key: str, cache_dir: Path):
    import mlx.core as mx

    started = time.perf_counter()
    fd = _engine()
    if key == "parakeet":
        directory = _parakeet_dir(local=True) or _parakeet_dir()
        model = _parakeet_module().Model.from_config(json.loads((directory / "config.json").read_text()))
        model.load_weights(list(_parakeet_weights(directory, cache_dir).items()), strict=True)
        mx.eval(model.parameters())
        model.eval()
        fd.install_fast_tdt(model, block=16)
        return _wrap(model, directory, key, {"levers": ["tdt16"]}, time.perf_counter() - started)
    return _load_phonon2(cache_dir, fd, started)


def _load_phonon2(cache_dir: Path, fd, started: float):
    import mlx.core as mx
    from mlx.utils import tree_flatten
    from fermion._speech import fetch
    from fermion._speech._engine_phonon2 import load as engine_module
    from fermion.transcribe import _resolve

    repo, key, pin, _ = _resolve("phonon-2")
    model_dir = Path(fetch.ensure(repo, key, pin, quiet=True))
    cache = cache_dir / (f"phonon-2-packed-{pin['sha256'][:16]}-fermion-"
                         f"{importlib.metadata.version('fermion-research')}.safetensors")
    if cache.exists():
        model = _packed_from_cache(model_dir, cache, fd, engine_module("packed_runtime"))
    else:
        model = engine_module("load_parakeet").load_parakeet(
            model_dir / "model.fermion", model_dir / "config.json",
            dtype=mx.bfloat16, packed=True, scale_dtype=mx.float32)
        cache_dir.mkdir(parents=True, exist_ok=True)
        partial = cache.with_suffix(".partial.safetensors")
        mx.save_safetensors(str(partial), dict(tree_flatten(model.parameters())))
        partial.rename(cache)
    fd.install_fast_tdt(model, block=16)
    return _wrap(model, model_dir, "phonon-2", {"five_value_modules": 264, "levers": ["tdt16"]},
                 time.perf_counter() - started)


def _packed_from_cache(model_dir: Path, cache: Path, fd, pr):
    import mlx.core as mx

    model = _parakeet_module().Model.from_config(json.loads((model_dir / "config.json").read_text()))
    weights = mx.load(str(cache))
    packed = []
    for i, layer in enumerate(model.encoder.layers):
        for dotted in fd._PACKED_LEAVES:
            parent, leaf = dotted.split(".")
            planes = weights[f"encoder.layers.{i}.{dotted}.base_q"]
            module = pr.PackedFiveValueLinear(planes.shape[1] * 16, planes.shape[0],
                                              bias=f"encoder.layers.{i}.{dotted}.bias" in weights,
                                              scale_dtype=mx.float32)
            setattr(getattr(layer, parent), leaf, module)
            packed.append(module)
    model.load_weights(list(weights.items()), strict=True)
    for module in packed:
        module.materialize_runtime_metadata()
    mx.eval(model.parameters())
    model.eval()
    return model


def warm_up(speech) -> None:
    import numpy as np

    speech.transcribe_array((np.random.default_rng(0).standard_normal(8000) * 0.02).astype(np.float32))

