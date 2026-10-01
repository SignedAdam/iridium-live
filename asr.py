"""The two speech models, behind one runtime.

Phonon-2 is a five-value Parakeet-TDT container and mlx-community's Parakeet TDT 0.6B v3 is the plain one, so both
run in mlx-audio's Parakeet graph with fermion's GPU-resident greedy TDT loop on top and both answer fermion's
`SpeechModel` interface. Whichever is loaded, the rest of the engine cannot tell the difference.
"""
from __future__ import annotations

import importlib.metadata
import json
import time
from pathlib import Path

import downloads

PARAKEET_REPO = "mlx-community/parakeet-tdt-0.6b-v3"
MODELS = {"phonon-2": "FermionResearch/Phonon-2", "parakeet": PARAKEET_REPO}


def _engine():
    from fermion._speech._engine_phonon2 import load as engine_module

    lp, fd = engine_module("load_parakeet"), engine_module("fast_decode")
    lp._install_fp32_frontend()  # the fp32 mel frontend both models were measured with
    return fd


def _wrap(model, path, key: str, decode: dict, seconds: float):
    from fermion._speech.engine_phonon2 import Phonon2SpeechModel

    return Phonon2SpeechModel(model, path=Path(path), profile=key, backend="mlx-audio-parakeet",
                              decode=decode, load_seconds=seconds)


def ensure(key: str, report) -> None:
    """Put the model on disk if it is not, reporting 0..1 as the bytes land. Cheap and silent when it is."""
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


def load(key: str, cache_dir: Path):
    """The loaded model, ready to decode. Both paths end in `install_fast_tdt`, so the greedy TDT loop stays on
    the GPU either way; only the encoder differs (Phonon-2's is packed to 2-bit planes, Parakeet's is bf16)."""
    import mlx.core as mx

    started = time.perf_counter()
    fd = _engine()
    if key == "parakeet":
        from mlx_audio.stt.models.parakeet import Model

        directory = _parakeet_dir()
        model = Model.from_config(json.loads((directory / "config.json").read_text()))
        weights = mx.load(str(directory / "model.safetensors"))  # shipped fp32; bf16 is what Phonon-2 runs in
        model.load_weights([(k, v.astype(mx.bfloat16)) for k, v in weights.items()], strict=True)
        mx.eval(model.parameters())
        model.eval()
        fd.install_fast_tdt(model, block=16)
        return _wrap(model, directory, key, {"levers": ["tdt16"]}, time.perf_counter() - started)
    return _load_phonon2(cache_dir, fd, started)


def _load_phonon2(cache_dir: Path, fd, started: float):
    """Phonon-2 with its five-value encoder left packed: the 264 quantised linears stay two native 2-bit QMM
    planes (`fermion transcribe`'s own packed runtime, without the `dense16` lever), which is what keeps the
    encoder at 0.5 GB of GPU memory instead of 1.3 GB. Building the planes out of the container costs 13 s and
    1.2 GB of transient host memory the allocator is slow to give back, so the first load saves them (350 MB,
    against 1.2 GB for the densified weights) and every load after that is back in 4 s."""
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
    """The same graph `load_parakeet(packed=True)` builds, out of the saved planes: the 264 packed linears carry
    `base_q`/`residual_q`/`row_lo`/`row_hi`, and the per-group QMM metadata is broadcast from the rows at the end."""
    import mlx.core as mx
    from mlx_audio.stt.models.parakeet import Model

    model = Model.from_config(json.loads((model_dir / "config.json").read_text()))
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
    """One discarded decode: the first through a fresh model pays the Metal graph compile, and that must not land
    on a user's first partial."""
    import numpy as np

    speech.transcribe_array((np.random.default_rng(0).standard_normal(8000) * 0.02).astype(np.float32))
