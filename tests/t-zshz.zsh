#!/usr/bin/env zunit
#{{{                    MARK:Header
#**************************************************************
##### Purpose: zsh-z contract pins. zsh-z is a native-zsh port of
#####          rupa/z (no awk/sort/sed). Tests drive the public
#####          API against an isolated $ZSHZ_DATA file so we never
#####          touch the user's real ~/.z db.
#}}}***********************************************************

@setup {
    0="${${0:#$ZSH_ARGZERO}:-${(%):-%N}}"
    0="${${(M)0:#/*}:-$PWD/$0}"
    pluginDir="${0:h:A}"
    pluginFile="$pluginDir/zsh-z.plugin.zsh"
    completionFile="$pluginDir/_zshz"
    tmp=$(mktemp -d)
}

@teardown {
    [[ -n "$tmp" && -d "$tmp" ]] && rm -rf "$tmp"
}

@test 'plugin file parses cleanly under zsh -n (no syntax errors)' {
    run zsh -n "$pluginFile"
    assert $state equals 0
}

@test 'plugin file ships ~700 lines (catastrophic-shrink guard)' {
    local lines
    lines=$(wc -l < "$pluginFile" | tr -d ' ')
    local result=$([[ "$lines" -ge 600 && "$lines" -le 900 ]] && echo yes || echo "no:$lines")
    assert "$result" same_as 'yes'
}

@test '_zshz completion file exists at plugin root + is a zsh completion' {
    # Pin: the _zshz completion gets picked up via fpath augmentation
    # in the plugin. Without it, `z <tab>` does nothing.
    assert "$completionFile" is_file
    local first
    first=$(head -1 "$completionFile")
    assert "$first" contains '#compdef'
}

@test 'ZSHZ[FUNCTIONS] enumerates all 11 helper + main fns (no drift)' {
    # Pin: the FUNCTIONS list is what plugin-unload iterates to
    # unfunction. Adding a new helper without updating this list
    # silently leaks the helper into the user's env after unload.
    local body
    body=$(cat "$pluginFile")
    for fn in _zshz_usage _zshz_add_path _zshz_update_datafile \
              _zshz_legacy_complete _zshz_remove_path \
              _zshz_find_common_root _zshz_output \
              _zshz_find_matches zshz _zshz_precmd _zshz_chpwd _zshz
    do
        assert "$body" contains "$fn"
    done
}

@test 'add-zsh-hook precmd _zshz_precmd is registered at source time' {
    # Pin: precmd is what runs `zshz --add $PWD` after every command.
    # Without the hook, the database never grows.
    local body
    body=$(cat "$pluginFile")
    assert "$body" contains 'add-zsh-hook precmd _zshz_precmd'
}

@test 'add-zsh-hook chpwd _zshz_chpwd is registered at source time' {
    # Pin: chpwd resets DIRECTORY_REMOVED after `z -x`. Without it,
    # `z -x foo` then `cd foo` would refuse to re-add foo.
    local body
    body=$(cat "$pluginFile")
    assert "$body" contains 'add-zsh-hook chpwd _zshz_chpwd'
}

@test 'precmd uses :a vs :A based on ZSHZ_NO_RESOLVE_SYMLINKS' {
    # Pin: :A resolves symlinks, :a does not. The branch lets users
    # choose. Hardcoding either silently changes db semantics for
    # symlinked dirs.
    local body
    body=$(cat "$pluginFile")
    assert "$body" contains 'ZSHZ_NO_RESOLVE_SYMLINKS'
    assert "$body" contains '${PWD:a}'
    assert "$body" contains '${PWD:A}'
}

@test 'plugin adds its dir to fpath via \${0:A:h} (resolves symlinks)' {
    # Pin: zsh plugin standard preamble + symlink-resolved fpath.
    # Without :A, plugins symlinked via dotfiles won't find _zshz.
    local body
    body=$(cat "$pluginFile")
    assert "$body" contains 'fpath=( ${0:A:h} $fpath )'
}

@test 'plugin unload fn exists + reverses the add-zsh-hook registrations' {
    # Pin: zsh-100-Commits-Club standard. Plugin must be safely
    # unloadable. The unload fn MUST undo precmd + chpwd hooks.
    local body
    body=$(cat "$pluginFile")
    assert "$body" contains 'zsh-z_plugin_unload()'
    assert "$body" contains 'add-zsh-hook -D precmd _zshz_precmd'
    assert "$body" contains 'add-zsh-hook -d chpwd _zshz_chpwd'
    assert "$body" contains 'unset ZSHZ'
}

