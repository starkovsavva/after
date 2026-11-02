"""Offline dependency smoke; tiny ONNX Identity graph, synthetic silent audio.

This is not a speech model and does not establish ASR accuracy/readiness.
Model field numbers follow https://github.com/onnx/onnx/blob/main/onnx/onnx.proto3.
"""
import importlib.metadata
import json
from pathlib import Path
import subprocess
import sys


def integer(field, value):
    def varint(number):
        result = bytearray()
        while number > 127:
            result.append((number & 127) | 128)
            number >>= 7
        result.append(number)
        return bytes(result)
    return varint(field << 3) + varint(value)


def message(field, data):
    # Fixtures stay below 128 bytes; larger payloads need general length varints.
    assert len(data) < 128 and field < 16
    return bytes([(field << 3) | 2, len(data)]) + data


def identity_model():
    def value(name):
        shape = message(1, integer(1, 1))
        tensor = integer(1, 1) + message(2, shape)  # FLOAT, shape [1]
        return message(1, name) + message(2, message(1, tensor))
    node = message(1, b'X') + message(2, b'Y') + message(4, b'Identity')
    graph = message(1, node) + message(2, b'cpu-probe') + message(11, value(b'X')) + message(12, value(b'Y'))
    return integer(1, 8) + message(7, graph) + message(8, integer(2, 13))


def probe(policy):
    import numpy as np
    import onnx_asr
    import onnxruntime as ort
    import sherpa_onnx
    import imageio_ffmpeg
    for package in policy['packages']:
        if importlib.metadata.version(package['name']) != package['version']:
            raise RuntimeError('Installed CPU package version differs from the compiled lock')
    session = ort.InferenceSession(identity_model(), providers=['CPUExecutionProvider'])
    original = np.array([3.25], dtype=np.float32)
    if session.get_providers() != ['CPUExecutionProvider'] or not np.array_equal(session.run(None, {'X': original})[0], original):
        raise RuntimeError('Actual CPU ONNX inference failed')
    ffmpeg = Path(imageio_ffmpeg.get_ffmpeg_exe()).resolve(strict=True)
    if not ffmpeg.is_relative_to(Path(sys.prefix).resolve()):
        raise RuntimeError('FFmpeg must come from the verified wheel installation')
    subprocess.run([str(ffmpeg), '-nostdin', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                    'anullsrc=r=16000:cl=mono', '-t', '0.05', '-f', 'null', '-'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    return {'cpuInferenceVerified': True, 'bundledFfmpegVerified': True, 'modelsInstalled': False}


if __name__ == '__main__':
    policy = json.loads(Path(sys.argv[1]).read_text())
    Path(sys.argv[2]).write_text(json.dumps(probe(policy)))
