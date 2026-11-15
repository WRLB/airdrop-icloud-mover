#!/bin/bash
# AirDrop iCloud Mover
# When ~/Downloads is a symlink into iCloud Drive, macOS AirDrop cannot save
# there and falls back to /private/tmp. This moves those files into the iCloud
# folder ~/Downloads points to. macOS only; Bash 3.2 and built-in tools only.
set -u
set -o pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077

LABEL=local.airdrop-icloud-mover
WATCH=/private/tmp
APP_DIR="$HOME/Library/Application Support/AirDrop iCloud Mover"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/AirDrop iCloud Mover.log"
QUIET=3        # seconds a file must stay unchanged before it is moved
THROTTLE=2     # launchd waits this long between runs (its default is 10)
DEADLINE=180   # longest one run keeps waiting for files still changing
DEST=''

stamp() { /bin/date '+%Y-%m-%d %H:%M:%S'; }
note() { printf '%s %s\n' "$(stamp)" "$*"; }
warn() { printf '%s %s\n' "$(stamp)" "$*" >&2; }
pause() { /bin/sleep "$QUIET"; }

resolve_destination() {
  local cloud target
  [[ -L "$HOME/Downloads" ]] || { warn 'ERROR ~/Downloads is not a symlink; this tool is not needed.'; return 1; }
  cloud=$(cd -P "$HOME/Library/Mobile Documents/com~apple~CloudDocs" 2>/dev/null && pwd -P) \
    || { warn 'ERROR cannot open iCloud Drive (macOS privacy permission?).'; return 1; }
  target=$(cd -P "$HOME/Downloads" 2>/dev/null && pwd -P) \
    || { warn 'ERROR cannot open the ~/Downloads target (macOS privacy permission?).'; return 1; }
  [[ "$target" == "$cloud/"* ]] || { warn "ERROR ~/Downloads does not point inside iCloud Drive: $target"; return 1; }
  [[ -d "$target" && -w "$target" ]] || { warn 'ERROR the ~/Downloads target is not a writable folder.'; return 1; }
  DEST=$target
}

# AirDrop tags received files with a quarantine record whose 3rd field is sharingd.
is_candidate() {
  local q a b agent
  [[ -f "$1" && ! -L "$1" && -O "$1" ]] || return 1
  q=$(/usr/bin/xattr -p com.apple.quarantine "$1" 2>/dev/null) || return 1
  IFS=';' read -r a b agent _ <<< "$q"
  [[ "$agent" == sharingd ]]
}
signature() { /usr/bin/stat -f '%i:%z:%m:%c' "$1" 2>/dev/null; }
# Only a writer counts: Finder's Quick Look preview keeps files open read-only.
is_busy() { /usr/sbin/lsof -F a "$1" 2>/dev/null | /usr/bin/grep -q '^a[wu]'; }

# Sets FREE to a destination path that does not exist yet: "name (2).ext", ...
free_name() {
  local name="$1" base="$1" ext='' n=2
  if [[ "$name" == ?*.* ]]; then base=${name%.*}; ext=".${name##*.}"; fi
  FREE="$DEST/$name"
  while [[ -e "$FREE" || -L "$FREE" ]]; do
    [[ $n -le 999 ]] || return 1
    FREE="$DEST/$base ($n)$ext"; n=$((n + 1))
  done
}

