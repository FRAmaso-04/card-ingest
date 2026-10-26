#!/bin/bash
# ============================================================
# Card Ingest - installer (macOS)
#
#   ./install.sh                 asks for the destination folder
#   ./install.sh "/Volumes/MySSD/Projects"
#
# Re-running it updates the script and keeps your blacklist,
# recent projects and settings.
# ============================================================
set -euo pipefail

LABEL="io.github.cardingest"
INSTALL_DIR="$HOME/Library/Application Support/CardIngest"
STATE_DIR="$HOME/.card_ingest"
CONFIG_FILE="$STATE_DIR/config.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(uname)" != "Darwin" ]; then
  echo "Card Ingest works on macOS only." >&2
  exit 1
fi
[ -f "$SRC_DIR/ingest.sh" ] || { echo "ingest.sh not found next to install.sh" >&2; exit 1; }

# --- 1. Destination folder ---
DEST="${1:-}"
if [ -z "$DEST" ] && [ -f "$CONFIG_FILE" ]; then
  CURRENT=$( (. "$CONFIG_FILE"; printf '%s' "${SSD_ROOT:-}") 2>/dev/null || true)
  if [ -n "$CURRENT" ]; then
    printf 'Current destination: %s\nKeep it? [Y/n] ' "$CURRENT"
    read -r ANSWER || ANSWER=""
    case "$ANSWER" in n|N|no|NO) ;; *) DEST="$CURRENT" ;; esac
  fi
fi
if [ -z "$DEST" ]; then
  echo "Choose the folder where imported projects will be copied..."
  DEST=$(osascript -e 'POSIX path of (choose folder with prompt "Card Ingest: choose the folder where your projects will be copied")' 2>/dev/null) || {
    echo "Cancelled." >&2; exit 1; }
fi
DEST="${DEST%/}"
if [ ! -d "$DEST" ]; then
  echo "Folder not found: $DEST" >&2
  echo "(If it is on an external drive, connect the drive and run the installer again.)" >&2
  exit 1
fi

# --- 2. Requirements (python3 + qlmanage are needed for the gallery) ---
if ! /usr/bin/python3 -c 'import sys' >/dev/null 2>&1 && ! python3 -c 'import sys' >/dev/null 2>&1; then
  echo "WARNING: python3 is not available, the gallery will fall back to a simple list dialog."
  echo "         Install it with:  xcode-select --install"
fi

# --- 3. Files ---
mkdir -p "$INSTALL_DIR" "$STATE_DIR" "$HOME/Library/LaunchAgents"
cp "$SRC_DIR/ingest.sh" "$INSTALL_DIR/ingest.sh"
chmod 755 "$INSTALL_DIR/ingest.sh"

# Keep the user's other settings, replace only SSD_ROOT
TMP_CFG=$(mktemp)
if [ -f "$CONFIG_FILE" ]; then
  grep -v '^SSD_ROOT=' "$CONFIG_FILE" > "$TMP_CFG" || true
else
  echo "# Card Ingest settings - see config.example.sh for all options" > "$TMP_CFG"
fi
printf 'SSD_ROOT=%q\n' "$DEST" >> "$TMP_CFG"
mv "$TMP_CFG" "$CONFIG_FILE"

# Volumes mounted right now are not new cards: don't propose them
[ -s "$STATE_DIR/known_volumes.txt" ] || ls -1 /Volumes > "$STATE_DIR/known_volumes.txt" 2>/dev/null || true

# --- 4. LaunchAgent ---
xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
SCRIPT_XML=$(xml_escape "$INSTALL_DIR/ingest.sh")
STATE_XML=$(xml_escape "$STATE_DIR")

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_XML</string>
    </array>
    <!-- Runs as soon as a disk is mounted or unmounted -->
    <key>WatchPaths</key>
    <array>
        <string>/Volumes</string>
    </array>
    <!-- Safety net only -->
    <key>StartInterval</key>
    <integer>600</integer>
    <key>ThrottleInterval</key>
    <integer>2</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$STATE_XML/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$STATE_XML/launchd.err.log</string>
</dict>
</plist>
PLISTEOF
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "Card Ingest installed."
echo "  Destination : $DEST"
echo "  Script      : $INSTALL_DIR/ingest.sh"
echo "  Settings    : $CONFIG_FILE"
echo "  Log         : $STATE_DIR/ingest.log"
echo
echo "Insert a memory card to try it. To uninstall: ./uninstall.sh"
