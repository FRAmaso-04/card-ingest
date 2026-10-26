#!/bin/bash
# ============================================================
# Card Ingest - uninstaller (macOS)
#
#   ./uninstall.sh          removes the program, keeps your data
#                           (blacklist, recent projects, settings)
#   ./uninstall.sh --purge  also deletes ~/.card_ingest
#
# Copied photos and videos are never touched.
# ============================================================
set -uo pipefail

LABEL="io.github.cardingest"
INSTALL_DIR="$HOME/Library/Application Support/CardIngest"
STATE_DIR="$HOME/.card_ingest"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST"
rm -rf "$INSTALL_DIR"
rm -f "$HOME/Desktop/STOP Trasferimento.command"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$STATE_DIR"
  echo "Card Ingest removed, including settings and blacklist."
else
  echo "Card Ingest removed. Settings and blacklist kept in $STATE_DIR"
  echo "(run ./uninstall.sh --purge to delete them too)."
fi
