"""One bounded frozen-settings contract for speech and model selection."""
import json
import os


def snapshot():
    """Return None only when absent; supplied invalid data never falls back."""
    if "POSLE_JOB_SETTINGS" not in os.environ:
        return None
    raw = os.environ["POSLE_JOB_SETTINGS"]
    if len(raw.encode("utf-8")) > 262144:
        raise ValueError("Конфигурация задания слишком большая.")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("Настройки задания должны быть объектом.")
    return value
