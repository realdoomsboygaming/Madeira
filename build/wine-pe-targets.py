"""Select enabled i386 runtime targets from Wine's generated all rule."""
import re
import sys
from pathlib import Path


def targets(makefile):
    rules = re.sub(r"\\\r?\n", " ", makefile)
    enabled = set()
    for rule in re.findall(r"^all:\s*(.*)$", rules, re.MULTILINE):
        enabled.update(rule.split())
    guest = sorted(t for t in enabled if re.fullmatch(
        r"(?:dlls|programs)/[^\s]+/i386-windows/[^/]+\.(?:dll|exe|drv|cpl)", t))
    required = {f"dlls/{name}/i386-windows/{name}.dll"
                for name in ("ntdll", "kernel32", "kernelbase")}
    if missing := required.difference(guest):
        raise ValueError(f"Wine did not enable required i386 targets: {sorted(missing)}")
    host = [f"dlls/{name}/aarch64-windows/{name}.dll"
            for name in ("wow64", "wow64win")]
    if missing := set(host).difference(enabled):
        raise ValueError(f"Wine did not enable ARM64 WoW64 targets: {sorted(missing)}")
    # Build loader-critical images first, so fork integration errors surface early.
    return sorted(required) + host + [t for t in guest if t not in required]


if __name__ == "__main__":
    try:
        print("\n".join(targets(Path(sys.argv[1]).read_text())))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
