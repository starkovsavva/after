import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import types

import media_runtime


class MediaRuntimeChecks(unittest.TestCase):
    def test_reuses_bytes_without_touching_the_dependency_and_updates_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'ffmpeg-original'
            source.write_bytes(b'original-native-binary')
            source.chmod(0o700)
            target = media_runtime.install(source, root)
            self.assertEqual(target.name, 'После Медиа')
            self.assertEqual(target.read_bytes(), source.read_bytes())
            inode = target.stat().st_ino
            self.assertEqual(media_runtime.install(source, root).stat().st_ino, inode)
            source.write_bytes(b'updated-native-binary')
            self.assertEqual(media_runtime.install(source, root).read_bytes(), source.read_bytes())
            self.assertEqual(target.stat().st_mode & 0o777, 0o700)

    def test_rejects_target_and_directory_symlinks_without_modifying_foreign_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'; source.write_bytes(b'native'); source.chmod(0o700)
            foreign = root / 'foreign'; foreign.write_bytes(b'untouched')
            (root / 'runtime/media').mkdir(parents=True)
            (root / 'runtime/media/После Медиа').symlink_to(foreign)
            with self.assertRaises(RuntimeError): media_runtime.install(source, root)
            self.assertEqual(foreign.read_bytes(), b'untouched')
            (root / 'runtime/media/После Медиа').unlink()
            for child in (root / 'runtime/media').iterdir(): child.unlink()
            (root / 'runtime/media').rmdir()
            (root / 'runtime/media').symlink_to(root)
            with self.assertRaises(RuntimeError): media_runtime.install(source, root)

    def test_failed_install_leaves_previous_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'; source.write_bytes(b'native'); source.chmod(0o700)
            target = media_runtime.install(source, root)
            source.chmod(0o600)
            with self.assertRaises(RuntimeError): media_runtime.install(source, root)
            self.assertEqual(target.read_bytes(), b'native')

    def test_configure_reuses_model_runtime_and_routes_dependency_calls_to_brand(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary_dir = root / "runtime/venv/bin"; binary_dir.mkdir(parents=True)
            dependency = root / "runtime/venv/lib/ffmpeg"; dependency.parent.mkdir()
            dependency.write_bytes(b"signed-native"); dependency.chmod(0o700)
            legacy = binary_dir / "ffmpeg"; legacy.symlink_to(dependency)
            mock = types.SimpleNamespace(get_ffmpeg_exe=lambda: str(dependency))
            with patch.dict("sys.modules", {"imageio_ffmpeg": mock}), patch.dict(os.environ, {}, clear=True):
                target = media_runtime.configure(root)
                self.assertEqual(legacy.resolve(), dependency.resolve())
                self.assertEqual((root / "runtime/media/bin/ffmpeg").resolve(), target.resolve())
                self.assertEqual(os.environ["IMAGEIO_FFMPEG_EXE"], str(target))
                self.assertEqual(os.environ["PATH"].split(os.pathsep)[0], str(root / "runtime/media/bin"))
            self.assertEqual(dependency.read_bytes(), b"signed-native")

    def test_configure_cannot_modify_a_foreign_symlinked_venv(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            foreign = root / "foreign"; (foreign / "bin").mkdir(parents=True)
            dependency = foreign / "ffmpeg"; dependency.write_bytes(b"untouched")
            alias = foreign / "bin/ffmpeg"; alias.symlink_to(dependency)
            (root / "runtime").mkdir(); (root / "runtime/venv").symlink_to(foreign)
            with self.assertRaises(RuntimeError): media_runtime.configure(root)
            self.assertEqual(os.readlink(alias), str(dependency))
            self.assertEqual(dependency.read_bytes(), b"untouched")
