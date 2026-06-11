#!/usr/bin/env zunit
#{{{                    MARK:Header
#**************************************************************
##### Purpose: zsh-z datafile-logic behavioral pins. Drives the
#####          real functions (_zshz_update_datafile via --add,
#####          _zshz_find_matches via -e) against an isolated
#####          $ZSHZ_DATA so the user's ~/.z is never touched.
#####          Targets two concrete bug classes the source-grep
#####          tests can't catch: (1) stale dead-path entries
#####          surviving an update, and (2) glob-special chars
#####          ([], spaces) in a path breaking the add->match
#####          round-trip (the classic naive-globbing failure).
#}}}***********************************************************

@setup {
    0="${${0:#$ZSH_ARGZERO}:-${(%):-%N}}"
    0="${${(M)0:#/*}:-$PWD/$0}"
    pluginDir="${0:h:A}"
    pluginFile="$pluginDir/zsh-z.plugin.zsh"
    tmp=$(mktemp -d)
}

@teardown {
    [[ -n "$tmp" && -d "$tmp" ]] && rm -rf "$tmp"
}

@test 'update prunes a path whose directory no longer exists' {
    # Bug class: stale-entry accumulation. _zshz_update_datafile
    # (lines ~202-205) rebuilds the db keeping only lines whose
    # ${line%%\|*} is still a live directory. Seed the datafile
    # with one live dir + one dead path, trigger an update by
    # re-adding the live dir, and assert the dead path is gone
    # while the live dir's rank was incremented (5 -> 6). A naive
    # impl that copies lines through untouched would leave the
    # dead path forever and never bump the live rank.
    local datafile="$tmp/.z"
    local live="$tmp/live-dir"
    mkdir -p "$live"
    print -r -- "$live|5|1700000000"                  > "$datafile"
    print -r -- "/no/such/dead/path/xyz|99|1700000000" >> "$datafile"

    zsh -c "
        emulate zsh
        autoload -U add-zsh-hook is-at-least
        ZSHZ_DATA='$datafile'
        source '$pluginFile' 2>/dev/null
        zshz --add '$live' 2>/dev/null
    " 2>/dev/null

    local body
    body=$(<"$datafile")

    # The dead path must be pruned out entirely.
    run grep -cF '/no/such/dead/path/xyz' "$datafile"
    assert "$output" same_as '0'

    # The live dir must remain, with rank bumped from 5 to 6.
    local rank
    rank=$(awk -F'|' -v t="$live" '$1==t {print $2}' "$datafile")
    assert "$rank" same_as '6'
}

@test 'a path containing glob chars survives add then -e echo round-trip' {
    # Bug class: naive globbing / unquoted special chars. A path
    # like .../proj[v2] contains a glob bracket expression. If the
    # match path treats the stored path as a pattern (or fails to
    # quote it), the add->find->echo round-trip drops the entry or
    # errors. Pin that `z --add` then `z -e <substr>` echoes the
    # exact bracketed path back verbatim.
    local datafile="$tmp/.z"
    local target="$tmp/proj[v2]"
    mkdir -p "$target"

    local out
    out=$(zsh -c "
        emulate zsh
        autoload -U add-zsh-hook is-at-least
        ZSHZ_DATA='$datafile'
        source '$pluginFile' 2>/dev/null
        zshz --add '$target' 2>/dev/null
        zshz -e 'proj' 2>&1
    " 2>/dev/null)

    # -e echoes the best match; it must be the literal bracketed path.
    assert "$out" contains 'proj[v2]'
    assert "$out" same_as "$target"
}
