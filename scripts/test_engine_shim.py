"""The legacy MCP entry point must exec the branded engine without a shell."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
SHIM = PROJECT / 'packaging/LegacyEngineShim.c'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'Requires macOS and clang')
class LegacyEngineShimTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix='after-engine-shim-', dir='/private/tmp')
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name) / 'Приложение с пробелами'
        self.root.mkdir()
        self.shim = self.root / 'posle-engine'
        subprocess.run(['/usr/bin/clang', '-Os', '-std=c11', '-Wall', '-Wextra', '-Werror', str(SHIM), '-o', str(self.shim)],
                       check=True, capture_output=True)

    def test_exec_preserves_arguments_stdin_and_status_without_shell(self):
        source = self.root / 'fixture.c'
        source.write_text(r'''#include <stdio.h>
int main(int argc, char **argv) {
    printf("%s\n", argv[0]);
    for (int i = 1; i < argc; i++) printf("%s\n", argv[i]);
    int c; while ((c = getchar()) != EOF) putchar(c);
    return 23;
}
''')
        engine = self.root / 'After Engine'
        subprocess.run(['/usr/bin/clang', str(source), '-o', str(engine)], check=True, capture_output=True)
        canary = self.root / 'never-created'
        arguments = ['mcp', '--root', 'Русский "путь" $(touch ' + str(canary) + ')']
        result = subprocess.run([str(self.shim), *arguments], input='synthetic input\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.stdout, '\n'.join([str(engine), *arguments]) + '\nsynthetic input\n')
        self.assertFalse(canary.exists())

    def test_missing_engine_fails_without_using_path(self):
        result = subprocess.run([str(self.shim), 'mcp'], text=True, capture_output=True,
                                env={**os.environ, 'PATH': str(self.root)})
        self.assertEqual(result.returncode, 127)
        self.assertEqual(result.stdout, '')
        self.assertIn('cannot start bundled engine', result.stderr)

    def test_symlink_invocation_resolves_the_bundled_engine(self):
        source = self.root / 'fixture.c'
        source.write_text('int main(void) { return 42; }\n')
        subprocess.run(['/usr/bin/clang', str(source), '-o', str(self.root / 'After Engine')],
                       check=True, capture_output=True)
        link = Path(self.fixture.name) / 'external-link'
        link.symlink_to(self.shim)
        self.assertEqual(subprocess.run([str(link)], capture_output=True).returncode, 42)

    def test_legacy_entry_point_runs_with_branded_kernel_process_name(self):
        source = self.root / 'process-name.c'
        source.write_text('''#include <libproc.h>
#include <stdio.h>
#include <unistd.h>
int main(void) {
    char name[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_name(getpid(), name, sizeof(name)) <= 0) return 1;
    puts(name); return 0;
}
''')
        subprocess.run(['/usr/bin/clang', str(source), '-lproc', '-o', str(self.root / 'After Engine')],
                       check=True, capture_output=True)
        result = subprocess.run([str(self.shim)], text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.strip(), 'After Engine')


if __name__ == '__main__':
    unittest.main()
