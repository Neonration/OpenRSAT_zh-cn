import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepare_fpc_darwin", ROOT / "tools/prepare_fpc_darwin.py")
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


class FpcBackportTests(unittest.TestCase):
    def test_unknown_source_is_not_partially_modified(self):
        with tempfile.TemporaryDirectory() as temp:
            compiler = Path(temp) / "compiler"
            compiler.mkdir()
            files = [compiler / name for name in ("nflw.pas", "pstatmnt.pas", "pexpr.pas")]
            files[0].write_text(
                "                        labelsym.nonlocal:=true;\n"
                "                        exclude(current_procinfo.procdef.procoptions,po_inline);\n",
                encoding="utf-8",
            )
            files[1].write_text("unexpected source\n", encoding="utf-8")
            files[2].write_text("untouched\n", encoding="utf-8")
            before = [p.read_bytes() for p in files]
            with self.assertRaises(ValueError):
                patcher.main(Path(temp))
            self.assertEqual(before, [p.read_bytes() for p in files])


if __name__ == "__main__":
    unittest.main()
