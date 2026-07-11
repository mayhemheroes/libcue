#!/usr/bin/env bash
#
# libcue/mayhem/test.sh — RUN libcue's own test suite (built by mayhem/build.sh with normal flags)
# and emit a CTRF summary. exit 0 iff no test failed.
#
# BEHAVIORAL oracle (§6.3 anti-reward-hacking): each test binary (standard_cue, single_file_idx_00,
# multiple_files, noncompliant, issue10, 99_tracks) is run DIRECTLY and its stdout is checked for
# known-answer strings such as "All tests passed!". A no-op / "exit(0)" patch produces EMPTY output;
# the grep assertions fail; the CTRF reports failed>0; this script exits non-zero. Merely checking
# the exit code (ctest-only approach) is insufficient because ctest only sees the exit code and a
# neutered binary also exits 0. This script does NOT compile — it only runs pre-built binaries.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "libcue-tests" 0 1 0; exit 2
fi

passed=0
failed=0

# run_test <binary> [working_dir] [expected_stdout_pattern]
# Runs the binary, greps stdout for the expected pattern (default: "All tests passed!").
# BEHAVIORAL: neutered binaries emit nothing; grep fails; test is marked failed.
run_test() {
  local name="$1"
  local wdir="${2:-$BUILDDIR}"
  local pattern="${3:-All tests passed!}"
  local bin="$BUILDDIR/$name"

  if [ ! -x "$bin" ]; then
    echo "FAIL $name: binary not found at $bin" >&2
    failed=$(( failed + 1 ))
    return
  fi

  local out
  out="$(cd "$wdir" && "$bin" 2>&1)" && rc=0 || rc=$?
  echo "--- $name ---"
  printf '%s\n' "$out"

  # BEHAVIORAL assertion: stdout must contain the expected pattern.
  # A neutered binary produces empty stdout; this grep then fails regardless of exit code.
  if printf '%s\n' "$out" | grep -qF "$pattern"; then
    echo "PASS $name"
    passed=$(( passed + 1 ))
  else
    echo "FAIL $name: expected output '$pattern' not found (got: $(printf '%s' "$out" | head -3))"
    failed=$(( failed + 1 ))
  fi
}

echo "=== running libcue test suite from $BUILDDIR ==="

# Run each test binary directly, checking printed output (not just exit code).
# Tests that need a specific working directory (for relative .cue file paths) get it explicitly.
run_test "standard_cue"       "$BUILDDIR"          "All tests passed!"
run_test "single_file_idx_00" "$BUILDDIR"          "All tests passed!"
run_test "multiple_files"     "$BUILDDIR"          "All tests passed!"
run_test "noncompliant"       "$BUILDDIR"          "All tests passed!"
run_test "issue10"            "$SRC/t"             "All tests passed!"
run_test "99_tracks"          "$SRC/t"             "All tests passed!"

echo ""
echo "=== results: passed=$passed failed=$failed ==="
emit_ctrf "libcue-tests" "$passed" "$failed" 0
