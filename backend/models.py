"""Read-only, bounded discovery of local Parakeet weights (stdlib only).

Importing this module never imports ML runtimes or contacts a model registry.
Compatibility means a supported file layout with complete local artifacts; actual
ONNX/MLX graph validation remains the runtime's responsibility when loading it.
"""
from __future__ import annotations

import hashlib
import json
import os
import struct
import zipfile
from collections import deque
from contextvars import ContextVar
from pathlib import Path

SETTINGS_OVERRIDE = ContextVar("posle_model_settings", default=None)

DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
# Immutable Hub revisions; listed download sizes exclude the tiny runtime/config.
ASR_CATALOG = {
    "parakeet-v3": {"repo": DEFAULT_MODEL, "revision": "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15", "family": "parakeet", "name": "Parakeet v3", "bytes": 2508532829},
    "whisper-turbo": {"repo": "mlx-community/whisper-large-v3-turbo", "revision": "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb", "family": "whisper", "name": "Whisper Large v3 Turbo", "bytes": 1613977880},
    "whisper-small": {"repo": "mlx-community/whisper-small-mlx", "revision": "45f3915923c7a79a5a5b5a7d909d39aeb0e5630e", "family": "whisper", "name": "Whisper Small", "bytes": 481307858},
}


def catalog_model(settings):
    key = settings.get("speechLocalModel", "parakeet-v3")
    if key not in ASR_CATALOG:
        raise RuntimeError("Выберите доступную модель распознавания в настройках.")
    return ASR_CATALOG[key]

MAX_JSON = 1024 * 1024
MAX_HEADER = 16 * 1024 * 1024
MAX_NODES = 800
MAX_DEPTH = 6


def _json(path: Path):
    if path.name == "settings.json" and os.environ.get("POSLE_JOB_SETTINGS"):
        raw = os.environ["POSLE_JOB_SETTINGS"]
        if len(raw) > MAX_JSON:
            raise ValueError("Конфигурация задания слишком большая")
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ValueError("Настройки задания должны быть объектом")
        return value
    if not path.is_file() or path.stat().st_size > MAX_JSON:
        raise ValueError("JSON модели отсутствует или слишком большой")
    with path.open(encoding="utf-8") as stream:
        result = json.load(stream)
    if not isinstance(result, dict):
        raise ValueError("JSON модели должен содержать объект")
    return result


def _files(directory: Path):
    try:
        result = {}
        for index, entry in enumerate(directory.iterdir()):
            if index >= 512:
                break
            if entry.is_file():
                result[entry.name] = entry
        return result
    except OSError:
        return {}


def _weight(path: Path, minimum: int):
    if not path.is_file() or path.stat().st_size < minimum:
        raise ValueError(f"Файл {path.name} отсутствует или не полностью скачан")
    # Detect Git LFS pointer files and broken symlinks without opening GB weights.
    with path.open("rb") as stream:
        if stream.read(64).startswith(b"version https://git-lfs.github.com/spec/"):
            raise ValueError(f"Вместо весов {path.name} найден указатель Git LFS")


def _safetensors(path: Path):
    _weight(path, 1024)
    with path.open("rb") as stream:
        header_size = struct.unpack("<Q", stream.read(8))[0]
        if not 2 <= header_size <= MAX_HEADER:
            raise ValueError(f"Повреждён заголовок {path.name}")
        header = json.loads(stream.read(header_size))
    if not isinstance(header, dict):
        raise ValueError(f"Повреждён заголовок {path.name}")
    tensors = [v for k, v in header.items() if k != "__metadata__"]
    if not tensors:
        raise ValueError(f"В {path.name} нет тензоров")
    payload_size = path.stat().st_size - 8 - header_size
    for tensor in tensors:
        if not isinstance(tensor, dict):
            raise ValueError(f"Повреждён заголовок {path.name}")
        offsets = tensor.get("data_offsets", [])
        if (not isinstance(offsets, list) or len(offsets) != 2 or any(type(value) is not int for value in offsets)
                or not 0 <= offsets[0] <= offsets[1] <= payload_size):
            raise ValueError(f"Веса {path.name} скачаны не полностью")


