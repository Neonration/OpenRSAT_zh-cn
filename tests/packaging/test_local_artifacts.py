"""Offline packaging contract tests; no network, package installation or AD needed.

Run: python -m unittest discover -s tests/packaging -v
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class LocalArtifactPackagingTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[2]
        self.bash = shutil.which("bash")
        if os.name == "nt":
            git = shutil.which("git")
            if git:
                candidate = Path(git).parent.parent / "bin/bash.exe"
                if candidate.is_file():
                    self.bash = str(candidate)
        if not self.bash:
            self.skipTest("Bash is required (Git Bash on Windows).")
        self.temp = tempfile.TemporaryDirectory(prefix="openrsat packaging ")
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        self.source = self.root / "source tree"
        shutil.copytree(self.repo / "packaging/linux", self.source / "packaging/linux")
        # A Windows checkout must also produce a valid RPM build shell script.
        spec = self.source / "packaging/linux/rpm/OpenRSAT.spec"
        spec.write_bytes(spec.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
        postinst = self.source / "packaging/linux/deb/postinst"
        postinst.write_bytes(postinst.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
        shutil.copytree(self.repo / "languages", self.source / "languages")
        self.output = self.root / "output directory"
        self.records = self.root / "tool records"
        self.work = self.root / "temporary working directories"
        self.stubs = self.root / "mock tools"
        for directory in (self.output, self.records, self.work, self.stubs):
            directory.mkdir()
        self.binary = self.root / "local current branch binary"
        self.binary.write_bytes(b"LOCAL-FORK-BINARY\x00\xff\n")
        self.icon = self.root / "test icon.png"
        self.icon.write_bytes(b"TEST-ICON")
        self._stub("wget", 'echo NETWORK_NOT_ALLOWED >&2; exit 99')
        self._stub("curl", 'echo NETWORK_NOT_ALLOWED >&2; exit 99')
        self._stub("dpkg-deb", r'''
[ "${FAIL_PACKAGER:-0}" = 0 ] || exit 42
[ "$1" = --root-owner-group ] && [ "$2" = --build ]
root=$3
cp "$root/opt/openrsat/OpenRSAT" "$RECORD_DIR/deb-binary"
cp "$root/DEBIAN/control" "$RECORD_DIR/deb-control"
test -x "$root/DEBIAN/postinst"
cp "$root/DEBIAN/postinst" "$RECORD_DIR/deb-postinst"
cp -R "$root/usr/share/openrsat/locale" "$RECORD_DIR/deb-locale"
cp "$root/opt/openrsat/OpenRSAT" "$4"
''')
        self._stub("rpmbuild", r'''
[ "${FAIL_PACKAGER:-0}" = 0 ] || exit 42
while [ "$#" -gt 0 ]; do
  case "$1" in
    --define)
      case "$2" in
        "_topdir "*) topdir=${2#_topdir } ;;
        "_rpmarch "*) arch=${2#_rpmarch } ;;
      esac
      shift 2 ;;
    --target) target=$2; shift 2 ;;
    --buildroot) shift 2 ;;
    *) shift ;;
  esac
done
[ "$target" = "$arch" ]
cp "$topdir/SOURCES/OpenRSAT" "$RECORD_DIR/rpm-binary"
printf '%s' "$arch" > "$RECORD_DIR/rpm-arch"
cp "$topdir/SPECS/OpenRSAT.spec" "$RECORD_DIR/rpm-spec"
mkdir "$RECORD_DIR/rpm-locale"
cp "$topdir"/SOURCES/OpenRSAT.*.po "$RECORD_DIR/rpm-locale/"
mkdir -p "$topdir/RPMS/$arch"
cp "$topdir/SOURCES/OpenRSAT" "$topdir/RPMS/$arch/OpenRSAT-test.$arch.rpm"
''')

    def _stub(self, name, body):
        path = self.stubs / name
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body + "\n", encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def _shell_path(self, path):
        if os.name == "nt":
            return subprocess.check_output([self.bash, "-c", 'cygpath -u "$1"', "--", str(path)], text=True).strip()
        return str(path)

    def _run(self, kind, args, fail_packager=False):
        script = self.source / "packaging/linux" / kind / "build.sh"
        command = 'export PATH="$1:$PATH" TMPDIR="$2" RECORD_DIR="$3" FAIL_PACKAGER="$4"; shift 4; exec bash "$@"'
        return subprocess.run(
            [self.bash, "--noprofile", "--norc", "-c", command, "--",
             self._shell_path(self.stubs), self._shell_path(self.work), self._shell_path(self.records),
             "1" if fail_packager else "0", self._shell_path(script), *args],
            cwd=self.output, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=20,
        )

    def _args(self, arch="arm64"):
        # Inputs are relative to the caller, not to the script's directory.
        return ["0.4.594", arch, "../test icon.png", "../local current branch binary"]

    def test_local_binary_catalogs_and_architecture(self):
        for kind in ("deb", "rpm"):
            with self.subTest(kind=kind):
                result = self._run(kind, self._args())
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual((self.records / f"{kind}-binary").read_bytes(), self.binary.read_bytes())
                catalogs = sorted((self.source / "languages").glob("OpenRSAT.*.po"))
                self.assertEqual(len(list((self.records / f"{kind}-locale").glob("*.po"))), len(catalogs))
                for catalog in catalogs:
                    self.assertEqual((self.records / f"{kind}-locale" / catalog.name).read_bytes(), catalog.read_bytes())
                self.assertEqual(list(self.work.iterdir()), [], "The private build directory must be removed.")
        self.assertIn("Architecture: arm64", (self.records / "deb-control").read_text())
        self.assertNotIn(b"\r", (self.records / "deb-postinst").read_bytes())
        self.assertEqual((self.records / "rpm-arch").read_text(), "aarch64")
        self.assertIn("BuildArch:      %{_rpmarch}", (self.records / "rpm-spec").read_text())
        self.assertNotIn(b"\r", (self.records / "rpm-spec").read_bytes())
        self.assertEqual((self.output / "OpenRSAT-0.4.594-arm64.deb").read_bytes(), self.binary.read_bytes())
        self.assertEqual((self.output / "OpenRSAT-test.aarch64.rpm").read_bytes(), self.binary.read_bytes())

    def test_invalid_or_missing_inputs_fail_without_packaging(self):
        cases = [self._args()[:3], ["0.4.594", "invalid", *self._args()[2:]],
                 ["bad/version", *self._args()[1:]],
                 [*self._args()[:3], "missing binary"],
                 [*self._args()[:2], "missing icon", self._args()[3]]]
        for kind in ("deb", "rpm"):
            for args in cases:
                with self.subTest(kind=kind, args=args):
                    result = self._run(kind, args)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(list(self.records.iterdir()), [])
                    self.assertEqual(list(self.work.iterdir()), [])

    def test_packager_failure_propagates_and_cleans_private_directory(self):
        for kind in ("deb", "rpm"):
            with self.subTest(kind=kind):
                result = self._run(kind, self._args(), fail_packager=True)
                self.assertEqual(result.returncode, 42, result.stdout)
                self.assertEqual(list(self.work.iterdir()), [])
                self.assertEqual(list(self.output.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
