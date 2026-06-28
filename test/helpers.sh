#!/usr/bin/env bash
# Test helpers for faa, sourced by run_tests.sh. No external deps (no bats).
#
# These tests double as usage docs: each one reads like a real session — you
# `cd` into a worktree (or into main) and run `faa`, `faa push`, `faa reset sync`
# exactly as you would by hand. Two small bits of plumbing make that possible:
#   1. faa is put on PATH, so it's invoked as a bare `faa` command.
#   2. `faa` is wrapped in a thin function that records the output and exit code
#      of the last run (LAST_OUT / LAST_RC) so the asserts can check them.
# The command you see in a test is exactly what a user would type.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="$SCRIPT_DIR:$PATH"

PASS=0
FAIL=0
LAST_OUT=""
LAST_RC=0

# `faa ...` — run the real script, stash its output + exit code for the asserts.
# stdin passes straight through, so `faa -p <<< "1"` works like typing the digit.
faa() {
    LAST_OUT=$(command faa "$@" 2>&1)
    LAST_RC=$?
    return 0
}

# --- assertions ------------------------------------------------------------
pass() { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    printf '    FAIL %s\n' "$1"
    [ $# -ge 2 ] && printf '         > %s\n' "$2"
    printf '         > last output: %s\n' "$LAST_OUT"
}

assert_ok()    { [ "$LAST_RC" -eq 0 ] && pass "$1" || fail "$1" "rc=$LAST_RC"; }
assert_fails() { [ "$LAST_RC" -ne 0 ] && pass "$1" || fail "$1" "expected non-zero exit"; }

assert_out() { # <substring> <name>
    case "$LAST_OUT" in
        *"$1"*) pass "$2" ;;
        *)      fail "$2" "output missing: $1" ;;
    esac
}

assert_file() { # <dir> <file> <expected-content> <name>   (trailing newline ignored)
    local got
    got=$(cat "$1/$2" 2>/dev/null)
    [ "$got" = "$3" ] && pass "$4" || fail "$4" "$2: got [$got] want [$3]"
}

assert_filehas() { # <dir> <file> <substring> <name>
    if grep -qF "$3" "$1/$2" 2>/dev/null; then pass "$4"; else fail "$4" "$2 lacks: $3"; fi
}

assert_nofile() { # <dir> <file> <name>
    [ ! -e "$1/$2" ] && pass "$3" || fail "$3" "$2 should not exist"
}

assert_branch() { # <dir> <branch> <name>
    git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null \
        && pass "$3" || fail "$3" "branch $2 missing"
}

assert_ref() { # <dir> <ref> <name>
    git -C "$1" rev-parse --verify --quiet "$2" >/dev/null \
        && pass "$3" || fail "$3" "ref $2 missing"
}

assert_same() { # <dir> <refA> <refB> <name>
    local a b
    a=$(git -C "$1" rev-parse "$2" 2>/dev/null)
    b=$(git -C "$1" rev-parse "$3" 2>/dev/null)
    { [ -n "$a" ] && [ "$a" = "$b" ]; } && pass "$4" || fail "$4" "$2=$a vs $3=$b"
}

assert_curbranch() { # <dir> <expected> <name>
    local c
    c=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null)
    [ "$c" = "$2" ] && pass "$3" || fail "$3" "current=[$c] want=[$2]"
}

assert_object() { # <dir> <sha> <name>   object still present (recoverable)
    git -C "$1" cat-file -e "$2" 2>/dev/null && pass "$3" || fail "$3" "object $2 gone"
}

# --- scenario scaffolding --------------------------------------------------
setup() {
    TMP=$(mktemp -d)
    MAIN="$TMP/main"
    git init -q "$MAIN"
    git -C "$MAIN" config user.email t@example.com
    git -C "$MAIN" config user.name tester
    git -C "$MAIN" config core.autocrlf false
    git -C "$MAIN" config commit.gpgsign false
    printf 'base\n' > "$MAIN/base.txt"
    git -C "$MAIN" add -A
    git -C "$MAIN" commit -q -m init
}

add_wt() { # <feature>   -> sets WT to the worktree path
    git -C "$MAIN" branch "$1"
    git -C "$MAIN" worktree add -q "$TMP/$1" "$1"
    WT="$TMP/$1"
}

# Save work in a worktree with a controlled committer date (so recency ordering
# in the -l/-p tests is deterministic).
seed_dated() { # <dir> <file> <content> <date>
    printf '%s\n' "$3" > "$1/$2"
    ( cd "$1" && GIT_COMMITTER_DATE="$4" GIT_AUTHOR_DATE="$4" command faa >/dev/null 2>&1 )
}

cleanup() { cd "$SCRIPT_DIR" 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true; }

sha() { git -C "$1" rev-parse "$2" 2>/dev/null; }
