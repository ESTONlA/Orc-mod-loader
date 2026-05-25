#!/usr/bin/env bash
# OrcKit installer (Linux)
# Mirrors windows-installer.bat:
#   - Copies local OrcLoader.gd into the game folder
#   - Copies local override.cfg template, merges into user's existing override.cfg
#     (forces template key values, preserves user sections/keys)
#   - Creates mods/ directory if missing

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_MODLOADER="$SCRIPT_DIR/OrcLoader.gd"
LOCAL_OVERRIDE="$SCRIPT_DIR/override.cfg"

echo
echo "=== OrcKit Installer ==="
echo

# --- Find game installation ---
GAME_PATH=""
CANDIDATE_PATHS=(
    "$HOME/.steam/steam/steamapps/common/Sir, We Have an Orc Problem Playtest"
    "$HOME/.local/share/Steam/steamapps/common/Sir, We Have an Orc Problem Playtest"
    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/common/Sir, We Have an Orc Problem Playtest"
    "/mnt/steam/steamapps/common/Sir, We Have an Orc Problem Playtest"
)

for p in "${CANDIDATE_PATHS[@]}"; do
    if [[ -f "$p/swhaop_playtest.x86_64" || -f "$p/swhaop_playtest.sh" || -f "$p/swhaop_playtest.exe" ]]; then
        GAME_PATH="$p"
        break
    fi
done

if [[ -z "$GAME_PATH" ]]; then
    echo "Could not find OrcKit automatically."
    read -r -p "Enter the path to your game folder (containing swhaop_playtest.x86_64 or swhaop_playtest.exe): " GAME_PATH
    GAME_PATH="${GAME_PATH/#\~/$HOME}"
    if [[ ! -f "$GAME_PATH/swhaop_playtest.x86_64" && ! -f "$GAME_PATH/swhaop_playtest.sh" && ! -f "$GAME_PATH/swhaop_playtest.exe" ]]; then
        echo "ERROR: OrcKit executable not found at: $GAME_PATH"
        exit 1
    fi
fi

echo "Found game at: $GAME_PATH"

MODLOADER_DEST="$GAME_PATH/OrcLoader.gd"
OVERRIDE_PATH="$GAME_PATH/override.cfg"
MODS_PATH="$GAME_PATH/mods"

if [[ ! -f "$LOCAL_MODLOADER" ]]; then
    echo "ERROR: OrcLoader.gd not found next to this installer:"
    echo "  $LOCAL_MODLOADER"
    exit 1
fi
if [[ ! -f "$LOCAL_OVERRIDE" ]]; then
    echo "ERROR: override.cfg not found next to this installer:"
    echo "  $LOCAL_OVERRIDE"
    exit 1
fi

# --- Install OrcLoader.gd ---
if ! cp -f "$LOCAL_MODLOADER" "$MODLOADER_DEST" || [[ ! -f "$MODLOADER_DEST" ]]; then
    echo "ERROR: Could not copy OrcLoader.gd to $MODLOADER_DEST"
    echo "  Likely cause: missing write permission, destination on a read-only filesystem,"
    echo "  or the file is locked by a running game process."
    exit 1
fi
echo "Installed OrcLoader.gd to game folder"

# --- Stage override.cfg template ---
OVERRIDE_TMP="$OVERRIDE_PATH.template"
rm -f "$OVERRIDE_TMP"
if ! cp -f "$LOCAL_OVERRIDE" "$OVERRIDE_TMP" || [[ ! -s "$OVERRIDE_TMP" ]]; then
    echo "ERROR: Failed to stage override.cfg template"
    exit 1
fi

