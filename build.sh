#!/usr/bin/env bash
# build.sh -- concatenate src/*.gd into OrcLoader.gd
#
# Explicit ordering (not filename-based sort): the FILES list below is the
# source of truth for concat order. Dependencies flow top-down earlier
# files may not reference code defined later.

set -euo pipefail
cd "$(dirname "$0")"

SRC=src
OUT=OrcLoader.gd
TMP=$OUT.tmp

FILES=(
    # Fundamentals (header + module-scope state + log helpers)
    "$SRC/header.gd"
    "$SRC/constants.gd"
    "$SRC/logging.gd"
    # File + archive helpers (no game-specific logic)
    "$SRC/fs_archive.gd"
    # Static-init boot layer
    "$SRC/boot.gd"
    # Mod discovery + loading
    "$SRC/security_scan.gd"
    "$SRC/mod_discovery.gd"
    "$SRC/mod_loading.gd"
    "$SRC/conflict_report.gd"
    # UI
    "$SRC/ui.gd"
    # Public API (hooks + registry)
    "$SRC/hooks_api.gd"
    # Generic registry facade. Sir, We Have an Orc Problem does not expose
    # the previous target game's content-registry stack,
    # so content changes should go through hooks or explicit overrides.
    "$SRC/registry.gd"
    # Declarative setup() entry point (depends on registry _many verbs + hook_many)
    "$SRC/setup.gd"
    "$SRC/framework_wrappers.gd"
    # Codegen pipeline
    "$SRC/gdsc_detokenizer.gd"
    "$SRC/pck_enumeration.gd"
    "$SRC/rewriter.gd"
    "$SRC/hook_pack.gd"
    # Orchestration
    "$SRC/lifecycle.gd"
    "$SRC/main_menu_hook.gd"
)

# Validate every listed file exists before starting
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "ERROR: missing source file: $f" >&2; exit 1; }
done

# Concatenate
: > "$TMP"
for f in "${FILES[@]}"; do
    cat "$f" >> "$TMP"
    echo "" >> "$TMP"  # blank line between files
done

# Sanity checks on the output
extends_count=$(grep -c '^extends ' "$TMP" || true)
if [[ $extends_count -ne 1 ]]; then
    echo "ERROR: expected exactly 1 'extends' line, found $extends_count" >&2
    rm -f "$TMP"
    exit 1
fi
class_count=$(grep -c '^class_name ' "$TMP" || true)
if [[ $class_count -gt 1 ]]; then
    echo "ERROR: multiple class_name declarations: $class_count" >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$OUT"
lines=$(wc -l < "$OUT")
echo "Built $OUT: $lines lines from ${#FILES[@]} source files"
