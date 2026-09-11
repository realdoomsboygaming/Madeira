import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "wine_pe_targets", Path(__file__).resolve().parents[1] / "build/wine-pe-targets.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WineTargetsTests(unittest.TestCase):
    def test_selects_enabled_pe_images_without_unix_targets(self):
        required = [f"dlls/{name}/i386-windows/{name}.dll"
                    for name in ("ntdll", "kernelbase", "kernel32")]
        host = [f"dlls/{name}/aarch64-windows/{name}.dll"
                for name in ("wow64", "wow64win")]
        program = "programs/notepad/i386-windows/notepad.exe"
        makefile = "all: " + (" \\" + "\n ").join(required + host + [program, "dlls/ntdll/ntdll.so", "server/wineserver"])
        makefile += "\ndlls/disabled/i386-windows/disabled.dll: ignored.o\n"
        self.assertEqual(set(module.targets(makefile)), set(required + host + [program]))

    def test_rejects_configuration_without_i386(self):
        with self.assertRaisesRegex(ValueError, "required i386"):
            module.targets("all: dlls/ntdll/aarch64-windows/ntdll.dll\n")


if __name__ == "__main__":
    unittest.main()