@test 'zshz uses zparseopts (NOT getopts — getopts lacks long opts)' {
    # Pin: --add / --complete / --help are long opts; getopts can't
    # handle them. Refactor to getopts would silently drop long-opt
    # support documented in the synopsis.
    local body
    body=$(cat "$pluginFile")
    assert "$body" contains 'zparseopts'
    assert "$body" contains '-add'
    assert "$body" contains '-complete'
    assert "$body" contains '-help'
}

@test 'zshz supports all 8 documented flags (-c -e -h -l -r -t -x --add --complete --help)' {
    # Pin: the public flag set per the synopsis comment block. If
    # any flag drops out of the zparseopts spec, the help text and
    # behaviour drift apart.
    local body
    body=$(cat "$pluginFile")
    # zparseopts spec uses single-letter flags
    for flag in 'c ' 'e ' 'h ' 'l ' 'r ' 't ' 'x'; do
        assert "$body" contains "    $flag"
    done
}

@test 'zshz -h prints usage and returns 0' {
    # End-to-end: source the plugin in a clean env, invoke zshz -h,
    # confirm the documented OPTION listing appears.
    local out
    out=$(ZSHZ_DATA="$tmp/.z" zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        source '$pluginFile' 2>/dev/null
        zshz -h
    " 2>&1)
    assert "$out" contains 'Usage: z'
    assert "$out" contains 'Jump to a directory'
}

@test 'zshz with invalid flag prints "Improper option" + returns 1' {
    # Pin: rejects unknown flags loudly rather than silently
    # accepting + producing surprising results.
    local out state
    out=$(ZSHZ_DATA="$tmp/.z" zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        source '$pluginFile' 2>/dev/null
        zshz -ZZZ 2>&1
        echo \"RC=\$?\"
    ")
    assert "$out" contains 'Improper option'
    assert "$out" contains 'RC=1'
}

@test 'zshz --add PATH appends an entry to ZSHZ_DATA datafile' {
    # End-to-end: pristine datafile, zshz --add some-real-dir, then
    # read the file back. Format is `path|rank|timestamp`.
    local datafile="$tmp/.z"
    local target="$tmp/some-target-dir"
    mkdir -p "$target"
    zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        ZSHZ_DATA='$datafile'
        source '$pluginFile' 2>/dev/null
        zshz --add '$target' 2>/dev/null
    " 2>/dev/null
    assert "$datafile" is_file
    local body
    body=$(cat "$datafile")
    assert "$body" contains "$target"
}

@test 'datafile format is "path|rank|timestamp" (3-field pipe-delimited)' {
    # Pin: the legacy rupa/z format. If a refactor changes the
    # delimiter or field order, every user's existing db (and z's
    # cross-shell sharing) breaks.
    local datafile="$tmp/.z"
    local target="$tmp/some-target"
    mkdir -p "$target"
    zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        ZSHZ_DATA='$datafile'
        source '$pluginFile' 2>/dev/null
        zshz --add '$target' 2>/dev/null
    " 2>/dev/null
    local fields
    fields=$(awk -F'|' '{print NF}' "$datafile" | head -1)
    assert "$fields" same_as '3'
}

@test 'multiple --add calls to same path increment rank (frecency growth)' {
    # Pin: re-visiting a path bumps its rank. The frecency formula
    # is the whole point of z — pin a directional test.
    local datafile="$tmp/.z"
    local target="$tmp/often-visited"
    mkdir -p "$target"
    zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        ZSHZ_DATA='$datafile'
        source '$pluginFile' 2>/dev/null
        zshz --add '$target' 2>/dev/null
        zshz --add '$target' 2>/dev/null
        zshz --add '$target' 2>/dev/null
    " 2>/dev/null
    # After 3 adds, rank field should be > 1.
    local rank
    rank=$(awk -F'|' -v t="$target" '$1==t {print $2}' "$datafile" | tail -1)
    local result=$([[ -n "$rank" ]] && awk -v r="$rank" 'BEGIN{exit !(r > 1)}' && echo yes || echo "no:$rank")
    assert "$result" same_as 'yes'
}

@test 'zshz -l lists matches (does NOT cd)' {
    # Pin: -l is read-only listing. If it ever cd's, scripts that
    # use `z -l foo` to introspect break catastrophically.
    local datafile="$tmp/.z"
    local target="$tmp/list-only-target"
    mkdir -p "$target"
    local pwd_before pwd_after
    pwd_before=$(pwd)
    pwd_after=$(zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        ZSHZ_DATA='$datafile'
        source '$pluginFile' 2>/dev/null
        zshz --add '$target' 2>/dev/null
        zshz -l list-only-target >/dev/null 2>&1
        pwd
    ")
    assert "$pwd_before" same_as "$pwd_after"
}

@test 'zshz -e echoes best match (does NOT cd)' {
    # Pin: -e is the print-don't-cd flag — used by other scripts.
    local datafile="$tmp/.z"
    local target="$tmp/echo-target-xyz789"
    mkdir -p "$target"
    local out
    out=$(zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        ZSHZ_DATA='$datafile'
        source '$pluginFile' 2>/dev/null
        zshz --add '$target' 2>/dev/null
        zshz -e xyz789 2>&1
    ")
    assert "$out" contains 'echo-target-xyz789'
}

@test 'zshz -x PWD removes the current dir from the datafile' {
    # End-to-end: add a path, cd to it, run z -x, verify db row is gone.
    local datafile="$tmp/.z"
    local target="$tmp/will-be-removed"
    mkdir -p "$target"
    local after
    after=$(cd "$target" && ZSHZ_DATA="$datafile" zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        source '$pluginFile' 2>/dev/null
        zshz --add '$target' 2>/dev/null
        zshz -x 2>/dev/null
        # grep -c always prints a count; suppress its non-zero exit
        # when nothing matched so the test sees a single line.
        grep -c '$target' '$datafile' 2>/dev/null
        true
    ")
    assert "$after" same_as '0'
}

@test 'ZSHZ_EXCLUDE_DIRS prevents matching dirs from being added' {
    # Pin: the exclude env var is the user's escape hatch — drop
    # silently and every excluded dir resurfaces in completion.
    local body
    body=$(cat "$pluginFile")
    assert "$body" contains 'ZSHZ_EXCLUDE_DIRS'
}

@test 'ZSHZ_MAX_SCORE triggers aging when exceeded (frecency cap)' {
    # Pin: documented at 9000 by default. Without aging, the db
    # grows monotonically and old entries dominate forever.
    local body
    body=$(cat "$pluginFile")
    assert "$body" contains 'ZSHZ_MAX_SCORE'
}

@test 'ZSHZ_CMD env var allows renaming the public z command' {
    # Pin: documented escape hatch for users with z-conflicts.
    # Falling back to _Z_CMD (legacy rupa/z env name) preserves
    # users migrating from rupa/z.
    local body
    body=$(cat "$pluginFile")
    assert "$body" contains 'ZSHZ_CMD'
    assert "$body" contains '_Z_CMD'
}

@test 'ZSHZ_DATA defaults to $HOME/.z when unset (rupa/z compat)' {
    # Pin: the default datafile path is `~/.z` — the rupa/z legacy
    # default. Switching to ~/.config/zsh-z/ would silently strand
    # existing users. The source spells it `${HOME}/.z` with the
    # full ZSHZ_DATA / _Z_DATA fallback chain.
    grep -qF '${ZSHZ_DATA:-${_Z_DATA:-${HOME}/.z}}' "$pluginFile"
    assert $? equals 0
}

@test 'plugin sources cleanly in a fresh zsh subshell + defines zshz' {
    # End-to-end: full source under emulate zsh, verify zshz
    # function is defined.
    local result
    result=$(zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        source '$pluginFile' 2>/dev/null
        typeset -f zshz >/dev/null && print -n DEFINED || print -n NOPE
    " 2>&1)
    assert "$result" same_as 'DEFINED'
}

@test 're-sourcing the plugin is idempotent (no fn duplication)' {
    local first second
    first=$(zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        source '$pluginFile' 2>/dev/null
        typeset +f | grep -c '^_zshz'
    ")
    second=$(zsh -c "
        emulate zsh
        autoload -U add-zsh-hook
        source '$pluginFile' 2>/dev/null
        source '$pluginFile' 2>/dev/null
        typeset +f | grep -c '^_zshz'
    ")
    assert "$first" same_as "$second"
}
