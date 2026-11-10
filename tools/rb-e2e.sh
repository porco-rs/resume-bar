#!/bin/bash
export RB_LANGUAGE=de
# Host-only end-to-end check through a real login process.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$ROOT"
work=$(mktemp -d /private/tmp/resume-bar-test-B3-PERSON-e2e.XXXXXX)
app_pid=
cleanup() {
    for mode in person ai; do
        if [[ -f $work/$mode.pid && ! -f $work/$mode.done ]]; then
            kill "$(cat "$work/$mode.pid")" 2>/dev/null || true
        fi
    done
    if [[ -n $app_pid ]]; then
        kill "$app_pid" 2>/dev/null || true
        ( sleep 2; kill -KILL "$app_pid" 2>/dev/null || true ) &
        local killer=$!
        wait "$app_pid" 2>/dev/null || true
        kill "$killer" 2>/dev/null || true
        wait "$killer" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'printf "FAIL unexpected error\n"' ERR
trap 'exit 1' HUP INT TERM
if ! swift build -c release --product rb >"$work/build.log" 2>&1 ||
   ! swift build -c release --product ResumeBar >>"$work/build.log" 2>&1; then
    printf 'FAIL release build\n'; exit 1
fi
bin=$(swift build -c release --show-bin-path 2>"$work/build.log")
mkdir -p "$work/garten" "$work/karte" "$work/nirgends"
cc -o "$work/codex" "$ROOT/tools/rb-e2e-codex.c"
python3 - "$ROOT/ui/trainer/uebung.json" "$work/fixture.json" "$work" <<'PY'
import sys
from pathlib import Path
source, target, root = sys.argv[1:]
Path(target).write_text(Path(source).read_text().replace('/practice/', root + '/'))
PY
export RB_SOCKET="$work/rb.sock" RB_E2E_ROOT="$work" RB_E2E_BIN="$bin/rb"
perl -e 'alarm 90; exec @ARGV' "$bin/ResumeBar" --fixture "$work/fixture.json" --rb-socket "$RB_SOCKET" >"$work/app.log" 2>&1 &
app_pid=$!
ready=0
for ((i=0; i<100; i++)); do
    if [[ -S $RB_SOCKET ]]; then ready=1; break; fi
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if (( ! ready )); then printf 'FAIL fixture startup\n'; exit 1; fi
cat > "$work/inner" <<'INNER'
#!/bin/zsh
mode=$1
result="$RB_E2E_ROOT/$mode.results"
print -r -- $$ > "$RB_E2E_ROOT/$mode.pid"
: > "$result"
check() {
    local label=$1 expected=$2 condition=$3
    shift 3
    local output code
    output=$("$RB_E2E_BIN" "$@" 2>&1)
    code=$?
    if [[ $code != $expected ]]; then
        print -r -- "FAIL $mode $label" >> "$result"
        return
    fi
    case $condition in
        pending) [[ $output == *'erscheint in Resume Bar'* ]] ;;
        no_pending) [[ $output != *'erscheint in Resume Bar'* ]] ;;
        denied) [[ $output == 'Das ist nicht erlaubt.' ]] ;;
        foreign) [[ $output == 'Das geht nur im eigenen Projekt.' ]] ;;
        json) print -r -- "$output" | /usr/bin/python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 ;;
        has:*) [[ $output == *${condition#has:}* ]] ;;
        lacks:*) [[ $output != *${condition#lacks:}* ]] ;;
        *) true ;;
    esac
    if [[ $? == 0 ]]; then print -r -- "ok $mode $label" >> "$result"
    else print -r -- "FAIL $mode $label" >> "$result"; fi
}
cd "$RB_E2E_ROOT/garten" || exit 1
if [[ $mode == person ]]; then
    check ls 0 any ls
    check add 0 no_pending add 'Person Ziel' --bis fr
    check add-by 0 'has:bis ' add 'English Ziel' --by tomorrow
    check ls-after-add 0 'has:Person Ziel' ls
    check add-other-project 0 'has:karte' add 'Karte Ziel' -p karte
    check ls-only-own 0 'lacks:Karte Ziel' ls
    check ls-all 0 'has:Karte Ziel' ls -a
    check deadline 0 'has:24.12.' bis 'Person Ziel' 24.12.
    check due 0 'has:bis Fr ' due offen fri
    check ls-after-deadline 0 'has:24.12.' ls
    check start 0 'has:gestartet' start 'Person Ziel'
    check done 0 'has:erledigt' done Pflanzen
    check ls-after-done 0 'lacks:Pflanzen' ls
    check export 0 json export
else
    check ls 0 any ls
    check add 0 pending add 'AI Ziel' --bis fr
    check ls-after-add 0 'has:AI Ziel' ls
    check done 0 'has:erledigt' done 'AI Ziel'
    check ls-after-done 0 'lacks:AI Ziel' ls
    check ls-all 1 denied ls -a
    check start 1 denied start 'AI Ziel'
    check deadline 1 denied bis 'AI Ziel' morgen
    check export 1 denied export
    check add-other-project 1 foreign add x -p karte
    cd "$RB_E2E_ROOT/nirgends" || exit 1
    check outside-project 1 foreign ls
fi
print done > "$RB_E2E_ROOT/$mode.done"
INNER
# Keep login and the named shell in each ancestry, independently of this script's parents.
( nohup perl -e 'alarm 60; exec @ARGV' script -q /dev/null /usr/bin/login -pf "$(id -un)" /bin/zsh "$work/inner" person </dev/null >/dev/null 2>&1 & )
( nohup perl -e 'alarm 60; exec @ARGV' script -q /dev/null /usr/bin/login -pf "$(id -un)" "$work/codex" "$work/inner" ai </dev/null >/dev/null 2>&1 & )
for ((i=0; i<600; i++)); do
    [[ -f $work/person.done && -f $work/ai.done ]] && break
    sleep 0.1
done
failed=0
for mode in person ai; do
    if [[ -f $work/$mode.done ]]; then
        cat "$work/$mode.results"
        if grep -q '^FAIL ' "$work/$mode.results"; then failed=1; fi
    else
        printf 'FAIL %s completion\n' "$mode"; failed=1
    fi
done
code=0
output=$(RB_SOCKET="$work/missing.sock" "$bin/rb" ls 2>&1) || code=$?
if [[ $code == 3 && $output == 'Resume Bar läuft nicht.' ]]; then printf 'ok app gone\n'
else printf 'FAIL app gone\n'; failed=1; fi
exit "$failed"
