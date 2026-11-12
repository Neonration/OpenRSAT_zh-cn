import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('prepare_dependencies', ROOT / 'tools/prepare_dependencies.py')
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)

class DependencyPreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest, cls.patch = prep.load_patch(ROOT / 'patches')
        source = (ROOT / prep.SUBMODULE / prep.SOURCE).read_bytes()
        canonical = prep.canonical(source)
        current = prep.digest(canonical)
        if current == cls.manifest['base_sha256_lf']:
            cls.base = canonical
        elif current == cls.manifest['patched_sha256_lf']:
            with tempfile.TemporaryDirectory() as tmp:
                target = Path(tmp) / prep.SOURCE
                target.parent.mkdir(parents=True)
                target.write_bytes(canonical)
                result = subprocess.run(['git', 'apply', '--reverse', '--whitespace=nowarn', '-'],
                    input=cls.patch, cwd=tmp, capture_output=True)
                if result.returncode:
                    raise RuntimeError('Could not reconstruct pristine fixture')
                cls.base = prep.canonical(target.read_bytes())
            if prep.digest(cls.base) != cls.manifest['base_sha256_lf']:
                raise RuntimeError('Pristine fixture hash mismatch')
        else:
            raise RuntimeError('Dependency source is neither expected base nor prepared version')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='openrsat-dependency-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.target = self.root / prep.SUBMODULE / prep.SOURCE
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(self.base)
        self.patch_dir = self.root / 'patches'
        shutil.copytree(ROOT / 'patches', self.patch_dir)

    def test_prepare_idempotent_and_check(self):
        with self.assertRaises(prep.PreparationError):
            prep.prepare(self.root, check=True, patch_dir=self.patch_dir)
        self.assertEqual(self.target.read_bytes(), self.base)
        prep.prepare(self.root, patch_dir=self.patch_dir)
        ready = self.target.read_bytes()
        self.assertEqual(prep.digest(prep.canonical(ready)), self.manifest['patched_sha256_lf'])
        prep.prepare(self.root, check=True, patch_dir=self.patch_dir)
        prep.prepare(self.root, patch_dir=self.patch_dir)
        self.assertEqual(self.target.read_bytes(), ready)

    def test_unknown_changes_never_overwritten(self):
        changed = self.base + b'\nlocal change\n'
        self.target.write_bytes(changed)
        with self.assertRaises(prep.PreparationError): prep.prepare(self.root, patch_dir=self.patch_dir)
        self.assertEqual(self.target.read_bytes(), changed)

    def test_corrupt_patch_and_manifest_preserve_source(self):
        patch = self.patch_dir / prep.PATCH_NAME
        patch.write_bytes(patch.read_bytes() + b'bad')
        with self.assertRaises(prep.PreparationError): prep.prepare(self.root, patch_dir=self.patch_dir)
        self.assertEqual(self.target.read_bytes(), self.base)
        shutil.copy2(ROOT / 'patches' / prep.PATCH_NAME, patch)
        manifest = self.patch_dir / prep.MANIFEST_NAME
        value = json.loads(manifest.read_text(encoding='utf8'))
        value['upstream_commit'] = 'bad'
        manifest.write_text(json.dumps(value), encoding='utf8')
        with self.assertRaises(prep.PreparationError): prep.prepare(self.root, patch_dir=self.patch_dir)
        self.assertEqual(self.target.read_bytes(), self.base)

    def test_crlf_preserved(self):
        self.target.write_bytes(self.base.replace(b'\n', b'\r\n'))
        prep.prepare(self.root, patch_dir=self.patch_dir)
        result = self.target.read_bytes()
        self.assertNotIn(b'\n', result.replace(b'\r\n', b''))
        self.assertEqual(prep.digest(prep.canonical(result)), self.manifest['patched_sha256_lf'])

    def test_missing_file_rejected(self):
        self.target.unlink()
        with self.assertRaises(prep.PreparationError): prep.prepare(self.root, patch_dir=self.patch_dir)
        self.assertFalse(self.target.exists())

    def test_changed_during_prepare_preserved(self):
        original = prep.patched_bytes
        def racing(source, patch, expected):
            result = original(source, patch, expected)
            self.target.write_bytes(b'concurrent edit')
            return result
        prep.patched_bytes = racing
        try:
            with self.assertRaises(prep.PreparationError): prep.prepare(self.root, patch_dir=self.patch_dir)
            self.assertEqual(self.target.read_bytes(), b'concurrent edit')
        finally:
            prep.patched_bytes = original

if __name__ == '__main__': unittest.main()
