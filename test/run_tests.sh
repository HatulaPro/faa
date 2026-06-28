#!/usr/bin/env bash
# faa test suite — realistic end-to-end sessions, written to read like usage docs.
# Each step does what a user does: cd into a worktree (or main) and run `faa`.
# Run: bash test/run_tests.sh
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# --------------------------------------------------------------------------
# Journey 1 — the core loop: agent works, main verifies, main fixes an
# *unrelated* file and pushes, agent pulls it, agent continues.
# --------------------------------------------------------------------------
journey_core_loop() {
    echo "Journey 1: the core loop"
    setup; add_wt add-button

    # The agent edited a file in its worktree — save that work.
    cd "$WT"
    printf 'v1\n' > feature.js
    faa
    assert_ok  "agent commits its work"
    assert_out "committed" "commit is reported"
    local c1; c1=$(sha "$WT" HEAD)

    # Over in main, pull the agent's branch in to run/verify it.
    cd "$MAIN"
    faa
    assert_ok        "main pulls the feature"
    assert_branch    "$MAIN" faa-add-button "mirror branch was created"
    assert_curbranch "$MAIN" faa-add-button "main is on the mirror"
    assert_file      "$MAIN" feature.js v1 "main sees the agent's file"

    # You spot and fix something unrelated, then send it back.
    printf 'cfg\n' > config.js
    faa push
    assert_ok  "main pushes its fix"
    assert_out "pushed" "push is reported"

    # The agent picks up your fix and carries on.
    cd "$WT"
    faa
    assert_ok     "agent pulls main's fix"
    assert_file   "$WT" config.js cfg "agent received main's unrelated fix"
    assert_file   "$WT" feature.js v1 "agent's own file is intact"
    assert_same   "$MAIN" refs/heads/add-button refs/heads/faa-add-button \
                  "feature and mirror converged (linear)"
    assert_object "$WT" "$c1" "history is preserved"

    printf 'v2\n' > feature.js
    faa
    assert_ok  "agent commits again on top"
    assert_out "committed" "second commit reported"

    cleanup
}

# --------------------------------------------------------------------------
# Journey 2 — main edits the agent's OWN file and the agent pulls it back.
# ("I add my own changes on main and pull them back where the agent sees.")
# --------------------------------------------------------------------------
journey_main_tweaks_agent_file() {
    echo "Journey 2: main tweaks the agent's file"
    setup; add_wt add-button

    cd "$WT"
    printf 'line1\nline2\nline3\n' > a.js
    faa; assert_ok "agent commits a.js"

    cd "$MAIN"
    faa; assert_ok "main pulls"
    printf 'line1\nline2\nMAIN3\n' > a.js          # main edits the same file
    faa push; assert_ok "main pushes its edit to a.js"

    cd "$WT"
    faa; assert_ok "agent pulls main's edit"
    assert_file "$WT" a.js $'line1\nline2\nMAIN3' "agent sees main's edit to its file"

    cleanup
}

# --------------------------------------------------------------------------
# Journey 3 — push guard + recovery: the agent advances while main is editing;
# main's push aborts, main pulls, then pushes cleanly.
# --------------------------------------------------------------------------
journey_push_guard() {
    echo "Journey 3: push guard recovery"
    setup; add_wt add-button

    cd "$WT"; printf 'a1\n' > a.js; faa          # commit c1
    cd "$MAIN"; faa                              # mirror at c1
    cd "$WT"; printf 'a2\n' > a.js; faa          # agent advances to c2

    cd "$MAIN"
    printf 'm\n' > m.js
    faa push
    assert_fails "push aborts because the worktree advanced"
    assert_out   "pull them first" "abort tells main to pull"

    faa
    assert_ok   "main pulls the new commit"
    assert_file "$MAIN" a.js a2 "main now has the agent's c2"
    assert_file "$MAIN" m.js m  "main keeps its own edit on top"

    faa push
    assert_ok "push succeeds after pulling"

    cd "$WT"
    faa
    assert_ok   "agent pulls main's push"
    assert_file "$WT" m.js m "agent received main's change"

    cleanup
}

# --------------------------------------------------------------------------
# Journey 4 — pull-before-commit: a push is pending and the agent has unsaved
# edits; bare faa pulls first (not commit), then a second faa commits.
# --------------------------------------------------------------------------
journey_pull_before_commit() {
    echo "Journey 4: pull-before-commit"
    setup; add_wt add-button

    cd "$WT"; printf 'a1\n' > a.js; faa
    cd "$MAIN"; faa
    printf 'fix\n' > fix.js; faa push            # push pending

    cd "$WT"
    printf 'wip\n' > wip.js                      # agent has unsaved (untracked) work
    faa
    assert_ok   "agent faa with a pending push pulls instead of committing"
    assert_out  "run 'faa' again" "agent is told to run faa again"
    assert_file "$WT" fix.js fix "agent pulled main's pushed file"
    assert_file "$WT" wip.js wip "agent's unsaved work is preserved"

    faa
    assert_ok  "second faa commits the preserved work"
    assert_out "committed" "commit reported on the second run"

    cleanup
}

