#!/usr/bin/env bash
#
# libcue/mayhem/build.sh — build lipnitsk/libcue's OSS-Fuzz harness as a sanitized libFuzzer
# target (+ a standalone reproducer), AND libcue's own CTest suite for mayhem/test.sh.
#
# The fuzzed surface is libcue's CUE-sheet PARSER (a flex/bison grammar) on attacker-controlled
# bytes: the harness NUL-terminates the input and calls cue_parse_string()/cd_delete() (oss-fuzz/
# fuzz.cpp). Inputs are raw .cue sheet text. We compile the libcue library ITSELF with
# $SANITIZER_FLAGS (via CMake) so the parser/scanner (not just the harness) is instrumented.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). flex + bison + cmake are provided by the base image.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# Always ensure the library gets SanitizerCoverage instrumentation.
# The base image exports SANITIZER_FLAGS without -fsanitize=fuzzer-no-link; append it
# unconditionally so libcue object files are instrumented regardless of base-image defaults.
case "$SANITIZER_FLAGS" in
  *fuzzer-no-link*) ;;  # already present
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac
# DEBUG_FLAGS: DWARF-3 symbols required by Mayhem triage (§6.2 item 10); clang-19 defaults to DWARF-5.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
HARNESS="$HARNESS_DIR/fuzz.cpp"

# ── 1) Build the libcue static library WITH sanitizers via CMake (instruments parser+scanner) ─────
#       BUILD_FUZZER is left OFF here: we link the fuzzer ourselves so we control the engine and can
#       also emit the standalone reproducer. The CMake lib target `cue` is what we link against.
BUILD="$SRC/mayhem-build"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DBUILD_FUZZER=OFF
cmake --build "$BUILD" --target cue -j"$MAYHEM_JOBS"

LIBCUE="$(find "$BUILD" -name 'libcue.a' -o -name 'libcue.so*' | head -1)"
[ -n "$LIBCUE" ] || LIBCUE="$BUILD/libcue.a"
INC="-I$SRC -I$BUILD"

# ── 2) libFuzzer target -> /mayhem/fuzz ───────────────────────────────────────────────────────────
#       Define FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION so the harness's own main() is compiled out
#       (libFuzzer provides main). Link against the sanitized libcue built above.
RPATH_FUZZ=""
[ "${LIBCUE##*.}" != a ] && RPATH_FUZZ="-Wl,-rpath,$(dirname "$LIBCUE")"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $INC -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION \
    "$HARNESS" $LIB_FUZZING_ENGINE "$LIBCUE" $RPATH_FUZZ \
    -o "/mayhem/fuzz"

# ── 3) standalone reproducer -> /mayhem/fuzz-standalone ───────────────────────────────────────────
#       fuzz.cpp ships its OWN command-line main() (active when the unsafe macro is NOT defined),
#       reading each file argument and feeding it to LLVMFuzzerTestOneInput — exactly the standalone
#       contract. No separate driver object needed; no libFuzzer engine here.
RPATH=""
[ "${LIBCUE##*.}" != a ] && RPATH="-Wl,-rpath,$(dirname "$LIBCUE")"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
    "$HARNESS" "$LIBCUE" $RPATH \
    -o "/mayhem/fuzz-standalone"

# ── 4) Build libcue's OWN CTest suite with NORMAL flags (clean tree) so test.sh only RUNS it. ─────
#       These are minunit known-answer tests (t/*.c): they parse fixed CUE sheets and assert exact
#       parsed values (track counts, INDEX frames, CDTEXT fields). A no-op/exit(0) patch fails them.
TESTS="$SRC/mayhem-tests"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$TESTS" -DCMAKE_BUILD_TYPE=Debug -DBUILD_FUZZER=OFF
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build "$TESTS" -j"$MAYHEM_JOBS"
echo "built libcue CTest suite in mayhem-tests/"

echo "build.sh complete:"
ls -la /mayhem/fuzz /mayhem/fuzz-standalone 2>&1 || true
