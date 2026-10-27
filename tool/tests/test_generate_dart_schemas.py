"""The generator's check mode must detect drift and never mutate outputs."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DartSchemaGeneration(unittest.TestCase):
    def test_repository_is_current(self):
        subprocess.run([sys.executable, str(ROOT / 'tool/generate_dart_schemas.py'),
                        '--check'], check=True)

    def test_check_detects_content_schema_set_and_missing_output_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'tool').mkdir()
            script = root / 'tool/generate_dart_schemas.py'
            shutil.copyfile(ROOT / 'tool/generate_dart_schemas.py', script)
            schemas = root / 'schemas/v0.1'
            schemas.mkdir(parents=True)
            source = schemas / 'test.schema.json'
            source.write_text('{"type":"string"}')
            target = root / 'dart/packages/chatweave_core/lib/src/wire_schemas.dart'
            target.parent.mkdir(parents=True)

            def run(*args):
                return subprocess.run([sys.executable, str(script), *args],
                                      capture_output=True, text=True)

            self.assertNotEqual(run('--check').returncode, 0)
            self.assertFalse(target.exists())
            self.assertEqual(run().returncode, 0)
            original = target.read_bytes()
            self.assertEqual(run('--check').returncode, 0)
            for operation in ('content', 'add', 'remove', 'output'):
                with self.subTest(operation=operation):
                    source.write_text('{"type":"number"}' if operation == 'content'
                                      else '{"type":"string"}')
                    extra = schemas / 'extra.schema.json'
                    if operation == 'add':
                        extra.write_text('{}')
                    elif extra.exists():
                        extra.unlink()
                    if operation == 'remove':
                        source.unlink()
                    target.write_bytes(original + (b'// drift\n'
                                                  if operation == 'output' else b''))
                    before = target.read_bytes()
                    self.assertNotEqual(run('--check').returncode, 0)
                    self.assertEqual(target.read_bytes(), before)
