"""Exercise relocation with real Mach-O binaries, without installed Homebrew libraries."""

import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("bundler", ROOT / "Scripts/bundle-libmpv.py")
bundler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundler)


class BundlingTests(unittest.TestCase):
    def setUp(self):
        root = ROOT / "DerivedData/BundleTests"
        root.mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(dir=root))
        self.libraries = self.directory / "vendor"
        self.libraries.mkdir()
        self.source = self.directory / "Input.app"
        (self.source / "Contents/MacOS").mkdir(parents=True)
        (self.source / "Contents/Resources").mkdir()
        (self.source / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Example", "LSMinimumSystemVersion": "14.0"}))
        leaf = self.libraries / "libleaf.dylib"
        self.compile("int leaf(void) { return 7; }", leaf,
                     "-dynamiclib", "-install_name", str(leaf))
        mpv = self.libraries / "libmpv.2.dylib"
        self.compile("extern int leaf(void); int mpv(void) { return leaf(); }", mpv,
                     "-dynamiclib", "-install_name", str(mpv), str(leaf))
        self.compile("extern int mpv(void); int main(void) { return mpv() == 7 ? 0 : 1; }",
                     self.source / "Contents/MacOS/Example", str(mpv))

    def compile(self, code, output, *flags):
        source = self.directory / (output.name + ".c")
        source.write_text(code)
        subprocess.run(["xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=14.0",
                        str(source), *flags, "-o", str(output)], check=True, capture_output=True)

    def test_transitive_libraries_are_portable_and_inputs_unchanged(self):
        original = {p: p.read_bytes() for p in self.libraries.glob("*.dylib")}
        output = self.directory / "Output.app"
        bundler.bundle(self.source, self.libraries, output)
        self.assertEqual(bundler.verify(output), 2)
        for path, data in original.items():
            self.assertEqual(path.read_bytes(), data)
        for path in (output / "Contents/Frameworks").glob("*.dylib"):
            subprocess.run(["codesign", "--force", "--sign", "-", str(path)], check=True,
                           capture_output=True)
        binary = output / "Contents/MacOS/Example"
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True,
                       capture_output=True)
        # Run from an unrelated directory with no dynamic-library environment override.
        subprocess.run([str(binary)], cwd="/", env={"PATH": "/usr/bin:/bin"}, check=True)

    def test_missing_dependency_and_existing_destination_are_rejected(self):
        empty = self.directory / "empty"
        empty.mkdir()
        with self.assertRaisesRegex(ValueError, "Missing vendored dependency"):
            bundler.bundle(self.source, empty, self.directory / "Missing.app")
        self.assertFalse((self.directory / "Missing.app").exists())
        with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
            bundler.bundle(self.source, self.libraries, self.source)

    def test_newer_os_dependency_is_rejected(self):
        info = self.source / "Contents/Info.plist"
        data = plistlib.loads(info.read_bytes())
        data["LSMinimumSystemVersion"] = "13.0"
        info.write_bytes(plistlib.dumps(data))
        with self.assertRaisesRegex(ValueError, "requires a newer macOS"):
            bundler.bundle(self.source, self.libraries, self.directory / "Unsupported.app")


if __name__ == "__main__":
    unittest.main()
