#!/bin/sh
# Looper L1 helper - POSIX sh edition of tools/looper.ps1 (same contract, output and exit codes).
#
#   looper.sh new     <loop> [--task NAME] [--project DIR]   create a task folder from template/
#   looper.sh status  <loop>                                 show whose move it is (changes nothing)
#   looper.sh publish <loop> handoff|review [--draft FILE]   archive to HISTORY and publish atomically
#             handoff only: [--attach FILE]...             snapshot files into HISTORY, list size + SHA-256
#   looper.sh wait    <loop> --for worker|reviewer [--timeout-minutes N] [--poll-seconds N]
#   looper.sh clean   <loop>                                 delete disposable runtime files (keeps the record)
#
# Never calls a model, never edits source, never judges work. Everything is derived from the
# files (see docs/contract.md). wait exit codes: 0 due, 2 done, 3 timed out (wait again).
# Needs: sh, cp, mv, awk, grep, sort, cmp, sha256sum or shasum. Options also accept the
# PowerShell spellings (-Task, -Project, -Draft, -Attach, -For, -TimeoutMinutes, -PollSeconds).
set -u
MARKER='<!-- looper:template -->'
LOOPER_HOME=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

die() { printf 'LOOPER ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64
    else shasum -a 256 "$1" | cut -c1-64; fi
}

T=$(mktemp -d 2>/dev/null || mktemp -d -t looper) || die 'cannot create a temp folder'
trap 'rm -rf "$T"' EXIT
trap 'exit 1' HUP INT TERM

# note NAME FILE: stable snapshot at $T/NAME; fails when missing, empty, still changing or template.
note() {
    rm -f "$T/$1"; i=0
    while [ $i -lt 5 ]; do
        [ -f "$2" ] || return 1
        # cp -p keeps each copy's write time, taken from the file it read: a snapshot's time always
        # belongs to its content, so the done rule compares snapshots, never a replaced file.
        if cp -p "$2" "$T/$1.a" 2>/dev/null && sleep 0.15 && cp -p "$2" "$T/$1" 2>/dev/null; then
            [ -s "$T/$1" ] || { rm -f "$T/$1"; return 1; }
            if cmp -s "$T/$1.a" "$T/$1" && ! [ "$T/$1.a" -nt "$T/$1" ] && ! [ "$T/$1" -nt "$T/$1.a" ]; then
                if grep -qF "$MARKER" "$T/$1"; then rm -f "$T/$1"; return 1; fi
                return 0
            fi
        fi
        i=$((i + 1)); sleep 0.2
    done
    rm -f "$T/$1"; return 1
}

# Published handoffs, "number sha" per line, in order ($T/known). HISTORY is the complete log.
known_list() {
    : > "$T/known.u"
    for f in "$HIST"/*_HANDOFF.md; do
        [ -f "$f" ] || continue
        num=${f##*/}; num=${num%_HANDOFF.md}
        case $num in '' | *[!0-9]*) continue ;; esac
        printf '%s %s\n' "$(expr "$num" + 0)" "$(sha "$f")" >> "$T/known.u"
    done
    sort -n "$T/known.u" > "$T/known"
}

