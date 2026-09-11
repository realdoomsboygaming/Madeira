This directory is populated by the i386 WoW64 stage in the GitHub Actions build.

It contains Wine's 32-bit x86 PE modules. The 64-bit ARM64 host modules remain
in `aarch64-windows`; Wine's WoW64 loader uses `aarch64-windows/xtajit.dll` for
the FEX x86 emulator.
