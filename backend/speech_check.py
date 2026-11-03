"""Offline local preflight using synthetic PCM; never publishes a transcript."""
from pathlib import Path
import tempfile
import wave


def check(settings, select_model, open_model, render_audio):
    if settings.get("speechMode") != "local" or settings.get("diarization") is not False:
        raise RuntimeError("Select local speech with diarization disabled before checking it.")
    path = settings.get("asrModelPath")
    if not isinstance(path, str) or not Path(path.strip()).is_absolute() or ".." in Path(path.strip()).parts:
        raise RuntimeError("Select an explicit absolute local model path.")
    selected = select_model()
    with tempfile.TemporaryDirectory(prefix="after-speech-check-") as temporary:
        audio = Path(temporary) / "synthetic.wav"
        render_audio(audio)
        with wave.open(str(audio)) as pcm:
            if (pcm.getnchannels(), pcm.getsampwidth(), pcm.getframerate(), pcm.getnframes()) != (1, 2, 16000, 16000):
                raise RuntimeError("Synthetic media verification failed.")
        adapter = open_model(selected)
        try:
            # Includes lazy model loading (e.g. Whisper). Silence may produce
            # empty tokens or hallucinations; neither is a quality assertion.
            tokens = adapter.transcribe(audio, lambda *_: None)
            if not isinstance(tokens, list):
                raise RuntimeError("Local inference returned an invalid result.")
        finally:
            adapter.close()
    return {"localInferenceVerified": True, "mediaVerified": True,
            "diarizationVerified": False}
