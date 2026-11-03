import unittest
import wave
from pathlib import Path
from unittest.mock import Mock

from speech_check import check


class LocalSpeechCheckTests(unittest.TestCase):
    def settings(self):
        return {"speechMode": "local", "diarization": False, "asrModelPath": "/selected/model"}

    def render(self, path):
        self.audio = path
        with wave.open(str(path), "wb") as output:
            output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            output.writeframes(b"\0\0" * 16000)

    def test_actual_decode_is_required_and_temporary_audio_is_removed(self):
        adapter = Mock()
        adapter.transcribe.return_value = []
        def decode(audio, callback):
            self.assertTrue(audio.is_file())
            with wave.open(str(audio)) as pcm:
                self.assertEqual(pcm.readframes(16000), b"\0\0" * 16000)
            return []
        adapter.transcribe.side_effect = decode
        selected = {"path": "/selected/model", "format": "onnx"}
        opener = Mock(return_value=adapter)
        result = check(self.settings(), lambda: selected, opener, self.render)
        opener.assert_called_once_with(selected)
        adapter.close.assert_called_once_with()
        self.assertFalse(self.audio.exists())
        self.assertEqual(result, {"localInferenceVerified": True, "mediaVerified": True,
                                  "diarizationVerified": False})
        self.assertNotIn("path", result)

    def test_decode_failure_and_invalid_results_never_claim_readiness(self):
        for failure in (True, False):
            adapter = Mock()
            if failure:
                adapter.transcribe.side_effect = RuntimeError("synthetic decode failed")
            else:
                adapter.transcribe.return_value = None
            with self.assertRaises(RuntimeError):
                check(self.settings(), lambda: {}, lambda _: adapter, self.render)
            adapter.close.assert_called_once_with()
            self.assertFalse(self.audio.exists())

    def test_media_failure_never_loads_a_model(self):
        opener = Mock()
        with self.assertRaises(RuntimeError):
            check(self.settings(), lambda: {}, opener, Mock(side_effect=RuntimeError("codec failure")))
        opener.assert_not_called()

    def test_unsupported_selection_never_inspects_models_or_renders_audio(self):
        for key, value in [("speechMode", "cloud"), ("diarization", True),
                           ("asrModelPath", "~/model"), ("asrModelPath", "relative"),
                           ("asrModelPath", "/model/../outside")]:
            settings = self.settings()
            settings[key] = value
            select, opener, render = Mock(), Mock(), Mock()
            with self.assertRaises(RuntimeError):
                check(settings, select, opener, render)
            select.assert_not_called()
            opener.assert_not_called()
            render.assert_not_called()


if __name__ == "__main__":
    unittest.main()