def _vocabulary(path: Path):
    if not path.is_file() or not 10 <= path.stat().st_size <= MAX_JSON:
        raise ValueError(f"Не найден полный словарь {path.name}")
    lines = path.read_text(encoding="utf-8").splitlines()
    entries = [line.rsplit(" ", 1) for line in lines if line.strip()]
    if not entries or any(len(parts) != 2 or not parts[1].isdigit() for parts in entries):
        raise ValueError(f"Неверный формат {path.name}")
    if not any(parts[0] == "<blk>" for parts in entries):
        raise ValueError(f"В {path.name} отсутствует <blk>")


def _choose(files, stem: str):
    return next((files[name] for name in (f"{stem}.int8.onnx", f"{stem}.fp16.onnx", f"{stem}.onnx") if name in files), None)


def inspect_model(directory: Path, source: str = "Выбранная папка", requested_format: str = "auto") -> dict:
    directory = directory.expanduser().absolute()
    files = _files(directory)
    names = set(files)
    inferred = "mlx" if any(name.endswith((".safetensors", ".npz")) for name in names) else "onnx"
    name = (directory.parent.parent.name.removeprefix("models--").replace("--", "/")
            if directory.parent.name == "snapshots" and directory.parent.parent.name.startswith("models--") else directory.name)
    result = {"id": hashlib.sha256(os.fsencode(str(directory))).hexdigest()[:20],
              "name": name, "path": str(directory), "format": inferred,
              "source": source, "compatible": False, "reason": "", "layout": "", "files": {}}
    try:
        if not directory.is_dir():
            raise ValueError("Папка модели не найдена")
        if requested_format not in ("auto", "mlx", "onnx"):
            raise ValueError("Неизвестный формат модели; выберите auto, mlx или onnx")
        if inferred == "mlx":
            config = _json(directory / "config.json")
            if isinstance(config, dict) and all(isinstance(config.get(key), int) and config[key] > 0 for key in ("n_mels", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer", "n_vocab", "n_text_ctx", "n_text_state", "n_text_head", "n_text_layer")):
                weights = next((files[name] for name in ("weights.safetensors", "weights.npz") if name in files), None)
                if weights is None:
                    raise ValueError("Whisper MLX: файл весов не найден")
                if weights.suffix == ".safetensors":
                    _safetensors(weights)
                else:
                    _weight(weights, 1024)
                    with zipfile.ZipFile(weights) as archive:
                        names = archive.namelist()
                        if not names or any(not name.endswith(".npy") or Path(name).name != name for name in names):
                            raise ValueError("Whisper MLX: повреждён архив весов")
                if requested_format == "onnx":
                    raise ValueError("Выбран ONNX, а папка содержит Whisper MLX")
                result.update(compatible=True, layout="whisper-mlx", files={"model": str(weights)}, reason="Whisper MLX · русский и английский")
                return result
            if not isinstance(config, dict) or not isinstance(config.get("encoder"), dict) or not isinstance(config.get("joint"), dict):
                raise ValueError("Это не MLX-конвертация Parakeet TDT")
            defaults = config.get("model_defaults", {})
            if not config["joint"].get("vocabulary") or not isinstance(defaults, dict) or not defaults.get("tdt_durations"):
                raise ValueError("MLX Parakeet TDT: не найден словарь или TDT-конфигурация")
            weights = sorted(name for name in files if name.endswith(".safetensors"))
            if "model.safetensors.index.json" in files:
                index = _json(files["model.safetensors.index.json"])
                weight_map = index.get("weight_map")
                if not isinstance(weight_map, dict) or not all(isinstance(value, str) for value in weight_map.values()):
                    raise ValueError("Повреждён индекс MLX-модели")
                required = set(weight_map.values())
                if not required or any(Path(name).name != name or name not in files for name in required):
                    raise ValueError("Отсутствуют части MLX-модели")
                weights = sorted(required)
            # parakeet-mlx 0.5.3 loads model.safetensors; other sharded layouts are
            # deliberately not offered even if they happen to contain safetensors.
            if weights != ["model.safetensors"]:
                raise ValueError("Нужен model.safetensors, совместимый с parakeet-mlx")
            _safetensors(files["model.safetensors"])
            result.update(layout="mlx", files={"model": str(files["model.safetensors"])})
        elif any(name.startswith("encoder-model") for name in names):
            if "parakeet" not in str(directory).lower():
                raise ValueError("Не удалось подтвердить Parakeet TDT; выберите исходную папку parakeet")
            encoder, decoder = _choose(files, "encoder-model"), _choose(files, "decoder_joint-model")
            if encoder is None or decoder is None:
                raise ValueError("ONNX Parakeet: нужны encoder-model и decoder_joint-model")
            _weight(encoder, 100_000_000 if ".int8." in encoder.name else 1_000_000)
            _weight(decoder, 1_000_000)
            # NeMo FP32 export stores encoder tensors in a separate .data file.
            if encoder.name == "encoder-model.onnx" and encoder.stat().st_size < 200_000_000:
                _weight(directory / "encoder-model.onnx.data", 1_000_000_000)
            _weight(directory / "nemo128.onnx", 1024)
            _vocabulary(directory / "vocab.txt")
            if "config.json" in files:
                config = _json(files["config.json"])
                if config.get("model_type") not in (None, "nemo-conformer-tdt") or config.get("features_size", 128) != 128:
                    raise ValueError("ONNX-конфигурация не соответствует Parakeet TDT 128 mel")
            result.update(layout="meetily-onnx", files={"encoder": str(encoder), "decoder": str(decoder),
                          "tokens": str(directory / "vocab.txt")})
        elif any(name.startswith("encoder") and name.endswith(".onnx") for name in names):
            encoder, decoder, joiner = (_choose(files, stem) for stem in ("encoder", "decoder", "joiner"))
            if not all((encoder, decoder, joiner)):
                raise ValueError("Sherpa ONNX: нужны encoder, decoder и joiner")
            for path, minimum in ((encoder, 100_000_000), (decoder, 1_000_000), (joiner, 100_000)):
                _weight(path, minimum)
            _vocabulary(directory / "tokens.txt")
            if "parakeet" not in str(directory).lower():
                raise ValueError("Не удалось подтвердить, что ONNX-модель — Parakeet; выберите её исходную папку parakeet")
            result.update(layout="sherpa-onnx", files={"encoder": str(encoder), "decoder": str(decoder),
                          "joiner": str(joiner), "tokens": str(directory / "tokens.txt")})
        elif any(name.endswith((".nemo", ".gguf")) for name in names):
            raise ValueError("GGUF и .nemo не являются MLX/ONNX Parakeet; нужна совместимая конвертация")
        else:
            raise ValueError("Не найдены полные веса Parakeet MLX или ONNX")
        if requested_format != "auto" and inferred != requested_format:
            raise ValueError(f"Выбран {requested_format.upper()}, а папка содержит {inferred.upper()}")
        result["compatible"] = True
        version_path = str(directory).lower()
        result["reason"] = ("Parakeet v2: только английский" if "v2" in version_path
                            else "Локальные файлы готовы; проверка графа при запуске")
    except (OSError, ValueError, TypeError, KeyError, RecursionError, struct.error) as exc:
        result["reason"] = str(exc)
    return result


def public_model(model: dict):
    return {key: model[key] for key in ("id", "name", "path", "format", "source", "compatible", "reason")}


def search_roots(root: Path, home: Path | None = None):
    home = home or Path.home()
    candidates = [(root / "cache/huggingface/hub", "После")]
    for name in ("HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"):
        if os.environ.get(name):
            candidates.append((Path(os.environ[name]).expanduser(), "Hugging Face"))
    if os.environ.get("HF_HOME"):
        candidates.append((Path(os.environ["HF_HOME"]).expanduser() / "hub", "Hugging Face"))
    candidates += [(home / ".cache/huggingface/hub", "Hugging Face"),
                   (home / "Library/Caches/huggingface/hub", "Hugging Face")]
    for name in ("Meetily", "meetily", "com.meetily.ai"):
        candidates.append((home / "Library/Application Support" / name / "models", "Локальная папка моделей"))
    candidates += [(home / ".lmstudio/models", "LM Studio"), (home / ".cache/lm-studio/models", "LM Studio")]
    seen = set()
    for directory, source in candidates:
        key = str(directory.absolute())
        if key not in seen:
            seen.add(key)
            yield directory, source


def discover_asr(root: Path, roots=None):
    """At most 800 model directories, depth 6; no home-wide recursive search."""
    found, notes, seen = [], [], set()
    queue = deque((path, source, 0) for path, source in (search_roots(root) if roots is None else roots))
    visited = 0
    while queue and visited < MAX_NODES:
        directory, source, depth = queue.popleft()
        try:
            key = str(directory.resolve())
            if key in seen or not directory.is_dir():
                continue
            seen.add(key)
            visited += 1
            with os.scandir(directory) as entries:
                children = []
                names = set()
                for index, entry in enumerate(entries):
                    if index >= 512:
                        notes.append("Одна из папок содержит слишком много файлов; укажите папку модели вручную.")
                        break
                    names.add(entry.name)
                    # Never traverse arbitrary directory symlinks or corpus folders.
                    if depth < MAX_DEPTH and entry.is_dir(follow_symlinks=False) and entry.name not in (
                            "blobs", ".locks", "refs", "meetings", "transcriptions", "recordings", "test_wavs", ".git"):
                        children.append(Path(entry.path))
            candidate = (("parakeet" in str(directory).lower() and any(name.endswith((".onnx", ".nemo", ".gguf", ".safetensors")) for name in names))
                         or any(name in names for name in ("model.safetensors", "weights.safetensors", "weights.npz")) and "config.json" in names
                         or any(name.startswith("encoder-model") for name in names))
            if candidate:
                item = inspect_model(directory, source)
                # Non-Parakeet MLX LLMs from LM Studio are outside the ASR list.
                if "parakeet" in str(directory).lower() or item["compatible"]:
                    found.append(item)
                if item["compatible"]:
                    continue
            for child in sorted(children):
                queue.append((child, source, depth + 1))
        except (OSError, RuntimeError):
            continue
    if queue:
        notes.append("Поиск ограничен стандартными папками моделей; другую папку можно выбрать вручную.")
    found.sort(key=lambda m: (not m["compatible"], "v2" in m["path"].lower(), m["format"] != "mlx", m["path"]))
    return found, list(dict.fromkeys(notes))


def selected_asr(root: Path):
    settings_file = root / "settings.json"
    settings = SETTINGS_OVERRIDE.get()
    if settings is None:
        settings = _json(settings_file) if settings_file.exists() or os.environ.get("POSLE_JOB_SETTINGS") else {}
    selected_format = settings.get("asrModelFormat", "auto") or "auto"
    if selected_format not in ("auto", "mlx", "onnx"):
        raise RuntimeError("Выберите формат Parakeet: auto, mlx или onnx")
    explicit = settings.get("asrModelPath", "").strip()
    if explicit:
        directory = Path(explicit).expanduser()
        if not directory.is_absolute():
            raise RuntimeError("Путь к Parakeet должен быть абсолютным")
        model = inspect_model(directory, requested_format=selected_format)
        if not model["compatible"]:
            raise RuntimeError("Выбранная модель Parakeet: " + model["reason"] + ". Повторная загрузка не выполнялась.")
        return model
    found, _ = discover_asr(root)
    catalog = catalog_model(settings)
    candidates = [model for model in found if model["compatible"] and selected_format in ("auto", model["format"])]
    if catalog["family"] == "whisper":
        return next((model for model in candidates if model["layout"] == "whisper-mlx" and (model["name"] == catalog["repo"] or Path(model["path"]).name == catalog["repo"].split("/")[-1])), None)
    return next((model for model in candidates if model["layout"] != "whisper-mlx"), None)
