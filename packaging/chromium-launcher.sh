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

# Source drop-in flags from /etc/chromium.d/* before enabling errexit so
# third-party drop-in snippets with non-zero test expressions do not abort launch.
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

set -e

export CHROME_WRAPPER="/usr/bin/$APPNAME"
export CHROME_DESKTOP="chromium.desktop"
export CHROME_VERSION_EXTRA="${CHROME_VERSION_EXTRA:-OpenTina}"

want_temp_profile=0
seen_ddash=0
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
    -h|--help|-help)
      usage
      exit 0
      ;;
    *)
      set -- "$@" "$arg"
      ;;
  esac
done

if [ "$want_temp_profile" -eq 1 ]; then
  TEMP_PROFILE="$(mktemp -d)"
  trap 'rm -rf "$TEMP_PROFILE"' EXIT INT TERM
  # shellcheck disable=SC2086
  "$LIBDIR/chromium" $CHROMIUM_FLAGS "--user-data-dir=$TEMP_PROFILE" "$@"
else
  # shellcheck disable=SC2086
  exec "$LIBDIR/chromium" $CHROMIUM_FLAGS "$@"
fi
