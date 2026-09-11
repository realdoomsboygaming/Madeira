#!/usr/bin/env bash
# Build Windows PE modules using the pinned Wine fork's multiarch support.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$REPO_ROOT/toolchains/$MINGW/bin:$PATH"
PATCH="$REPO_ROOT/patches/wine-wow64-loader-arch.patch"
if ! git -C "$REPO_ROOT/wine" apply --reverse --check "$PATCH" 2>/dev/null; then
  git -C "$REPO_ROOT/wine" apply --check "$PATCH"
  git -C "$REPO_ROOT/wine" apply "$PATCH"
fi
mkdir -p "$REPO_ROOT/wine/build-wow64"
cd "$REPO_ROOT/wine/build-wow64"
../configure --enable-win64 --enable-archs=aarch64,i386 \
  --with-wine-tools=../build-macos \
  --disable-tests --without-x --without-freetype

# makedep writes the enabled module targets into the top-level all rule.
# Use those PE targets directly: macOS unix libraries contain iOS-only hooks
# and are built separately by build/ntdll-unix and build/win32u-unix.
python3 "$REPO_ROOT/build/wine-pe-targets.py" Makefile > pe-targets.txt
targets=()
while IFS= read -r target; do targets+=("$target"); done < pe-targets.txt
# Link ntdll before the full PE build: architecture-specific loader hooks must
# resolve before spending time compiling hundreds of application-facing DLLs.
make -j"$(sysctl -n hw.ncpu)" dlls/ntdll/i386-windows/ntdll.dll
make -j"$(sysctl -n hw.ncpu)" "${targets[@]}"