# /private/tmp and iCloud Drive share one APFS volume, so mv is a rename:
# instant, no second copy, and every attribute (quarantine included) stays.
move_one() {
  local src="$1" name="${1##*/}" err
  free_name "$name" || { warn "ERROR too many name collisions: $(printf '%q' "$name")"; return 1; }
  err=$(/bin/mv -n "$src" "$FREE" 2>&1)
  if [[ -e "$src" || -L "$src" || ! -f "$FREE" ]]; then
    warn "ERROR could not move $(printf '%q' "$name"): ${err:-name taken during move}"
    return 1
  fi
  note "MOVED $(printf '%q' "$name") -> $(printf '%q' "${FREE##*/}")"
}

is_failed() {
  local x
  [[ ${#failed[@]} -gt 0 ]] || return 1
  for x in "${failed[@]}"; do [[ "$x" == "$1" ]] && return 0; done
  return 1
}

# One run: wait until each AirDrop file is unchanged for QUIET seconds and not
# open, then move it. Stops when none are left or after DEADLINE seconds.
sweep() {
  local start f i
  local -a paths sigs failed
  start=$(/bin/date +%s); failed=()
  shopt -s nullglob dotglob
  while :; do
    paths=(); sigs=()
    for f in "$WATCH"/*; do
      is_candidate "$f" || continue
      is_failed "$f" && continue
      paths+=("$f"); sigs+=("$(signature "$f")")
    done
    [[ ${#paths[@]} -gt 0 ]] || return 0
    if [[ $(( $(/bin/date +%s) - start )) -ge $DEADLINE ]]; then
      note "WAIT ${#paths[@]} file(s) still changing or open; the next run retries."
      return 0
    fi
    pause
    for ((i = 0; i < ${#paths[@]}; i++)); do
      f=${paths[i]}
      [[ "$(signature "$f")" == "${sigs[i]}" ]] || continue
      is_busy "$f" && continue
      move_one "$f" || failed+=("$f")
    done
  done
}

rotate_log() {
  local size
  [[ -f "$LOG" && ! -L "$LOG" && ! -d "$LOG.1" ]] || return 0
  size=$(/usr/bin/stat -f '%z' "$LOG") || return 0
  [[ $size -le 1048576 ]] || /bin/mv -f "$LOG" "$LOG.1"
}

xml() { local s="$1"; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }
make_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$(xml "$APP_DIR/mover.sh")</string><string>_agent</string>
  </array>
  <key>WatchPaths</key><array><string>$WATCH</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>ThrottleInterval</key><integer>$THROTTLE</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$(xml "$LOG")</string>
  <key>StandardErrorPath</key><string>$(xml "$LOG")</string>
</dict></plist>
EOF
}

check() {
  local f n=0
  resolve_destination || return 1
  printf '~/Downloads 연결 대상: %s\n' "$DEST"
  shopt -s nullglob dotglob
  for f in "$WATCH"/*; do
    is_candidate "$f" || continue
    printf '  옮길 AirDrop 파일: %q\n' "${f##*/}"; n=$((n + 1))
  done
  printf '지금 %s에 있는 AirDrop 파일: %s개\n' "$WATCH" "$n"
  if [[ -f "$PLIST" ]]; then printf '자동 실행: 설치됨\n'; else printf '자동 실행: 설치 안 됨\n'; fi
}

install() {
  local answer self tmp
  check || return 1
  printf '\n설치하면 위 파일과 앞으로 AirDrop으로 받는 파일이 이 iCloud 폴더로 옮겨집니다.\n'
  printf '설치할까요? [y/N] '
  IFS= read -r answer || return 1
  [[ "$answer" == y || "$answer" == Y ]] || { printf '취소했습니다. 아무것도 바꾸지 않았습니다.\n'; return 1; }
  self="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  /bin/mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" || return 1
  [[ "$self" == "$APP_DIR/mover.sh" ]] || /bin/cp "$self" "$APP_DIR/mover.sh" || return 1
  /bin/launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
  tmp=$(/usr/bin/mktemp "$HOME/Library/LaunchAgents/.$LABEL.XXXXXX") || return 1
  make_plist > "$tmp" && /usr/bin/plutil -lint -s "$tmp" && /bin/mv -f "$tmp" "$PLIST" || { /bin/rm -f "$tmp"; return 1; }
  /bin/launchctl bootstrap "gui/$UID" "$PLIST" || { printf '시작에 실패했습니다. status로 확인하세요.\n' >&2; return 1; }
  printf '설치했습니다. 작은 파일을 AirDrop으로 받아 보고 30초쯤 뒤 status로 확인하세요.\n'
}

uninstall() {
  /bin/launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
  /bin/rm -f "$PLIST" "$APP_DIR/mover.sh"
  /bin/rmdir "$APP_DIR" 2>/dev/null
  printf '자동 실행을 제거했습니다. 이미 옮긴 파일과 로그(%s)는 그대로 둡니다.\n' "$LOG"
}

status() {
  if /bin/launchctl print "gui/$UID/$LABEL" > /dev/null 2>&1; then
    printf '자동 실행: 켜짐\n'
    /bin/launchctl print "gui/$UID/$LABEL" | /usr/bin/grep -E '^[[:space:]]*(state|runs|last exit code) ='
  else
    printf '자동 실행: 꺼짐\n'
  fi
  if [[ -f "$LOG" ]]; then printf '\n최근 기록:\n'; /usr/bin/tail -n 20 "$LOG"; else printf '\n기록 없음\n'; fi
}

main() {
  [[ "$(/usr/bin/uname -s)" == Darwin ]] || { printf 'macOS 전용입니다.\n' >&2; exit 1; }
  [[ $EUID -ne 0 ]] || { printf 'sudo 없이 실행하세요.\n' >&2; exit 1; }
  case "${1:-check}" in
    check) check;;
    install) install;;
    uninstall) uninstall;;
    status) status;;
    run) resolve_destination && sweep;;
    _agent) rotate_log; resolve_destination && sweep;;
    *) printf '사용법: /bin/bash mover.sh [check | install | status | run | uninstall]\n'; exit 2;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
