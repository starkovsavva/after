"""OpenAI-compatible file ASR. No SDK, implicit requests, or credentials on disk.

Every request is an explicitly chosen cloud transcription. PCM chunks cover the
entire source with contiguous frame boundaries; returned times remain absolute.
"""
from __future__ import annotations

import json
import math
import os
import re
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import wave
from pathlib import Path

MAX_UPLOAD_BYTES = 24_000_000  # Leave room for multipart headers below 25 MB.
MAX_RESPONSE_BYTES = 16_000_000
CHUNK_SECONDS = 600


def endpoint(settings):
    provider = settings.get("speechCloudProvider", "openai")
    if provider not in ("openai", "custom"):
        raise RuntimeError("Выберите OpenAI или совместимый сервер распознавания.")
    base = (settings.get("speechCloudEndpoint", "").strip() if provider == "custom"
            else "https://api.openai.com/v1")
    parsed = urllib.parse.urlsplit(base)
    loopback = parsed.hostname in ("localhost", "127.0.0.1", "::1")
    if (not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.scheme not in ("https", "http") or parsed.scheme == "http" and not loopback):
        raise RuntimeError("Укажите HTTPS-адрес API без пароля и параметров. HTTP доступен только на этом Mac.")
    return base.rstrip("/") + ("" if parsed.path.rstrip("/").endswith("/audio/transcriptions") else "/audio/transcriptions")


def request_fields(settings):
    model = settings.get("speechCloudModel", "gpt-transcribe").strip()
    if not model or len(model) > 250 or any(ord(ch) < 32 for ch in model):
        raise RuntimeError("Укажите корректное название модели распознавания.")
    response_format = settings.get("speechResponseFormat", "json")
    if response_format not in ("json", "verbose_json", "diarized_json"):
        raise RuntimeError("Неподдерживаемый формат ответа распознавания.")
    fields = [("model", model), ("response_format", response_format)]
    if response_format == "diarized_json":
        fields.append(("chunking_strategy", "auto"))
    if response_format == "verbose_json":
        fields.append(("timestamp_granularities[]", "segment"))
    language = settings.get("speechLanguage", "auto")
    if language != "auto":
        if not re.fullmatch("[a-z]{2,3}", language):
            raise RuntimeError("Язык распознавания должен быть auto или кодом языка, например ru / en.")
        fields.append(("languages[]" if model == "gpt-transcribe" else "language", language))
    return fields


