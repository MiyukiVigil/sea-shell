#!/bin/sh
# sea-shell — fast developer & CI health check:
#   1. Shell script syntax (`sh -n`)
#   2. Python syntax (`py_compile`)
#   3. QML parse / syntax check (`qmllint`, filtering expected Quickshell module warnings)
#   4. Unit tests (`unittest`)
#
# Usage: sea-check.sh [--quick]   (--quick skips unittest)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

fail=0

echo "[1/4] Shell scripts (sh -n)..."
sh_count=0
for f in "$ROOT"/quickshell/scripts/*/*.sh "$ROOT"/install.sh "$ROOT"/uninstall.sh; do
    [ -f "$f" ] || continue
    sh_count=$((sh_count + 1))
    if ! sh -n "$f" 2>&1; then
        echo "  FAIL: $f"
        fail=1
    fi
done
echo "  Checked $sh_count shell scripts."

echo "[2/4] Python scripts (py_compile)..."
py_count=0
for f in "$ROOT"/quickshell/scripts/*/*.py; do
    [ -f "$f" ] || continue
    py_count=$((py_count + 1))
    if ! python3 -m py_compile "$f" 2>&1; then
        echo "  FAIL: $f"
        fail=1
    fi
done
echo "  Checked $py_count Python scripts."

echo "[3/4] QML syntax (qmllint)..."
QMLLINT="$(command -v qmllint || command -v qmllint-qt6 || true)"
[ -z "$QMLLINT" ] && [ -x /usr/lib/qt6/bin/qmllint ] && QMLLINT=/usr/lib/qt6/bin/qmllint
if [ -n "$QMLLINT" ]; then
    qml_count=0
    qml_errs=0
    for f in "$ROOT"/quickshell/ui/*.qml; do
        [ -f "$f" ] || continue
        qml_count=$((qml_count + 1))
        out=$("$QMLLINT" --bare "$f" 2>&1 || true)
        # Only flag hard syntax / parse errors (Quickshell imports aren't in Qt's default import path).
        bad=$(printf '%s\n' "$out" | grep -E 'Error:|Syntax error|Expected token|Unexpected token' | grep -v 'Failed to import' || true)
        if [ -n "$bad" ]; then
            echo "  FAIL: $f"
            printf '%s\n' "$bad" | sed 's/^/    /'
            qml_errs=$((qml_errs + 1))
            fail=1
        fi
    done
    echo "  Checked $qml_count QML files ($qml_errs syntax errors)."
else
    echo "  Skipped (qmllint not installed)."
fi

if [ "$QUICK" = 0 ] && [ -d "$ROOT/tests" ]; then
    echo "[4/4] Unit tests..."
    if ! PYTHONPATH="$ROOT/tests" python3 -m unittest \
        "$ROOT/tests/test_sddm.py" \
        "$ROOT/tests/test_install_migration.py" \
        "$ROOT/tests/test_uninstall_restore.py" \
        "$ROOT/tests/test_settings_navigation.py" \
        "$ROOT/tests/test_update_flow.py"; then
        fail=1
    fi
else
    echo "[4/4] Unit tests skipped."
fi

if [ "$fail" = 0 ]; then
    echo "sea-check: ALL PASS"
    exit 0
else
    echo "sea-check: FAILED" >&2
    exit 1
fi
