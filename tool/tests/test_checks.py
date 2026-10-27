#!/usr/bin/env python3
"""Negative controls for the CI boundaries; uses a fake Cargo, never compiles."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]


class BoundaryChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='chatweave-checks-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ('tool', 'bin', 'rust/crates/chatweave-protocol/src',
                          'dart/packages/chatweave_core/lib', 'schemas'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for name in ('check_deps', 'check_host_terms', 'host_terms.txt'):
            shutil.copyfile(REPOSITORY / 'tool' / name, self.root / 'tool' / name)
        (self.root / 'dart/packages/chatweave_core/pubspec.yaml').write_text(
            'name: chatweave_core\nenvironment:\n  sdk: ">=3.6.0 <4.0.0"\n')
        (self.root / 'dart/packages/chatweave_core/lib/core.dart').write_text('library;\n')
        (self.root / 'rust/Cargo.toml').write_text(
            '[workspace]\nmembers = ["crates/chatweave-protocol"]\n')
        (self.root / 'rust/crates/chatweave-protocol/Cargo.toml').write_text(
            '[package]\nname = "chatweave-protocol"\nversion = "0.1.0"\n')
        fake_cargo = self.root / 'bin/cargo'
        fake_cargo.write_text('''#!/usr/bin/env python3
import json
from pathlib import Path
import sys
root = Path(sys.argv[sys.argv.index('--manifest-path') + 1]).parent.parent
runtime = (root / '.include-tokio').exists()
names = ['chatweave-protocol', 'serde'] + (['tokio'] if runtime else [])
if sys.argv[1] == 'tree':
    print('\\n'.join(name + ' v1.0.0' for name in names))
elif sys.argv[1] == 'metadata':
    print(json.dumps({
        'packages': [{'id': name, 'name': name,
                      'manifest_path': str(root / 'rust/crates' / name / 'Cargo.toml')}
                     for name in names],
        'resolve': {'nodes': [{'id': name,
                              'dependencies': names[1:] if name == names[0] else []}
                             for name in names]}}))
else:
    sys.exit('unexpected Cargo invocation')
''')
        fake_cargo.chmod(0o755)
        self.environment = os.environ.copy()
        self.environment['PATH'] = str(self.root / 'bin') + os.pathsep + self.environment['PATH']

    def run_check(self, name):
        return subprocess.run(
            ['bash', str(self.root / 'tool' / name), '--root', str(self.root)],
            env=self.environment, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=False)

    def assert_rejected(self, check, needle):
        result = self.run_check(check)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(needle, result.stderr)

    def test_clean_fixture_passes_both_checks(self):
        for check in ('check_deps', 'check_host_terms'):
            with self.subTest(check=check):
                result = self.run_check(check)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_flutter_import_in_core_is_rejected(self):
        path = self.root / 'dart/packages/chatweave_core/lib/core.dart'
        path.write_text("import 'package:flutter/widgets.dart';\n")
        self.assert_rejected('check_deps', 'core.dart:1:')

    def test_flutter_dependency_in_core_is_rejected(self):
        path = self.root / 'dart/packages/chatweave_core/pubspec.yaml'
        with path.open('a') as stream:
            stream.write('dependencies:\n  flutter:\n    sdk: flutter\n')
        self.assert_rejected('check_deps', 'pure Dart core')

    def test_inline_flutter_dependency_is_rejected(self):
        path = self.root / 'dart/packages/chatweave_core/pubspec.yaml'
        with path.open('a') as stream:
            stream.write('dependencies: {flutter: {sdk: flutter}}\n')
        self.assert_rejected('check_deps', 'pure Dart core')

    def test_conditional_platform_import_is_rejected(self):
        path = self.root / 'dart/packages/chatweave_core/lib/core.dart'
        path.write_text("import 'portable.dart'\n    if (dart.library.io) 'dart:io';\n")
        self.assert_rejected('check_deps', 'core.dart:1:')

    def test_platform_channel_is_rejected(self):
        path = self.root / 'dart/packages/chatweave_core/lib/core.dart'
        path.write_text("final channel = services.MethodChannel('example');\n")
        self.assert_rejected('check_deps', 'platform channel')

    def test_axum_dependency_in_protocol_is_rejected(self):
        path = self.root / 'rust/crates/chatweave-protocol/Cargo.toml'
        with path.open('a') as stream:
            stream.write('[dependencies]\naxum = "0.8"\n')
        self.assert_rejected('check_deps', 'forbidden dependency axum')

    def test_renamed_axum_dependency_is_rejected(self):
        path = self.root / 'rust/crates/chatweave-protocol/Cargo.toml'
        with path.open('a') as stream:
            stream.write('[dependencies]\nweb = { package = "axum", version = "0.8" }\n')
        self.assert_rejected('check_deps', 'forbidden dependency axum')

    def test_transitive_runtime_is_rejected(self):
        (self.root / '.include-tokio').write_text('enabled')
        self.assert_rejected('check_deps', 'forbidden dependency tokio')

    def test_example_private_import_is_rejected(self):
        path = self.root / 'examples/demo.dart'
        path.parent.mkdir()
        path.write_text("import 'package:chatweave_core/src/internal.dart';\n")
        self.assert_rejected('check_deps', 'public package entrypoints')

    def test_business_term_in_library_is_rejected(self):
        path = self.root / 'rust/crates/chatweave-protocol/src/lib.rs'
        path.write_text('// ledger\n')
        self.assert_rejected('check_host_terms', 'lib.rs:1:')

    def test_docs_and_tool_are_outside_vocabulary_scope(self):
        (self.root / 'docs').mkdir()
        (self.root / 'docs/example.md').write_text('ledger 余额\n')
        (self.root / 'tool/example.txt').write_text('ledger 余额\n')
        result = self.run_check('check_host_terms')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