# Soft format: "Verdict: PASS", "**Verdict:** repair", or a Verdict heading with the word below it.
verdict() {
    awk '
    function word(s) {
        if (s ~ /^pass([^a-z0-9_]|$)/) return "PASS"
        if (s ~ /^repair([^a-z0-9_]|$)/) return "REPAIR"
        if (s ~ /^blocked([^a-z0-9_]|$)/) return "BLOCKED"
        return ""
    }
    { l = tolower($0); sub(/\r$/, "", l) }
    pending { if (l ~ /^[ \t]*$/) next; sub(/^[ \t>*_#`-]*/, "", l); w = word(l); if (w != "") { print w; exit } pending = 0 }
    l ~ /^[ \t>*_#-]*verdict/ {
        rest = l; sub(/^[ \t>*_#-]*verdict/, "", rest)
        r = rest; sub(/^[ \t*_]*[:=-]?[ \t*_`]*/, "", r); w = word(r); if (w != "") { print w; exit }
        if (rest ~ /^[ \t*_:]*$/) pending = 1
    }' "$1"
}

# Hash prefixes on lines whose label (text before the first colon) says "handoff" but not
# previous/prior/earlier/old/last. Printed lower-case, one per line.
handoff_tokens() {
    awk '
    function wc(c) { return c ~ /[A-Za-z0-9_]/ }
    {
        sub(/\r$/, "")
        c = index($0, ":"); if (c == 0) next
        label = tolower(substr($0, 1, c - 1))
        if (label !~ /(^|[^a-z0-9_])handoff([^a-z0-9_]|$)/) next
        if (label ~ /(^|[^a-z0-9_])(previous|prior|earlier|old|last)([^a-z0-9_]|$)/) next
        v = substr($0, c + 1); pos = 0
        while (match(v, /[0-9a-fA-F]+/)) {
            s = RSTART; n = RLENGTH
            before = (s > 1) ? substr(v, s - 1, 1) : ""; after = substr(v, s + n, 1)
            if (n >= 12 && n <= 64 && !wc(before) && !wc(after)) print tolower(substr(v, s, n))
            v = substr(v, s + n)
        }
    }' "$1"
}

# bind FILE: sets BIND to the sha of the one published handoff the answer names, "ambiguous", or "".
bind() {
    : > "$T/matches"
    for tok in $(handoff_tokens "$1"); do
        awk -v t="$tok" 'index($2, t) == 1 { print $2 }' "$T/known" >> "$T/matches"
    done
    count=$(sort -u "$T/matches" | grep -c .)
    BIND=''
    if [ "$count" -eq 1 ]; then BIND=$(sort -u "$T/matches")
    elif [ "$count" -gt 1 ]; then BIND=ambiguous; fi
}

number_of() { awk -v s="$1" '$2 == s { n = $1 } END { if (n != "" && n != 0) printf "%03d", n; else printf "???" }' "$T/known"; }

state() {
    known_list
    H=''; HSHORT=''; HNUM=''; VERDICT=''; RFOR=''; RNOTE=''; FINAL_OK=''
    if note h "$HANDOFF"; then
        H=$(sha "$T/h"); HSHORT=$(printf '%.12s' "$H"); HNUM=$(number_of "$H")
        # A handoff written by hand may be missing from HISTORY; an answer naming it must still bind.
        grep -q " $H\$" "$T/known" || printf '0 %s\n' "$H" >> "$T/known"
    fi
    if note r "$REVIEW"; then
        RNOTE=yes; VERDICT=$(verdict "$T/r"); bind "$T/r"
        [ "$BIND" = ambiguous ] || RFOR=$BIND
    fi
    note f "$FINAL" && FINAL_OK=yes
    if [ -z "$H" ]; then
        NEXT=worker; WHY='no handoff published yet'
    elif [ -z "$RFOR" ] || [ "$RFOR" != "$H" ]; then
        NEXT=reviewer; WHY="handoff $HNUM $HSHORT has no applicable review"
    elif [ "$VERDICT" = PASS ] && [ -n "$FINAL_OK" ] && ! [ "$T/f" -nt "$T/h" ]; then
        # Done only when the report existed before the handoff that passed, i.e. it was reviewed.
        NEXT=done; WHY="handoff $HNUM passed and FINAL_REPORT.md is written"
    else
        NEXT=worker; WHY="answer (${VERDICT:-no verdict}) published for handoff $HNUM $HSHORT"
    fi
}

# Temp file in the same folder, then rename over the target: readers see old or new, never half.
write_atomic() {
    [ -d "$2" ] && return 1   # never move a file into a directory of that name
    tmp="$(dirname -- "$2")/.$(basename -- "$2").$$.tmp"
    cp "$1" "$tmp" 2>/dev/null && mv -f "$tmp" "$2" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# History first, then the current file; if the current file cannot be replaced, undo the new
# history copy so that nothing is published.
publish_pair() {
    existed=0; [ -f "$2" ] && existed=1
    if ! write_atomic "$1" "$2"; then
        [ -n "$ATTACH_DIR" ] && rm -rf "$ATTACH_DIR"
        die "could not write $2; nothing was published. Keep the draft and retry once the file is writable."
    fi
    if ! write_atomic "$1" "$3"; then
        [ "$existed" = 1 ] || rm -f "$2"
        [ -n "$ATTACH_DIR" ] && rm -rf "$ATTACH_DIR"
        die "could not replace $3; nothing was published. Keep the draft and retry once the file is writable."
    fi
}

cmd_status() {
    state
    printf 'LOOPER %s\n' "$ROOT"
    if [ -n "$H" ]; then printf 'handoff: %s %s\n' "$HNUM" "$HSHORT"; else echo 'handoff: none'; fi
    if [ -z "$RNOTE" ]; then echo 'review:  none'
    elif [ -n "$RFOR" ]; then printf 'review:  %s for handoff %s %.12s\n' "${VERDICT:-ANSWER}" "$(number_of "$RFOR")" "$RFOR"
    else printf 'review:  %s (names no published handoff)\n' "${VERDICT:-ANSWER}"; fi
    if [ -n "$FINAL_OK" ]; then echo 'final:   written'; else echo 'final:   not written'; fi
    printf 'NEXT: %s - %s\n' "$NEXT" "$WHY"
}

# Files outside Git (a document, an export): each is copied once into $T/att, and that copy is both
# hashed and later snapshotted into HISTORY. The list is appended to the handoff text, so the id
# changes whenever a file does; it names no number, so re-sending the same text and files is quiet.
attach_files() {
    rm -rf "$T/att"; mkdir "$T/att"; : > "$T/att.lines"
    old_ifs=$IFS; nl='
'
    IFS=$nl
    for a in $ATTACH; do
        if [ -f "$a" ]; then list=$a; else list=$(printf '%s' "$a" | tr ',' '\n'); fi
        for p in $list; do
            [ -f "$p" ] || die "attachment not found (files only): $p"
            name=$(basename -- "$p")
            [ -e "$T/att/$name" ] && die "two attachments are named $name; rename one."
            cp "$p" "$T/att/$name" || die "could not read $p"
            printf -- '- `%s`: %s bytes, sha256 %s\n' "$name" "$(wc -c < "$T/att/$name" | tr -d ' ')" "$(sha "$T/att/$name")" >> "$T/att.lines"
        done
    done
    IFS=$old_ifs
    [ -z "$(tail -c 1 "$T/d")" ] || printf '\n' >> "$T/d"   # end the text with exactly one blank line
    printf '\nAttachments (snapshots in `HISTORY/<number>_attachments/`, <number> being this handoff'"'"'s; review those, not the originals):\n' >> "$T/d"
    cat "$T/att.lines" >> "$T/d"
}

cmd_publish() {
    case $KIND in handoff) NAME=HANDOFF ;; review) NAME=REVIEW ;; *) die 'publish needs a kind: handoff or review' ;; esac
    target="$EXCH/$NAME.md"; default="$EXCH/$NAME.next.md"; draft=${DRAFT:-$default}
    [ -f "$draft" ] || die "no draft at $draft. Write the $KIND there first."
    [ -s "$draft" ] || die "draft $draft is empty."
    cp "$draft" "$T/d"
    grep -qF "$MARKER" "$T/d" && die "draft still contains the template marker $MARKER - write the real $KIND."
    if [ -n "$ATTACH" ]; then
        [ "$KIND" = handoff ] || die '-Attach is for handoffs only.'
        attach_files
    fi
    D=$(sha "$T/d"); DSHORT=$(printf '%.12s' "$D")
    known_list

    if [ "$KIND" = handoff ]; then
        if note h "$target" && [ "$(sha "$T/h")" = "$D" ]; then
            [ "$draft" = "$default" ] && rm -f "$draft"
            echo "LOOPER unchanged: handoff $DSHORT is already published; nothing to do."
            return 0
        fi
        last=$(tail -n 1 "$T/known")
        # Identity is the text's hash, so identical text would inherit that handoff's old answer.
        earlier=$(awk -v s="$D" -v l="${last%% *}" '$2 == s && $1 != l { printf "%03d", $1; exit }' "$T/known")
        [ -n "$earlier" ] && die "this exact handoff text was already published as $earlier. A re-sent request must differ (e.g. say why it is sent again) so an old answer cannot settle it."
        restoring=''
        if [ -n "$last" ] && [ "${last#* }" = "$D" ]; then num=${last%% *}; restoring=yes
        else num=$(awk 'BEGIN { m = 0 } $1 > m { m = $1 } END { print m + 1 }' "$T/known"); fi
        num=$(printf '%03d' "$num")
        if [ -n "$ATTACH" ]; then
            adir="$HIST/${num}_attachments"
            if [ -e "$adir" ]; then
                # Restoring the latest handoff (its EXCHANGE copy was lost): reuse its snapshot, but
                # only if it holds exactly these files, byte for byte. Never touch it otherwise.
                same=''
                if [ -n "$restoring" ] && [ -d "$adir" ] && [ "$(ls -A "$adir" | wc -l)" -eq "$(ls -A "$T/att" | wc -l)" ]; then
                    same=yes
                    for f in "$T/att"/* "$T/att"/.[!.]* "$T/att"/..?*; do   # every name but . and ..
                        [ -e "$f" ] || continue
                        cmp -s "$f" "$adir/${f##*/}" || same=''
                    done
                fi
                [ -n "$same" ] || die "$adir already exists and does not match these attachments; nothing was published."
            else
                ATTACH_DIR=$adir   # created here, so removed again if anything below fails
                { mkdir "$adir" && cp -R "$T/att/." "$adir/"; } || { rm -rf "$adir"; die "could not write the attachment snapshot $adir; nothing was published."; }
            fi
        fi
        publish_pair "$T/d" "$HIST/${num}_HANDOFF.md" "$target"
        [ "$draft" = "$default" ] && rm -f "$draft"
        echo "LOOPER published handoff $num $DSHORT - NEXT: reviewer"
        return 0
    fi

    # Only identity is required. A verdict is for review requests; other answers may omit it.
    v=$(verdict "$T/d"); v=${v:-answer}
    note h "$HANDOFF" || die 'there is no published handoff to review.'
    H=$(sha "$T/h")
    grep -q " $H\$" "$T/known" || printf '0 %s\n' "$H" >> "$T/known"
    hint="Handoff: $(number_of "$H" | sed 's/???/000/') $(printf '%.12s' "$H")"
    bind "$T/d"
    [ -n "$BIND" ] || die "review must name the handoff it reviewed, e.g. '$hint'."
    [ "$BIND" = ambiguous ] && die "review names more than one handoff; keep one 'Handoff:' line, e.g. '$hint'."
    if [ "$BIND" != "$H" ]; then
        die "stale review: it names handoff $(number_of "$BIND" | sed 's/???/000/') $(printf '%.12s' "$BIND") but the current handoff is $hint. Not published; review the current handoff." 4
    fi
    num=$(number_of "$H" | sed 's/???/000/')
    hist="$HIST/${num}_REVIEW.md"; i=2
    while [ -f "$hist" ] && [ "$(sha "$hist")" != "$D" ]; do hist="$HIST/${num}_REVIEW_$i.md"; i=$((i + 1)); done
    publish_pair "$T/d" "$hist" "$target"
    [ "$draft" = "$default" ] && rm -f "$draft"
    state  # recompute NEXT: a PASS on the final handoff makes the task done
    echo "LOOPER published review $v for handoff $num $HSHORT - NEXT: $NEXT"
}

cmd_wait() {
    case $FOR in worker | reviewer) ;; *) die 'wait needs --for worker or --for reviewer' ;; esac
    deadline=$(( $(date +%s) + $(awk -v m="$TIMEOUT" 'BEGIN { printf "%d", m * 60 + 0.5 }') ))
    while :; do
        state
        [ "$NEXT" = done ] && { echo "LOOPER DONE - $WHY"; exit 2; }
        [ "$NEXT" = "$FOR" ] && { echo "LOOPER DUE $FOR - $WHY"; exit 0; }
        left=$(( deadline - $(date +%s) ))
        [ "$left" -le 0 ] && { echo "LOOPER WAIT TIMEOUT - nothing due for $FOR after $TIMEOUT min; wait again"; exit 3; }
        # No portable file events in sh: poll. Each poll only hashes a few small files.
        [ "$left" -lt "$POLL" ] && sleep "$left" || sleep "$POLL"
    done
}

# Durable record: CONTEXT, PLAN, TASK, EXCHANGE/HANDOFF.md + REVIEW.md, HISTORY/, FINAL_REPORT,
# WATCHERS/README.md and WATCHERS/*.log. Everything else below is disposable runtime state.
cmd_clean() {
    for lock in "$ROOT"/WATCHERS/*.lock; do
        [ -f "$lock" ] || continue
        held="a driver is running (${lock##*/} is held); stop it before cleaning."
        if command -v flock >/dev/null 2>&1; then
            flock -n "$lock" true 2>/dev/null || die "$held"
        else
            case $(uname -s) in
                MINGW* | MSYS* | CYGWIN*) ( : >> "$lock" ) 2>/dev/null || die "$held" ;;   # Windows: a held lock cannot be opened
                *) die "cannot check ${lock##*/} without flock(1); nothing was cleaned. Use looper.ps1 clean (the drivers need PowerShell anyway)." ;;
            esac
        fi
    done
    : > "$T/junk"
    for f in "$ROOT"/WATCHERS/* "$ROOT"/WATCHERS/.[!.]* "$ROOT"/EXCHANGE/*.next.md "$ROOT"/EXCHANGE/.*.tmp "$ROOT"/HISTORY/.*.tmp; do
        [ -f "$f" ] || continue
        case ${f##*/} in README.md | *.log) continue ;; esac
        case $f in "$ROOT"/WATCHERS/*/*) continue ;; esac
        rm -f "$f" && printf '%s\n' "${f##*/}" >> "$T/junk"
    done
    for d in "$ROOT"/WATCHERS/*/; do   # e.g. scratch/
        [ -d "$d" ] || continue
        rm -rf -- "${d%/}" && printf '%s\n' "$(basename -- "$d")" >> "$T/junk"
    done
    echo "LOOPER cleaned $(grep -c . "$T/junk") runtime file(s): $(paste -sd ',' "$T/junk" | sed 's/,/, /g')"
    echo 'Kept: CONTEXT, PLAN, TASK, EXCHANGE/HANDOFF.md, EXCHANGE/REVIEW.md, HISTORY/, FINAL_REPORT, WATCHERS/README.md and logs.'
}

cmd_new() {
    if [ -d "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
        if [ -f "$ROOT/CONTEXT.md" ] && [ -d "$ROOT/EXCHANGE" ]; then
            die "$ROOT is already a Looper task. Continue it (read its CONTEXT.md) instead of creating another; for a different task use another folder, or pack/remove this one first."
        fi
        die "$ROOT already exists and is not empty; Looper never overwrites a folder."
    fi
    mkdir -p "$ROOT" || die "cannot create $ROOT"
    ROOT=$(CDPATH='' cd -- "$ROOT" && pwd)
    proj=${PROJECT:-$PWD}; proj=$(CDPATH='' cd -- "$proj" && pwd) || die "no project folder $PROJECT"
    task=${TASK:-${proj##*/}}
    cp -R "$LOOPER_HOME/template/." "$ROOT/" || die 'could not copy the template'
    find "$ROOT" -name .gitkeep -exec rm -f {} +
    L_TASK=$task L_LOOP=$ROOT L_PROJECT=$proj L_HOME=$LOOPER_HOME L_HELPER="$LOOPER_HOME/tools/looper.sh" \
    L_CREATED=$(date '+%Y-%m-%d %H:%M') awk '
        function put(text, key, value,   i, out) {
            out = ""
            while ((i = index(text, "{{" key "}}")) > 0) { out = out substr(text, 1, i - 1) value; text = substr(text, i + length(key) + 4) }
            return out text
        }
        { $0 = put($0, "TASK", ENVIRON["L_TASK"]); $0 = put($0, "LOOP", ENVIRON["L_LOOP"]); $0 = put($0, "PROJECT", ENVIRON["L_PROJECT"])
          $0 = put($0, "LOOPER_HOME", ENVIRON["L_HOME"]); $0 = put($0, "HELPER", ENVIRON["L_HELPER"]); $0 = put($0, "CREATED", ENVIRON["L_CREATED"]); print }
    ' "$ROOT/CONTEXT.md" > "$T/context" && cp "$T/context" "$ROOT/CONTEXT.md"

    # Keep the task folder out of the project's commits without touching tracked files.
    # Ask git for the folder's path inside its repo (avoids comparing path spellings, e.g. C:/ vs /c/).
    prefix=$(cd "$ROOT" && git rev-parse --show-prefix 2>/dev/null) || prefix=''
    gitdir=$(cd "$ROOT" && git rev-parse --absolute-git-dir 2>/dev/null) || gitdir=''
    if [ -n "$prefix" ] && [ -n "$gitdir" ]; then
        entry="/$prefix"
        mkdir -p "$gitdir/info"
        grep -qxF "$entry" "$gitdir/info/exclude" 2>/dev/null || printf '\n%s\n' "$entry" >> "$gitdir/info/exclude"
    fi

    echo "LOOPER created $ROOT"
    echo ''
    echo 'Worker next: fill PLAN.md and TASK.md (proportionately), then start work.'
    echo 'Give this one-line prompt to an independent reviewer, once:'
    echo ''
    echo "  You are the REVIEWER for the Looper task at $ROOT. Read $ROOT/CONTEXT.md and follow the reviewer route."
}

CMD=${1:-help}; [ $# -gt 0 ] && shift
LOOP=.looper; KIND=''; TASK=''; PROJECT=''; DRAFT=''; ATTACH=''; ATTACH_DIR=''; FOR=''; TIMEOUT=720; POLL=5; pos=0
while [ $# -gt 0 ]; do
    opt=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    case $opt in
        -task | --task) TASK=$2; shift 2 ;;
        -project | --project) PROJECT=$2; shift 2 ;;
        -draft | --draft) DRAFT=$2; shift 2 ;;
        -attach | --attach) ATTACH="$ATTACH${ATTACH:+
}$2"; shift 2 ;;
        -for | --for) FOR=$2; shift 2 ;;
        -timeoutminutes | --timeout-minutes) TIMEOUT=$2; shift 2 ;;
        -pollseconds | --poll-seconds) POLL=$2; shift 2 ;;
        -*) die "unknown option $1" ;;
        *) if [ $pos -eq 0 ]; then LOOP=$1; else KIND=$1; fi; pos=$((pos + 1)); shift ;;
    esac
done

case $CMD in
    new) ROOT=$LOOP; cmd_new; exit 0 ;;
    status | publish | wait | clean) ;;
    *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
[ -d "$LOOP/EXCHANGE" ] || die "$LOOP is not a Looper task folder (no EXCHANGE/). Create one with: looper.sh new <folder>"
ROOT=$(CDPATH='' cd -- "$LOOP" && pwd)
HANDOFF="$ROOT/EXCHANGE/HANDOFF.md"; REVIEW="$ROOT/EXCHANGE/REVIEW.md"; FINAL="$ROOT/FINAL_REPORT.md"
HIST="$ROOT/HISTORY"; EXCH="$ROOT/EXCHANGE"
[ -n "$DRAFT" ] && case $DRAFT in /* | [A-Za-z]:/* | [A-Za-z]:'\'*) ;; *) DRAFT="$PWD/$DRAFT" ;; esac   # absolute, including C:\ or C:/
case $CMD in
    status) cmd_status ;;
    publish) cmd_publish ;;
    wait) cmd_wait ;;
    clean) cmd_clean ;;
esac
