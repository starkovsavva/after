"""Architecture guard contracts: inward dependencies and explicit test boundaries."""
from pathlib import Path
import tempfile
import unittest

from check_layers import violations, outer_layer_violations


class LayerBoundaryTests(unittest.TestCase):
    def test_domain_cycles_and_outward_imports_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "a.rs").write_text("use super::b::Value;\nuse crate::storage;\n")
            (root / "b.rs").write_text("use super::a::Value;\n")
            errors = list(violations(root))
            self.assertTrue(any("outer module" in error for error in errors))
            self.assertTrue(any("a -> b -> a" in error for error in errors))

    def test_grouped_os_imports_cannot_hide_in_domain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "values.rs").write_text("use std::{collections::HashSet, fs};\n")
            self.assertTrue(any("OS/I/O" in error for error in violations(root)))

    def test_application_accepts_contracts_but_rejects_sql_adapter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "application").mkdir()
            source = root / "application/workspace.rs"
            source.write_text("use super::ports::WorkspaceRepository;\nuse crate::domain::workspace::NotesWorkspace;\n")
            self.assertEqual(list(outer_layer_violations(root)), [])
            source.write_text("use crate::infrastructure::workspace_repository;\n")
            self.assertEqual(len(list(outer_layer_violations(root))), 1)

    def test_infrastructure_can_implement_ports_but_cannot_call_legacy_operations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "infrastructure").mkdir()
            source = root / "infrastructure/workspace.rs"
            source.write_text("use crate::application::ports::WorkspaceRepository;\n#[cfg(all(test, unix))]\nmod tests { use crate::notes; }\n")
            self.assertEqual(list(outer_layer_violations(root)), [])
            source.write_text("use crate::notes;\n")
            self.assertEqual(len(list(outer_layer_violations(root))), 1)

    def test_queue_facade_cannot_be_used_as_an_inner_layer_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for layer in ("application", "infrastructure"):
                (root / layer).mkdir()
                (root / layer / "queue.rs").write_text("use crate::jobs;\n")
            self.assertEqual(len(list(outer_layer_violations(root))), 2)

    def test_process_supervisor_is_an_outer_adapter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "domain").mkdir()
            (root / "application").mkdir()
            for layer in ("domain", "application"):
                (root / layer / "worker.rs").write_text("use after_process_runtime::ProcessTree;\n")
            self.assertEqual(len(list(violations(root / "domain"))), 1)
            self.assertEqual(len(list(outer_layer_violations(root))), 1)


if __name__ == "__main__":
    unittest.main()
