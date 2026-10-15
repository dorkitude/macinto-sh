#!/bin/bash
# macinto.sh: command line client for Macinto.app.
# Talks to the app over a Unix socket using macOS's built-in nc(1). No other dependencies.
# https://github.com/dorkitude/macinto.sh (MIT License)

set -u

SOCK="${MACINTO_SOCKET:-$HOME/Library/Application Support/macinto/macinto.sock}"
PROG="macinto.sh"

die()   { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
usage() { printf '%s: usage: %s\n' "$PROG" "$*" >&2; printf "Run '%s help' for all commands.\n" "$PROG" >&2; exit 2; }

# Follow symlinks to the real script location (macOS readlink has no -f before 12.3).
script_path() {
  local p="$0" t
  while [ -L "$p" ]; do
    t=$(readlink "$p")
    case $t in /*) p=$t ;; *) p=$(dirname "$p")/$t ;; esac
  done
  printf '%s\n' "$p"
}

version() {
  local dir; dir=$(cd "$(dirname "$(script_path)")" && pwd)
  if [ -f "$dir/../Info.plist" ]; then          # inside Macinto.app/Contents/Resources
    /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dir/../Info.plist" 2>/dev/null && return
  fi
  if [ -f "$dir/VERSION" ]; then cat "$dir/VERSION"; return; fi   # repo checkout
  echo unknown
}

help() {
  cat <<'EOF'
macinto.sh: drive this Mac through Macinto.app (computer use tunnel)

Usage: macinto.sh <command> [args]

Macinto.app must be running and enabled from its menu bar icon. Every request
is refused while it is disabled. Coordinates are global points with the origin
at the top-left of the main display; screenshots use the same units.

Info
  status                          enabled?, time left, permissions, displays
  apps                            running apps: "* " marks frontmost; pid, bundle id, name
  location                        current mouse position
  keys                            list key names accepted by 'key'

Mouse
  click X Y [--right] [--double]  click at a point
  move X Y                        move the pointer
  drag X1 Y1 X2 Y2                left-button drag
  scroll DX DY                    scroll by lines (positive DY scrolls up)

Keyboard
  type TEXT                       type any Unicode text (newline = Return, tab = Tab)
  key COMBO [COMBO ...]           e.g. cmd+shift+g, return, escape, tab, f5, left, cmd+plus

Apps and UI (Accessibility tree)
  open APP                        activate by name or bundle id, launching if needed
  ui [--app NAME] [--depth N]     dump the front window's UI elements with ids and frames
  press ID [--app NAME]           AXPress an element (ids like 0.3.1 come from 'ui')
  focus ID [--app NAME]           focus an element
  setvalue ID TEXT [--app NAME]   set an element's value (text fields)

Capture (needs Screen Recording permission)
  screenshot [-o FILE.png] [--force] [--display N] [--app NAME] [--native]
                                  PNG scaled to points (pixel coords == click coords);
                                  --native keeps full Retina resolution. Default file:
                                  ./macinto-YYYYmmdd-HHMMSS.png
  record start [-o FILE.mov] [--force] [--display N]
  record stop                     finish and move the movie to its -o path
  record status

Other
  wait SECONDS                    sleep (client side)
  help                            this text
  --version                       print version

Exit codes: 0 ok, 1 error, 2 usage error.
Environment: MACINTO_SOCKET overrides the socket path.
EOF
}

# base64-encode one argument for the wire; "-" stands for an empty argument.
enc() {
  if [ -z "$1" ]; then printf -- '-'; else printf '%s' "$1" | base64 | tr -d '\n'; fi
}

# request CMD [ARGS...]: send one request; prints the payload on success.
request() {
  local line="$1" a resp status
  shift
  for a in "$@"; do line="$line $(enc "$a")"; done
  if [ ! -S "$SOCK" ]; then
    die "Macinto is not running (no socket at $SOCK). Start it with: open -a Macinto"
  fi
  resp=$(printf '%s\n' "$line" | nc -U "$SOCK" 2>/dev/null)
  if [ -z "$resp" ]; then
    die "no response from Macinto at $SOCK. Is it running? Start it with: open -a Macinto"
  fi
  status=${resp%%$'\n'*}
  case $status in
    ok)
      [ "$resp" != "ok" ] && printf '%s\n' "${resp#*$'\n'}"
      return 0 ;;
    "error usage: "*)
      printf '%s: usage: %s\n' "$PROG" "${status#error usage: }" >&2; exit 2 ;;
    "error "*)
      die "${status#error }" ;;
    *)
      die "unexpected response: $status" ;;
  esac
}

field() { # field NAME <<< "payload": value of a "name: value" line
  sed -n "s/^$1: //p" | head -n 1
}

abspath() {
  case $1 in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac
}

stamp() { date +%Y%m%d-%H%M%S; }

cmd_screenshot() {
  local out="" force=0 pass=() payload tmp size
  while [ $# -gt 0 ]; do
    case $1 in
      -o|--output) [ $# -ge 2 ] || usage "screenshot -o FILE.png"; out=$2; shift 2 ;;
      --force|-f)  force=1; shift ;;
      --display|--app) [ $# -ge 2 ] || usage "screenshot $1 VALUE"; pass+=("$1" "$2"); shift 2 ;;
      --native) pass+=("$1"); shift ;;
      *) usage "screenshot [-o FILE.png] [--force] [--display N] [--app NAME] [--native]" ;;
    esac
  done
  [ -n "$out" ] || out="./macinto-$(stamp).png"
  out=$(abspath "$out")
  [ -d "$(dirname "$out")" ] || die "directory does not exist: $(dirname "$out")"
  if [ -e "$out" ] && [ $force -eq 0 ]; then die "$out already exists (use --force to overwrite)"; fi
  payload=$(request screenshot ${pass[@]+"${pass[@]}"}) || exit $?
  tmp=$(printf '%s\n' "$payload" | field path)
  size=$(printf '%s\n' "$payload" | field size)
  [ -n "$tmp" ] && [ -f "$tmp" ] || die "Macinto did not return a file"
  if [ $force -eq 1 ]; then mv -f "$tmp" "$out" || exit 1; else mv -n "$tmp" "$out" || exit 1; fi
  [ -e "$tmp" ] && die "$out appeared while capturing; screenshot left at $tmp"
  printf '%s %s\n' "$out" "$size"
}

cmd_record() {
  local sub=${1:-} out="" force=0 pass=() payload tmp dest f
  [ $# -gt 0 ] && shift
  case $sub in
    start)
      while [ $# -gt 0 ]; do
        case $1 in
          -o|--output) [ $# -ge 2 ] || usage "record start -o FILE.mov"; out=$2; shift 2 ;;
          --force|-f)  force=1; shift ;;
          --display)   [ $# -ge 2 ] || usage "record start --display N"; pass+=("$1" "$2"); shift 2 ;;
          *) usage "record start [-o FILE.mov] [--force] [--display N]" ;;
        esac
      done
      [ -n "$out" ] || out="./macinto-$(stamp).mov"
      out=$(abspath "$out")
      [ -d "$(dirname "$out")" ] || die "directory does not exist: $(dirname "$out")"
      if [ -e "$out" ] && [ $force -eq 0 ]; then die "$out already exists (use --force to overwrite)"; fi
      [ $force -eq 1 ] && pass+=(--force)
      request record start --dest "$out" ${pass[@]+"${pass[@]}"} >/dev/null || exit $?
      printf 'recording to %s (stop with: %s record stop)\n' "$out" "$PROG"
      ;;
    stop)
      payload=$(request record stop) || exit $?
      tmp=$(printf '%s\n' "$payload" | field path)
      dest=$(printf '%s\n' "$payload" | field dest)
      f=$(printf '%s\n' "$payload" | field force)
      [ -n "$tmp" ] && [ -f "$tmp" ] || die "Macinto did not return a file"
      if [ -z "$dest" ]; then printf '%s\n' "$tmp"; return 0; fi
      if [ "$f" = 1 ]; then mv -f "$tmp" "$dest" || exit 1; else mv -n "$tmp" "$dest" || exit 1; fi
      if [ -e "$tmp" ]; then die "$dest already exists; recording left at $tmp"; fi
      printf '%s (%ss)\n' "$dest" "$(printf '%s\n' "$payload" | field duration)"
      ;;
    status) request record status ;;
    *) usage "record start [-o FILE.mov] [--force] [--display N] | record stop | record status" ;;
  esac
}

[ $# -gt 0 ] || { help >&2; exit 2; }
cmd=$1
shift
[[ $cmd =~ ^-{0,2}[a-z]+$ ]] || usage "<command> [args] (unknown command '$cmd')"

case $cmd in
  help|-h|--help) help ;;
  --version|-v|version) printf 'macinto.sh %s\n' "$(version)" ;;
  wait)
    [ $# -eq 1 ] && [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]] || usage "wait SECONDS"
    sleep "$1" ;;
  screenshot) cmd_screenshot "$@" ;;
  record) cmd_record "$@" ;;
  type)
    [ $# -ge 1 ] || usage "type TEXT"
    request type "$*" ;;
  *) request "$cmd" "$@" ;;
esac