# --------------------------------------------------------------------------
# Journey 5 — reset round-trips both directions; commits kept, discards
# recoverable from the reflog.
# --------------------------------------------------------------------------
journey_reset() {
    echo "Journey 5: reset round-trips"
    setup; add_wt add-button

    cd "$WT"; printf 'a1\n' > a.js; faa
    local c1; c1=$(sha "$WT" HEAD)
    cd "$MAIN"; faa

    # (a) reset from the worktree, sync on main
    cd "$WT"
    printf 'a1\na2\n' > a.js
    faa reset
    assert_ok  "worktree reset declares truth"
    assert_out "faa reset sync" "worktree reset points to main"
    assert_ref "$MAIN" refs/faa/reset/add-button "reset marker recorded"

    cd "$MAIN"
    faa reset sync
    assert_ok      "main adopts the reset"
    assert_same    "$MAIN" refs/heads/faa-add-button refs/faa/reset/add-button \
                   "mirror matches the reset marker"
    assert_filehas "$MAIN" a.js a2 "main has the reset content"
    assert_object  "$MAIN" "$c1" "all commits kept (c1 still present)"

    # (b) reset from main, sync in the worktree (a worktree change is discarded)
    printf 'mfix\n' > m.js
    faa reset
    assert_ok  "main reset declares truth"
    assert_out "faa reset sync" "main reset points to the worktree"

    cd "$WT"
    local oldb; oldb=$(sha "$WT" HEAD)
    printf 'corrupt\n' > a.js                    # local change that should be discarded
    faa reset sync
    assert_ok      "worktree adopts main's reset"
    assert_same    "$MAIN" refs/heads/add-button refs/faa/reset/add-button \
                   "feature matches the reset marker"
    assert_filehas "$WT" m.js mfix "worktree has main's reset content"
    assert_file    "$WT" a.js $'a1\na2' "the local change was discarded (hard reset)"
    assert_object  "$WT" "$oldb" "prior tip is still recoverable (reflog)"

    cleanup
}

# --------------------------------------------------------------------------
# Journey 6 — verifying multiple agents: list, default, checkout, pick, help.
# --------------------------------------------------------------------------
journey_multi_agent() {
    echo "Journey 6: multiple agents"
    setup
    add_wt add-button; seed_dated "$WT" f1.js one "2026-01-01T00:00:00"
    add_wt fix-nav;    seed_dated "$WT" f2.js two "2026-02-01T00:00:00"   # more recent

    cd "$MAIN"

    faa -l
    assert_ok  "list runs"
    assert_out "add-button" "list shows add-button"
    assert_out "fix-nav"    "list shows fix-nav"

    faa
    assert_ok     "bare faa on main targets the most recent feature"
    assert_branch "$MAIN" faa-fix-nav "default mirror is the most recent feature"

    faa -c add-button
    assert_ok        "checkout switches main's mirror"
    assert_curbranch "$MAIN" faa-add-button "main is on the chosen mirror"

    faa -p <<< "1"                               # pick #1 from the printed list
    assert_ok "pick selects the first listed feature"
    case "$(git -C "$MAIN" symbolic-ref --quiet --short HEAD)" in
        faa-*) pass "pick left main on a mirror branch" ;;
        *)     fail "pick left main on a mirror branch" "not a mirror" ;;
    esac

    faa -h
    assert_ok  "help runs"
    assert_out "USAGE" "help shows usage"

    cleanup
}

# --------------------------------------------------------------------------
# Journey 7 — conflict surfacing: main's uncommitted edit collides with an
# incoming agent change; the pull stops with markers and a clear message,
# then a clean resolve + push works.
# --------------------------------------------------------------------------
journey_conflict() {
    echo "Journey 7: conflict surfacing"
    setup; add_wt add-button

    cd "$WT"; printf 'L1\nL2\nL3\n' > a.js; faa
    cd "$MAIN"; faa
    cd "$WT"; printf 'L1\nAGENT\nL3\n' > a.js; faa   # agent changes line 2

    cd "$MAIN"
    printf 'L1\nMAIN\nL3\n' > a.js                   # main changes the same line
    faa
    assert_fails   "conflicting pull stops"
    assert_out     "conflict" "user is told about the conflict"
    assert_filehas "$MAIN" a.js "<<<<<<<" "conflict markers are present"

    printf 'L1\nRESOLVED\nL3\n' > a.js               # user resolves
    faa push
    assert_ok "push works after resolving"

    cd "$WT"
    faa
    assert_ok   "agent pulls the resolved result"
    assert_file "$WT" a.js $'L1\nRESOLVED\nL3' "agent sees the resolved content"

    cleanup
}

