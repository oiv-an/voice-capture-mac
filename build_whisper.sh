#!/usr/bin/env bash
#
# build_whisper.sh — собирает whisper.cpp + ggml в статическую библиотеку
# напрямую через clang++ (CPU + Accelerate), БЕЗ cmake, brew и sudo.
#
# Результат:
#   Vendor/install/lib/libwhisper_combined.a
#   Vendor/install/include/*.h
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHISPER="$ROOT/Vendor/whisper.cpp"
OUT="$ROOT/Vendor/install"
OBJ="$ROOT/Vendor/.obj"

GGML_SRC="$WHISPER/ggml/src"
GGML_INC="$WHISPER/ggml/include"
WHISPER_SRC="$WHISPER/src"
WHISPER_INC="$WHISPER/include"

rm -rf "$OBJ" "$OUT"
mkdir -p "$OBJ" "$OUT/lib" "$OUT/include"

# Целевая архитектура
ARCH="$(uname -m)"   # arm64 / x86_64

# Общие include-пути
INCLUDES=(
  -I"$GGML_INC"
  -I"$GGML_SRC"
  -I"$GGML_SRC/ggml-cpu"
  -I"$WHISPER_INC"
  -I"$WHISPER_SRC"
)

# Дефайны: включаем CPU backend + Accelerate (BLAS), отключаем прочие бэкенды.
# GGML_USE_CPU — статическая регистрация CPU backend.
# GGML_USE_ACCELERATE / GGML_BLAS — ускорение через Apple Accelerate.
# Версионные макросы обычно генерирует cmake; задаём вручную.
WHISPER_VER="$(git -C "$WHISPER" describe --tags --always 2>/dev/null || echo "unknown")"
WHISPER_COMMIT="$(git -C "$WHISPER" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

DEFINES=(
  -DGGML_USE_CPU
  -DGGML_USE_ACCELERATE
  -DACCELERATE_NEW_LAPACK
  -DACCELERATE_LAPACK_ILP64
  -DNDEBUG
  -DGGML_VERSION="\"$WHISPER_VER\""
  -DGGML_COMMIT="\"$WHISPER_COMMIT\""
  -DWHISPER_VERSION="\"$WHISPER_VER\""
)

CFLAGS=(-O3 -fPIC -std=c11 "${DEFINES[@]}" "${INCLUDES[@]}")
CXXFLAGS=(-O3 -fPIC -std=c++17 "${DEFINES[@]}" "${INCLUDES[@]}")

if [[ "$ARCH" == "arm64" ]]; then
  CFLAGS+=(-mcpu=apple-m1)
  CXXFLAGS+=(-mcpu=apple-m1)
fi

CC="clang"
CXX="clang++"

compile() {
  local src="$1"
  local ext="${src##*.}"
  local obj="$OBJ/$(echo "$src" | sed 's#[/.]#_#g').o"
  if [[ "$ext" == "c" ]]; then
    echo "  CC  $src"
    "$CC" "${CFLAGS[@]}" -c "$src" -o "$obj"
  else
    echo "  CXX $src"
    "$CXX" "${CXXFLAGS[@]}" -c "$src" -o "$obj"
  fi
  echo "$obj"
}

OBJECTS=()

echo "==> Compiling ggml core"
for f in \
  "$GGML_SRC/ggml.c" \
  "$GGML_SRC/ggml-alloc.c" \
  "$GGML_SRC/ggml-quants.c" \
  "$GGML_SRC/ggml-threading.cpp" \
  "$GGML_SRC/ggml-backend.cpp" \
  "$GGML_SRC/ggml-backend-reg.cpp" \
  "$GGML_SRC/ggml-backend-meta.cpp" \
  "$GGML_SRC/ggml-backend-dl.cpp" \
  "$GGML_SRC/ggml-opt.cpp" \
  "$GGML_SRC/gguf.cpp"
do
  [[ -f "$f" ]] || continue
  OBJECTS+=("$(compile "$f" | tail -1)")
done

echo "==> Compiling ggml-cpu backend"
CPU="$GGML_SRC/ggml-cpu"
for f in \
  "$CPU/ggml-cpu.c" \
  "$CPU/ggml-cpu.cpp" \
  "$CPU/binary-ops.cpp" \
  "$CPU/unary-ops.cpp" \
  "$CPU/ops.cpp" \
  "$CPU/vec.cpp" \
  "$CPU/quants.c" \
  "$CPU/repack.cpp" \
  "$CPU/traits.cpp" \
  "$CPU/hbm.cpp" \
  "$CPU/llamafile/sgemm.cpp"
do
  [[ -f "$f" ]] && OBJECTS+=("$(compile "$f" | tail -1)")
done

echo "==> Compiling ggml-cpu arch ($ARCH)"
if [[ "$ARCH" == "arm64" ]]; then
  ARCHDIR="$CPU/arch/arm"
else
  ARCHDIR="$CPU/arch/x86"
fi
for f in "$ARCHDIR"/*.c "$ARCHDIR"/*.cpp; do
  [[ -f "$f" ]] && OBJECTS+=("$(compile "$f" | tail -1)")
done

echo "==> Compiling whisper"
OBJECTS+=("$(compile "$WHISPER_SRC/whisper.cpp" | tail -1)")

echo "==> Archiving libwhisper_combined.a"
ar rcs "$OUT/lib/libwhisper_combined.a" "${OBJECTS[@]}"

echo "==> Copying headers"
cp "$WHISPER_INC/whisper.h" "$OUT/include/"
cp "$GGML_INC/ggml.h" "$OUT/include/"
cp "$GGML_INC/ggml-cpu.h" "$OUT/include/"
cp "$GGML_INC/ggml-backend.h" "$OUT/include/"
cp "$GGML_INC/ggml-alloc.h" "$OUT/include/"

echo ""
echo "DONE: $OUT/lib/libwhisper_combined.a"
ls -lh "$OUT/lib/libwhisper_combined.a"