# --- Install/merge override.cfg ---
# For keys the template specifies, force the template's value (overwriting
# outdated user values like a stale OrcKit path). Keys the user has that
# the template doesn't specify are left untouched. Uses awk (POSIX-standard
# on any system with a shell).
#
# Two-pass algorithm:
#   Pass 1: walk template, record section/key -> value.
#   Pass 2: walk user file; when a section's key matches a template key,
#           rewrite with template's value. Otherwise emit as-is. At each
#           section boundary, append any template keys not present in
#           that section of the user file. Append any template sections
#           the user file lacks at the very end.
merge_override() {
    local user_file="$1"
    local tmpl_file="$2"
    local out_file="$3"
    awk -v tmpl_file="$tmpl_file" '
    function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
    function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
    function trim(s)  { return ltrim(rtrim(s)) }

    BEGIN {
        # Pass 1: parse template into tmpl_kv[sec SUBSEP key] = value.
        # Track section order and per-section key order for appending missing entries.
        tmpl_sec_count = 0
        cur_sec = ""
        while ((getline line < tmpl_file) > 0) {
            s = trim(line)
            if (s ~ /^\[.+\]$/) {
                cur_sec = substr(s, 2, length(s) - 2)
                if (!(cur_sec in tmpl_sec_seen)) {
                    tmpl_sec_seen[cur_sec] = 1
                    tmpl_sec_order[++tmpl_sec_count] = cur_sec
                    tmpl_key_count[cur_sec] = 0
                }
                continue
            }
            if (cur_sec == "" || s == "" || s ~ /^[;#]/) continue
            eq = index(s, "=")
            if (eq == 0) continue
            k = trim(substr(s, 1, eq - 1))
            v = substr(s, eq + 1)
            if (!((cur_sec SUBSEP k) in tmpl_kv)) {
                tmpl_kv[cur_sec SUBSEP k] = v
                tmpl_key_order[cur_sec, ++tmpl_key_count[cur_sec]] = k
            }
        }
        close(tmpl_file)

        # State for pass 2: accumulate lines per section so we can append
        # missing template keys at the section boundary.
        buf_count = 0
        user_cur_sec = ""
    }

    # Pass 2: every input line is from the user file.
    {
        s = trim($0)
        if (s ~ /^\[.+\]$/) {
            flush_section()
            user_cur_sec = substr(s, 2, length(s) - 2)
            user_sec_seen[user_cur_sec] = 1
            buf[++buf_count] = $0
            next
        }
        buf[++buf_count] = $0
    }

    END {
        flush_section()
        # Append template sections the user did not have.
        for (i = 1; i <= tmpl_sec_count; i++) {
            sec = tmpl_sec_order[i]
            if (sec in user_sec_seen) continue
            print ""
            print "[" sec "]"
            for (j = 1; j <= tmpl_key_count[sec]; j++) {
                k = tmpl_key_order[sec, j]
                print k "=" tmpl_kv[sec SUBSEP k]
            }
        }
    }

    # Emit buffered section contents with key rewrites, then append any
    # template keys missing from this section.
    function flush_section(    i, ln, s2, eq, k, seen_keys_local, j, tk) {
        delete seen_keys_local
        for (i = 1; i <= buf_count; i++) {
            ln = buf[i]
            s2 = trim(ln)
            if (s2 ~ /^\[.+\]$/) { print ln; continue }
            if (s2 == "" || s2 ~ /^[;#]/) { print ln; continue }
            eq = index(s2, "=")
            if (eq == 0) { print ln; continue }
            k = trim(substr(s2, 1, eq - 1))
            if (user_cur_sec != "" && ((user_cur_sec SUBSEP k) in tmpl_kv)) {
                print k "=" tmpl_kv[user_cur_sec SUBSEP k]
                seen_keys_local[k] = 1
            } else {
                print ln
            }
        }
        if (user_cur_sec != "" && (user_cur_sec in tmpl_sec_seen)) {
            for (j = 1; j <= tmpl_key_count[user_cur_sec]; j++) {
                tk = tmpl_key_order[user_cur_sec, j]
                if (!(tk in seen_keys_local)) {
                    print tk "=" tmpl_kv[user_cur_sec SUBSEP tk]
                }
            }
        }
        buf_count = 0
        delete buf
    }
    ' "$user_file" > "$out_file"
}

if [[ -f "$OVERRIDE_PATH" ]]; then
    echo "Merging override.cfg (preserving user sections, updating template keys)"
    cp -f "$OVERRIDE_PATH" "$OVERRIDE_PATH.bak"
    if merge_override "$OVERRIDE_PATH" "$OVERRIDE_TMP" "$OVERRIDE_PATH.merged" && [[ -s "$OVERRIDE_PATH.merged" ]]; then
        if ! mv -f "$OVERRIDE_PATH.merged" "$OVERRIDE_PATH"; then
            echo "ERROR: Could not move merged override.cfg into place"
            echo "  Your original is preserved at $OVERRIDE_PATH.bak"
            rm -f "$OVERRIDE_PATH.merged"
            exit 1
        fi
        echo "Updated override.cfg"
    else
        echo "ERROR: merge failed. Your original is preserved at $OVERRIDE_PATH.bak"
        rm -f "$OVERRIDE_PATH.merged"
        rm -f "$OVERRIDE_TMP"
        exit 1
    fi
else
    if ! mv -f "$OVERRIDE_TMP" "$OVERRIDE_PATH" || [[ ! -f "$OVERRIDE_PATH" ]]; then
        echo "ERROR: Could not install override.cfg at $OVERRIDE_PATH"
        echo "  Likely cause: missing write permission, or destination on a read-only filesystem."
        exit 1
    fi
    echo "Installed override.cfg"
fi
rm -f "$OVERRIDE_TMP"

# --- Create mods directory ---
if [[ ! -d "$MODS_PATH" ]]; then
    mkdir -p "$MODS_PATH"
    echo "Created mods directory"
else
    echo "Mods directory already exists"
fi

echo
echo "=== Installation Complete ==="
echo
echo "The mod loader is now installed. When you launch the game,"
echo "a mod manager window will appear before the game loads."
echo
echo "To install mods:"
echo "  - Place .vmz/.zip files in: $MODS_PATH"
echo
echo "Game path:  $GAME_PATH"
echo "Mods path:  $MODS_PATH"
echo
