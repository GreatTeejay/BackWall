#!/usr/bin/env bash
#
# BackWall — Teejay Edition :: one-line installer
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/GreatTeejay/BackWall/main/install.sh)
#
set -euo pipefail

GH_OWNER="${BACKWALL_GH_OWNER:-GreatTeejay}"
GH_REPO="${BACKWALL_GH_REPO:-BackWall}"
RAW="https://raw.githubusercontent.com/${GH_OWNER}/${GH_REPO}/main/backwall.sh"
DEST="/usr/local/bin/backwall"

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (e.g. with sudo)." >&2
    exit 1
fi

echo "Downloading BackWall..."
tmp="$(mktemp)"
curl -fsSL --max-time 30 -o "$tmp" "$RAW"

if ! head -n 20 "$tmp" | grep -q "BackWall"; then
    echo "Downloaded file does not look valid. Aborting." >&2
    rm -f "$tmp"
    exit 1
fi

install -m 0755 "$tmp" "$DEST"
rm -f "$tmp"

echo "Installed to $DEST"
echo "Launching BackWall..."
sleep 1

# Launch the script right away with the terminal reattached to stdin.
# (When installed via  bash <(curl ...)  stdin is the pipe, not the
# keyboard, so we redirect it back to the controlling TTY so the menu
# can read your key presses.) You can re-open it any time: backwall
if [[ -e /dev/tty ]]; then
    exec "$DEST" < /dev/tty
else
    echo "Run it with:  backwall"
fi
