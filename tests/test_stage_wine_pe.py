import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "build" / "stage-wine-pe.py"
SPEC = importlib.util.spec_from_file_location("stage_wine_pe", SCRIPT)
assert SPEC and SPEC.loader
stage_wine_pe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stage_wine_pe)


def _write_pe(path: Path, machine: int, payload: bytes = b"payload") -> None:
    data = bytearray(0x80)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x40)
    data[0x40:0x44] = b"PE\0\0"
    struct.pack_into("<H", data, 0x44, machine)
    data.extend(payload)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _i386_fixture(root: Path, name: str, *, payload: bytes = b"payload") -> Path:
    path = root / "dlls" / name.removesuffix(Path(name).suffix) / "i386-windows" / name
    _write_pe(path, 0x014C, payload)
    return path


def _required_i386(root: Path) -> None:
    for name in ("ntdll.dll", "kernel32.dll", "kernelbase.dll"):
        _i386_fixture(root, name)


class StageWinePETest(unittest.TestCase):
    def test_stages_runtime_extensions_and_excludes_build_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tmp_path = Path(temporary)
            source = tmp_path / "build"
            destination = tmp_path / "resources"
            _required_i386(source)
            _i386_fixture(source, "tool.exe")
            _i386_fixture(source, "driver.drv")
            _i386_fixture(source, "control.cpl")
            _i386_fixture(source, "ignored.o")
            _i386_fixture(source, "ignored.a")
            _i386_fixture(source, "ignored.so")
            (source / "misc" / "i386-windows" / "nested").mkdir(parents=True)
            _write_pe(
                source / "misc" / "i386-windows" / "nested" / "not-a-leaf.dll",
                0x014C,
            )
            (destination / "i386-windows" / "README.md").parent.mkdir(parents=True)
            (destination / "i386-windows" / "README.md").write_text(
                "keep", encoding="utf-8"
            )

            staged = stage_wine_pe.stage_runtime_pe(source, destination, "i386")

            names = {path.name for path in staged}
            self.assertTrue(
                {
                    "ntdll.dll",
                    "kernel32.dll",
                    "kernelbase.dll",
                    "tool.exe",
                    "driver.drv",
                    "control.cpl",
                }.issubset(names)
            )
            self.assertFalse((destination / "i386-windows" / "ignored.o").exists())
            self.assertFalse((destination / "i386-windows" / "ignored.a").exists())
            self.assertFalse((destination / "i386-windows" / "ignored.so").exists())
            self.assertFalse(
                (destination / "i386-windows" / "not-a-leaf.dll").exists()
            )
            self.assertEqual(
                (destination / "i386-windows" / "README.md").read_text(
                    encoding="utf-8"
                ),
                "keep",
            )

    def test_rejects_wrong_machine(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tmp_path = Path(temporary)
            source = tmp_path / "build"
            _required_i386(source)
            wrong = _i386_fixture(source, "wrong.dll")
            _write_pe(wrong, 0xAA64)

            with self.assertRaisesRegex(stage_wine_pe.StageError, "wrong PE machine"):
                stage_wine_pe.stage_runtime_pe(source, tmp_path / "resources", "i386")

            self.assertEqual(stage_wine_pe.read_pe_machine(wrong), 0xAA64)

    def test_rejects_conflicting_duplicate_basenames(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tmp_path = Path(temporary)
            source = tmp_path / "build"
            _required_i386(source)
            _i386_fixture(source, "same.dll", payload=b"one")
            _write_pe(
                source / "dlls" / "other" / "i386-windows" / "same.dll",
                0x014C,
                b"two",
            )

            with self.assertRaisesRegex(
                stage_wine_pe.StageError, "duplicate runtime basename"
            ):
                stage_wine_pe.stage_runtime_pe(source, tmp_path / "resources", "i386")

    def test_aarch64_stages_only_wow64_modules(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tmp_path = Path(temporary)
            source = tmp_path / "build"
            for name in ("wow64.dll", "wow64win.dll", "other.exe"):
                path = (
                    source
                    / "dlls"
                    / name.removesuffix(Path(name).suffix)
                    / "aarch64-windows"
                    / name
                )
                _write_pe(path, 0xAA64)

            destination = tmp_path / "resources"
            stage_wine_pe.stage_runtime_pe(source, destination, "aarch64")

            self.assertTrue((destination / "aarch64-windows" / "wow64.dll").is_file())
            self.assertTrue(
                (destination / "aarch64-windows" / "wow64win.dll").is_file()
            )
            self.assertFalse((destination / "aarch64-windows" / "other.exe").exists())

    def test_rejects_malformed_runtime_file_and_missing_required_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tmp_path = Path(temporary)
            source = tmp_path / "build"
            _required_i386(source)
            malformed = source / "dlls" / "bad" / "i386-windows" / "bad.dll"
            malformed.parent.mkdir(parents=True)
            malformed.write_bytes(b"not a PE")

            with self.assertRaisesRegex(stage_wine_pe.StageError, "malformed PE"):
                stage_wine_pe.stage_runtime_pe(source, tmp_path / "resources", "i386")

            clean_source = tmp_path / "clean-build"
            _i386_fixture(clean_source, "ntdll.dll")
            _i386_fixture(clean_source, "kernel32.dll")
            with self.assertRaisesRegex(
                stage_wine_pe.StageError,
                "missing required i386 runtime files: kernelbase.dll",
            ):
                stage_wine_pe.stage_runtime_pe(
                    clean_source, tmp_path / "resources", "i386"
                )


if __name__ == "__main__":
    unittest.main()
