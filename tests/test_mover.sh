#!/bin/bash
# Runs mover.sh functions against real macOS xattr/stat/mv/lsof in a private
# temp folder. Touches nothing in the real /private/tmp, ~/Downloads or iCloud.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/aim-test.XXXXXX"); T=$(cd -P "$T" && pwd -P)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { "$@" || fail "$*"; }
no() { if "$@"; then fail "unexpected success: $*"; fi; }
QTN='0081;6ae30c2c;sharingd;3634C856'
setup() {
  rm -rf "$T/case"; mkdir -p "$T/case/tmp" "$T/case/home/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
  HOME="$T/case/home"
  ln -s "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads" "$HOME/Downloads"
  . "$HERE/mover.sh"
  WATCH="$T/case/tmp"; QUIET=0; DEADLINE=10; LOG="$T/case/log"
  pause() { /bin/sleep 0.1; }
  resolve_destination || fail 'resolve_destination'
}
airdrop() { printf '%s' "${2:-data}" > "$WATCH/$1"; xattr -w com.apple.quarantine "${3:-$QTN}" "$WATCH/$1"; }
count() { find "$1" -mindepth 1 -maxdepth 1 -print0 | tr -cd '\0' | wc -c | tr -d ' '; }

# Catches moving non-AirDrop files, links, folders or nested files.
setup
airdrop good.HEIC
airdrop safari.zip data '0081;6ae30c2c;Safari;UUID'
printf x > "$WATCH/plain"; ln -s "$WATCH/plain" "$WATCH/link"
mkdir "$WATCH/sub"; printf x > "$WATCH/sub/inner"; xattr -w com.apple.quarantine "$QTN" "$WATCH/sub/inner"
sweep > "$T/out" 2>&1
ok test -f "$DEST/good.HEIC"; ok test "$(count "$DEST")" = 1
ok test -f "$WATCH/safari.zip"; ok test -f "$WATCH/plain"; ok test -L "$WATCH/link"; ok test -f "$WATCH/sub/inner"
ok grep -q 'MOVED good.HEIC -> good.HEIC' "$T/out"
echo 'PASS only top-level AirDrop files move'
# Catches lost content or attributes (move must be a plain rename).
ok test "$(cat "$DEST/good.HEIC")" = data
ok test "$(xattr -p com.apple.quarantine "$DEST/good.HEIC")" = "$QTN"
echo 'PASS content and quarantine kept'
# Catches overwriting existing files and bad collision names.
setup
printf old > "$DEST/photo.HEIC"; printf old2 > "$DEST/photo (2).HEIC"; printf old > "$DEST/README"; printf old > "$DEST/.x"
airdrop photo.HEIC new; airdrop README new; airdrop .x new
sweep > /dev/null 2>&1
ok test "$(cat "$DEST/photo.HEIC")" = old; ok test "$(cat "$DEST/photo (2).HEIC")" = old2
ok test "$(cat "$DEST/photo (3).HEIC")" = new
ok test "$(cat "$DEST/README (2)")" = new
ok test "$(cat "$DEST/.x (2)")" = new
ok test "$(count "$WATCH")" = 0
echo 'PASS collisions never overwrite'
# Catches moving a file that is still being written.
setup; airdrop grow.mov; n=0
pause() { n=$((n + 1)); [[ $n -eq 1 ]] && printf more >> "$WATCH/grow.mov"; /bin/sleep 0.1; }
sweep > /dev/null 2>&1
ok test "$(cat "$DEST/grow.mov")" = datamore; ok test "$n" -ge 2
echo 'PASS waits until the file stops changing'
# Catches moving files another process is still writing.
setup; airdrop open.mov; DEADLINE=1
exec 3>> "$WATCH/open.mov"
ok is_busy "$WATCH/open.mov"
sweep > "$T/out" 2>&1
ok test -f "$WATCH/open.mov"; ok grep -q 'WAIT 1 file' "$T/out"
exec 3>&-
no is_busy "$WATCH/open.mov"
sweep > /dev/null 2>&1; ok test -f "$DEST/open.mov"
echo 'PASS files open for writing wait (real lsof)'
# Catches a Quick Look preview (read-only handle) blocking the move forever.
setup; airdrop preview.mp4
exec 3< "$WATCH/preview.mp4"
no is_busy "$WATCH/preview.mp4"
sweep > /dev/null 2>&1
exec 3<&-
ok test -f "$DEST/preview.mp4"; no test -e "$WATCH/preview.mp4"
echo 'PASS read-only open files still move'
# Catches shell interpretation of odd file names.
setup
for name in 'a b.HEIC' '-n' $'line\nbreak' 'x;echo BAD' '$(touch PWNED)'; do airdrop "$name"; done
sweep > /dev/null 2>&1
ok test "$(count "$WATCH")" = 0; ok test "$(count "$DEST")" = 5; no test -e PWNED
echo 'PASS odd file names'
# Catches endless retry/log spam when the destination refuses writes.
setup; airdrop stuck.HEIC; chmod 500 "$DEST"
sweep > /dev/null 2> "$T/err"; chmod 700 "$DEST"
ok test -f "$WATCH/stuck.HEIC"; ok test "$(grep -c 'ERROR could not move' "$T/err")" = 1
echo 'PASS failed move keeps source and logs once per run'
# Catches running against a real or non-iCloud Downloads folder.
setup
rm "$HOME/Downloads"; mkdir "$HOME/Downloads"; no resolve_destination 2> /dev/null
rmdir "$HOME/Downloads"; mkdir "$T/case/elsewhere"; ln -s "$T/case/elsewhere" "$HOME/Downloads"; no resolve_destination 2> /dev/null
echo 'PASS destination must be iCloud via symlink'
# Catches unbounded logs.
setup
dd if=/dev/zero of="$LOG" bs=1024 count=1100 2> /dev/null; rotate_log
ok test -f "$LOG.1"; no test -e "$LOG"
printf small > "$LOG"; rotate_log; ok test -f "$LOG"
echo 'PASS log rotation'
# Catches a broken LaunchAgent definition or XML escaping.
setup
ok test "$(xml 'a&b<c>d')" = 'a&amp;b&lt;c&gt;d'
make_plist > "$T/agent.plist"; ok plutil -lint -s "$T/agent.plist"
ok test "$(plutil -extract WatchPaths.0 raw "$T/agent.plist")" = "$WATCH"
ok test "$(plutil -extract StartInterval raw "$T/agent.plist")" = 300
ok test "$(plutil -extract ThrottleInterval raw "$T/agent.plist")" = 2
echo 'PASS LaunchAgent plist'
# Catches the default command writing anything when Downloads is not set up.
mkdir "$T/empty"
no env HOME="$T/empty" /bin/bash "$HERE/mover.sh" > /dev/null 2>&1
ok test "$(count "$T/empty")" = 0
/bin/bash -n "$HERE/mover.sh" || fail syntax
echo 'PASS default check is read-only; syntax'
echo "ALL TESTS PASSED ($(sw_vers -productVersion), $(/bin/bash --version | head -1 | cut -d' ' -f1-4))"