def multipart(fields, audio: bytes):
    boundary = "posle-" + uuid.uuid4().hex
    parts = []
    for name, value in fields:
        parts.append((f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n').encode())
    parts += [(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode(), audio,
              f'\r\n--{boundary}--\r\n'.encode()]
    data = b"".join(parts)
    if len(data) >= 25_000_000:
        raise RuntimeError("Фрагмент аудио превышает лимит загрузки. Исходная запись сохранена.")
    return data, "multipart/form-data; boundary=" + boundary


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        # Never replay a secret and a recording to a redirected destination.
        return None


def upload(audio_path, settings, key, opener=None, timeout=300):
    if not key or any(ch in key for ch in "\r\n"):
        raise RuntimeError("Для облачного распознавания нужен API-ключ сервиса. Добавьте его в настройках распознавания речи.")
    data, content_type = multipart(request_fields(settings), audio_path.read_bytes())
    destination = endpoint(settings)
    req = urllib.request.Request(destination, data=data, headers={
        "Authorization": "Bearer " + key, "Content-Type": content_type,
        "Accept": "application/json", "User-Agent": "Posle"}, method="POST")
    if opener is None:
        handlers = [NoRedirect()]
        # A custom HTTP API on this Mac must stay on this Mac even when the
        # app was launched from a shell with proxy variables and no NO_PROXY.
        if urllib.parse.urlsplit(destination).hostname in ("localhost", "127.0.0.1", "::1"):
            handlers.append(urllib.request.ProxyHandler({}))
        opener = urllib.request.build_opener(*handlers)
    try:
        with opener.open(req, timeout=timeout) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        exc.close()
        # No provider-supplied content is echoed: some proxy errors include keys.
        messages = {401: "Ключ распознавания отклонён.", 403: "Сервис запретил доступ к модели.",
                    404: "Модель или адрес распознавания не найдены.", 413: "Сервис отклонил размер фрагмента аудио.",
                    429: "Лимит запросов или баланс сервиса исчерпан."}
        raise RuntimeError(messages.get(exc.code, f"Сервис распознавания вернул HTTP {exc.code}.")) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise RuntimeError("Нет ответа от сервиса распознавания. Проверьте адрес и соединение.") from None
    if len(payload) > MAX_RESPONSE_BYTES:
        raise RuntimeError("Ответ распознавания слишком большой; транскрипция не перезаписана.")
    try:
        result = json.loads(payload)
    except (ValueError, UnicodeDecodeError):
        raise RuntimeError("Сервис вернул ответ без JSON. Проверьте формат ответа модели.") from None
    if not isinstance(result, dict) or "error" in result:
        raise RuntimeError("Сервис вернул ошибку вместо транскрипции.")
    return result


def pcm_chunks(path: Path, output_dir: Path, seconds=CHUNK_SECONDS):
    """Bounded memory and no lost/overlapping samples, including the final tail."""
    with wave.open(str(path), "rb") as source:
        if source.getcomptype() != "NONE" or source.getnchannels() != 1 or source.getsampwidth() != 2 or source.getframerate() != 16000:
            raise RuntimeError("Облако ожидает PCM 16 бит, моно 16 кГц.")
        rate, total = source.getframerate(), source.getnframes()
        frames_per_chunk = min(int(seconds * rate), (MAX_UPLOAD_BYTES - 44) // 2)
        if frames_per_chunk < 1:
            raise RuntimeError("Неверный размер фрагмента аудио.")
        start, index = 0, 0
        while start < total:
            count = min(frames_per_chunk, total - start)
            pcm = source.readframes(count)
            if len(pcm) != count * 2:
                raise RuntimeError("Звуковая дорожка повреждена или обрезана.")
            output = output_dir / f"chunk-{index}.wav"
            with wave.open(str(output), "wb") as target:
                target.setparams((1, 2, rate, 0, "NONE", "not compressed"))
                target.writeframes(pcm)
            yield output, start / rate, count / rate, index
            output.unlink(missing_ok=True)
            start += count
            index += 1


def parse_response(response, offset, duration):
    text = response.get("text", "")
    if not isinstance(text, str):
        raise RuntimeError("Сервис вернул некорректный текст транскрипции.")
    raw = response.get("segments")
    approximate = False
    if raw is None:
        # JSON-only models do not provide word times. Expose one honest bounded
        # audio fragment, not invented sentences or interpolated word timestamps.
        raw = [{"start": 0, "end": duration, "text": text}] if text.strip() else []
        approximate = bool(raw)
    if not isinstance(raw, list):
        raise RuntimeError("Сервис вернул некорректные реплики.")
    segments = []
    for item in raw:
        if not isinstance(item, dict) or not isinstance(item.get("text"), str):
            raise RuntimeError("Сервис вернул некорректную реплику.")
        try:
            start, end = float(item["start"]), float(item["end"])
        except (ValueError, KeyError, TypeError):
            raise RuntimeError("Сервис не вернул корректные временные метки.") from None
        if (not math.isfinite(start) or not math.isfinite(end) or start < 0 or end < start
                or start > duration + 0.5 or end > duration + 0.5):
            raise RuntimeError("Временные метки сервиса выходят за пределы аудио.")
        if not item["text"].strip():
            continue
        speaker = item.get("speaker")
        if speaker is not None and (not isinstance(speaker, str) or not speaker.strip() or len(speaker) > 128):
            raise RuntimeError("Сервис вернул некорректного собеседника.")
        segments.append({"start": offset + min(start, duration), "end": offset + min(end, duration),
                         "text": item["text"].strip(), "speaker": speaker, "overlap": False})
    # A provider must not silently truncate the transcript text while returning a
    # seemingly successful timestamp payload. Differences only in whitespace pass.
    if raw and text.strip():
        normalized = lambda value: "".join(value.split())
        joined = " ".join(segment["text"] for segment in segments)
        comparable = text
        labels = {str(segment["speaker"]) for segment in segments if segment["speaker"]}
        if labels and normalized(joined) != normalized(comparable):
            # Official diarized responses can include speaker prefixes only in
            # top-level text. Remove those annotations, never transcript words.
            prefixes = "|".join(re.escape(label) for label in sorted(labels, key=len, reverse=True))
            comparable = re.sub(r"(?<!\w)(?:" + prefixes + r")\s*:\s*", "", text, flags=re.IGNORECASE)
        if normalized(joined) != normalized(comparable):
            raise RuntimeError("Текст сервиса не совпадает с репликами. Неполный ответ не сохранён.")
    if not raw and text.strip():
        raise RuntimeError("Сервис вернул текст без реплик. Неполный ответ не сохранён.")
    return segments, approximate


def transcribe(path: Path, root: Path, settings: dict, callback, key=None, uploader=None):
    # Validate before reading/uploading any audio.
    endpoint(settings)
    request_fields(settings)
    key = os.environ.get("POSLE_SPEECH_API_KEY", "") if key is None else key
    if not key:
        raise RuntimeError("Для облачного распознавания нужен API-ключ сервиса. Добавьте его в настройках распознавания речи.")
    uploader = uploader or upload
    result, approximate, chunk_count = [], False, 0
    with wave.open(str(path), "rb") as source:
        duration = source.getnframes() / source.getframerate()
    # A JSON-only provider gives no useful navigation times for a 10 minute
    # segment. Use 60-second requests and flag those fragment boundaries.
    chunk_seconds = 60 if settings.get("speechResponseFormat", "json") == "json" else CHUNK_SECONDS
    cache = root / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="speech-upload-", dir=cache) as temporary:
        for chunk, offset, length, index in pcm_chunks(path, Path(temporary), chunk_seconds):
            callback(index, max(1, math.ceil(duration / chunk_seconds)))
            response = uploader(chunk, settings, key)
            segments, approximate_chunk = parse_response(response, offset, length)
            if approximate_chunk:
                # Retain this distinction until engine assigns speakers. A whole
                # minute of untimed text cannot be mapped to individual turns.
                for segment in segments:
                    segment["_approximateTiming"] = True
            result.extend(segments)
            approximate |= approximate_chunk
            chunk_count += 1
    # A/B labels have no identity guarantee across independent API requests.
    labels_usable = chunk_count == 1 and all(segment["speaker"] for segment in result)
    if labels_usable:
        names = {}
        for segment in result:
            segment["speaker"] = names.setdefault(segment["speaker"], f"speaker_{len(names) + 1}")
    else:
        for segment in result:
            segment["speaker"] = "unknown"
    warnings = []
    if approximate:
        warnings.append("Сервис не вернул точные таймкоды. Ссылки ведут к началу аудиофрагмента длительностью до минуты.")
    if chunk_count > 1 and settings.get("speechResponseFormat") == "diarized_json":
        warnings.append("Метки собеседников сервиса не объединяются между аудиофрагментами; используется локальное разделение при наличии моделей.")
    callback(chunk_count, max(1, chunk_count))
    return result, warnings, labels_usable