# --------------------------------------------------------------------------
# Journey 8 — two features in flight at once. One finishes and you check it out
# and push a tweak; the other finishes and you switch to it and push a tweak;
# then you switch back and confirm the two never bled into each other.
# --------------------------------------------------------------------------
journey_two_features() {
    echo "Journey 8: two features at once"
    setup
    add_wt add-button; local A="$WT"
    add_wt fix-nav;    local B="$WT"

    # Both agents finish their work.
    cd "$A"; printf 'A1\n' > btn.js; faa
    cd "$B"; printf 'B1\n' > nav.js; faa

    # Check out the first one, verify it, push a tweak.
    cd "$MAIN"
    faa -c add-button
    assert_ok      "check out add-button"
    assert_file    "$MAIN" btn.js A1 "main sees add-button's file"
    assert_nofile  "$MAIN" nav.js     "fix-nav's file is not here"
    printf 'A1-main\n' > btn.js
    faa push; assert_ok "push a tweak to add-button"

    # Now the other one is ready — switching with an uncommitted tweak is refused.
    printf 'oops\n' > btn.js
    faa -c fix-nav
    assert_fails     "switching with uncommitted work is refused"
    assert_out       "before switching" "told to push/stash first"
    assert_curbranch "$MAIN" faa-add-button "still on add-button after the refusal"
    git -C "$MAIN" checkout -q -- btn.js     # (user discards the stray edit)

    # Switch to fix-nav cleanly and push a tweak there.
    faa -c fix-nav
    assert_ok     "check out fix-nav"
    assert_file   "$MAIN" nav.js B1 "main sees fix-nav's file"
    assert_nofile "$MAIN" btn.js     "add-button's file is not here"
    printf 'B1-main\n' > nav.js
    faa push; assert_ok "push a tweak to fix-nav"

    # Switch back to add-button: its mirror still holds main's add-button tweak,
    # untouched by anything that happened on fix-nav.
    faa -c add-button
    assert_ok     "switch back to add-button"
    assert_file   "$MAIN" btn.js A1-main "add-button kept main's tweak"
    assert_nofile "$MAIN" nav.js          "fix-nav's file did not bleed in"

    # Each agent pulls its own feature; the two stay independent.
    cd "$A"; faa
    assert_ok     "add-button agent pulls"
    assert_file   "$A" btn.js A1-main "add-button agent got its tweak"
    assert_nofile "$A" nav.js          "add-button agent has no fix-nav file"

    cd "$B"; faa
    assert_ok     "fix-nav agent pulls"
    assert_file   "$B" nav.js B1-main "fix-nav agent got its tweak"
    assert_nofile "$B" btn.js          "fix-nav agent has no add-button file"

    cleanup
}

# --------------------------------------------------------------------------
# Journey 9 — bare `faa` on main always follows the newest finished worktree:
# pulls it if you're on it, switches to it otherwise, and refuses to switch
# away from uncommitted work.
# --------------------------------------------------------------------------
journey_master_picks_latest() {
    echo "Journey 9: bare faa on main follows the latest worktree"
    setup
    add_wt add-button; local A="$WT"
    add_wt fix-nav;    local B="$WT"

    # add-button finishes first, fix-nav later (dated so recency is deterministic).
    seed_dated "$A" btn.js A1 "2026-01-01T00:00:00"
    seed_dated "$B" nav.js B1 "2026-02-01T00:00:00"

    # From the home branch, faa checks out the newest finished worktree.
    cd "$MAIN"
    faa
    assert_ok        "faa checks out the newest worktree"
    assert_curbranch "$MAIN" faa-fix-nav "fix-nav (most recent) chosen"

    # add-button gets newer work. Even though main is on fix-nav's mirror, a clean
    # `faa` follows the latest and switches to add-button — no -c, no git.
    seed_dated "$A" btn2.js A2 "2026-03-01T00:00:00"
    faa
    assert_ok        "faa follows the latest across features"
    assert_curbranch "$MAIN" faa-add-button "switched to the now-newest feature"
    assert_file      "$MAIN" btn2.js A2 "its latest work is checked out"

    # If you're already on the latest feature, faa stays and pulls, keeping your
    # in-progress edits on top.
    printf 'tweak\n' > btn2.js
    faa
    assert_ok        "faa on the latest feature stays put and pulls"
    assert_curbranch "$MAIN" faa-add-button "still on add-button"
    assert_file      "$MAIN" btn2.js tweak "main's in-progress edit is kept"

    # With those uncommitted edits, if a *different* feature becomes the latest,
    # faa refuses to switch and tells you what to do.
    seed_dated "$B" nav2.js B2 "2026-04-01T00:00:00"
    faa
    assert_fails     "faa won't switch away from uncommitted work"
    assert_out       "before switching" "told to push or stash first"
    assert_curbranch "$MAIN" faa-add-button "stayed on add-button"

    cleanup
}

# --------------------------------------------------------------------------
journey_core_loop
journey_main_tweaks_agent_file
journey_push_guard
journey_pull_before_commit
journey_reset
journey_multi_agent
journey_conflict
journey_two_features
journey_master_picks_latest

echo
echo "-----------------------------------------"
printf 'Total: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
