#!/bin/sh
# OpenTina Chromium launcher (/usr/bin/chromium)
set -e

APPNAME=chromium
LIBDIR=/usr/lib/chromium
CHROMIUM_FLAGS="${CHROMIUM_FLAGS:-}"

# Source drop-in flags from /etc/chromium.d/*
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

export CHROME_WRAPPER="/usr/bin/$APPNAME"
export CHROME_DESKTOP="chromium.desktop"
export CHROME_VERSION_EXTRA="${CHROME_VERSION_EXTRA:-OpenTina}"

want_temp_profile=0
cleaned_args=""
while [ $# -gt 0 ]; do
  case "$1" in
    --temp-profile)
      want_temp_profile=1
      shift
      ;;
    -h|--help)
      exec "$LIBDIR/chromium" --help
      ;;
    *)
      break
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
