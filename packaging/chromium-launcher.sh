#!/bin/sh
# OpenTina Chromium launcher (/usr/bin/chromium)

APPNAME=chromium
LIBDIR=/usr/lib/chromium
CHROMIUM_FLAGS="${CHROMIUM_FLAGS:-}"

usage() {
  cat <<EOF
Usage: $APPNAME [options] [URL]

OpenTina wrapper options:
  -h, --help         Show this help message and exit
  --temp-profile     Start with a fresh temporary profile directory removed on exit

All other flags are passed directly to $LIBDIR/chromium.
Drop-in flag files are sourced from /etc/chromium.d/*.
EOF
}

# Source drop-in flags from /etc/chromium.d/* before enabling errexit/noglob so
# third-party drop-in snippets expecting pathname globbing still work normally.
if [ -d /etc/chromium.d ]; then
  for file in /etc/chromium.d/*; do
    [ -f "$file" ] || continue
    case "$file" in
      */README|*.dpkg-*|*~) continue ;;
    esac
    # shellcheck disable=SC1090
    . "$file"
  done
fi

# Enable errexit and noglob so unquoted $CHROMIUM_FLAGS splits words without
# expanding wildcards (e.g. '*.local' or '-- *.html') against the working dir.
set -ef

export CHROME_WRAPPER="/usr/bin/$APPNAME"
export CHROME_DESKTOP="chromium.desktop"
export CHROME_VERSION_EXTRA="${CHROME_VERSION_EXTRA:-OpenTina}"

want_temp_profile=0
has_user_data_dir=0
seen_ddash=0

# Process combined ($CHROMIUM_FLAGS followed by "$@") respecting the first '--'
# across the full effective argument sequence.
filtered_flags=""
for flag_tok in $CHROMIUM_FLAGS; do
  if [ "$seen_ddash" -eq 1 ]; then
    filtered_flags="${filtered_flags:+$filtered_flags }$flag_tok"
    continue
  fi
  case "$flag_tok" in
    --)
      seen_ddash=1
      filtered_flags="${filtered_flags:+$filtered_flags }--"
      ;;
    --temp-profile)
      want_temp_profile=1
      ;;
    --user-data-dir|--user-data-dir=*)
      has_user_data_dir=1
      filtered_flags="${filtered_flags:+$filtered_flags }$flag_tok"
      ;;
    -h|--help|-help)
      usage
      exit 0
      ;;
    *)
      filtered_flags="${filtered_flags:+$filtered_flags }$flag_tok"
      ;;
  esac
done
CHROMIUM_FLAGS="$filtered_flags"

argc=$#
i=0
while [ "$i" -lt "$argc" ]; do
  arg="$1"
  shift
  i=$((i + 1))
  if [ "$seen_ddash" -eq 1 ]; then
    set -- "$@" "$arg"
    continue
  fi
  case "$arg" in
    --)
      seen_ddash=1
      set -- "$@" "--"
      ;;
    --temp-profile)
      want_temp_profile=1
      ;;
    --user-data-dir|--user-data-dir=*)
      has_user_data_dir=1
      set -- "$@" "$arg"
      ;;
    -h|--help|-help)
      usage
      exit 0
      ;;
    *)
      set -- "$@" "$arg"
      ;;
  esac
done

if [ "$want_temp_profile" -eq 1 ] && [ "$has_user_data_dir" -eq 1 ]; then
  echo "Error: --temp-profile cannot be combined with --user-data-dir." >&2
  exit 2
fi

if [ "$want_temp_profile" -eq 1 ]; then
  TEMP_PROFILE="$(mktemp -d)"
  child_pid=""
  cleanup_temp_profile() {
    rm -rf "$TEMP_PROFILE"
  }
  forward_signal() {
    sig="$1"
    trap - EXIT INT TERM HUP
    if [ -n "$child_pid" ]; then
      kill "-$sig" "$child_pid" 2>/dev/null || true
      wait "$child_pid" 2>/dev/null || true
    fi
    cleanup_temp_profile
    exit 143
  }
  trap 'cleanup_temp_profile' EXIT
  trap 'forward_signal INT' INT
  trap 'forward_signal TERM' TERM
  trap 'forward_signal HUP' HUP
  # Place --user-data-dir before $CHROMIUM_FLAGS so any '--' in $CHROMIUM_FLAGS
  # never turns --user-data-dir into a positional URL argument.
  # shellcheck disable=SC2086
  "$LIBDIR/chromium" "--user-data-dir=$TEMP_PROFILE" $CHROMIUM_FLAGS "$@" &
  child_pid=$!
  set +e
  wait "$child_pid"
  rc=$?
  set -e
  trap - EXIT INT TERM HUP
  cleanup_temp_profile
  exit "$rc"
else
  # shellcheck disable=SC2086
  exec "$LIBDIR/chromium" $CHROMIUM_FLAGS "$@"
fi
