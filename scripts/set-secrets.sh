#!/usr/bin/env bash
# Stores one app's secrets in this repo's GitHub environments, from your own
# machine (needs the GitHub CLI logged in as the repo owner: gh auth login).
#
#   bash scripts/set-secrets.sh suum      # or pillowo / splik
#
# Asks for each value; press Enter to skip one (keeps what is already stored).
# Values are read without echo and piped straight to `gh secret set`, so they
# never land in shell history or on disk. Build values go to environment
# "<app>", the App Store Connect values also to "<app>-production".
set -euo pipefail

APP="${1:-}"
case "$APP" in suum|pillowo|splik) ;; *) echo "Usage: $0 suum|pillowo|splik"; exit 1 ;; esac
REPO="${REPO:-Bhautik-4B/public-work-ios}"

put() { # put <env> <name> <value>
  printf '%s' "$3" | gh secret set "$2" --repo "$REPO" --env "$1"
  echo "  set $2 in $1"
}
ask() { # ask <name> <prompt> [both]
  local v; read -r -s -p "$2: " v; echo
  [ -n "$v" ] || return 0
  put "$APP" "$1" "$v"
  [ "${3:-}" = both ] && put "$APP-production" "$1" "$v"
  return 0
}
ask_file() { # ask_file <name> <prompt> <base64|text> [both]
  local f v; read -r -p "$2 (file path): " f
  [ -n "$f" ] || return 0
  f="${f/#\~/$HOME}"
  [ -f "$f" ] || { echo "  no such file, skipped"; return 0; }
  if [ "$3" = base64 ]; then v="$(base64 -w 0 "$f" 2>/dev/null || base64 -i "$f")"; else v="$(cat "$f")"; fi
  put "$APP" "$1" "$v"
  [ "${4:-}" = both ] && put "$APP-production" "$1" "$v"
  return 0
}

echo "== $APP: private code access"
ask PRIVATE_REPO       "Private repo (owner/name)"
ask PRIVATE_REPO_TOKEN "Read-only token for that repo"
echo "== $APP: app"
ask BUNDLE_ID "Bundle id (e.g. com.company.app)" both
ask TEAM_ID   "Apple Team ID (10 chars)"
echo "== $APP: App Store Connect API key"
ask ASC_KEY_ID    "Key ID" both
ask ASC_ISSUER_ID "Issuer ID" both
ask_file ASC_KEY_P8 "AuthKey_XXXX.p8" text both
echo "== $APP: signing (skip all three for automatic signing)"
ask_file CERTIFICATES_P12 "Distribution certificate .p12" base64
ask P12_PASSWORD "Password of the .p12"
ask_file BUILD_PROVISION_PROFILE "App Store .mobileprovision" base64
echo "== $APP: optional project overrides (Enter = auto-detect)"
ask APP_DIR           "Sub folder of the app in the repo"
ask IOS_WORKSPACE     "Workspace/project path inside the ios folder (e.g. Runner.xcworkspace)"
ask IOS_SCHEME        "Scheme"
ask IOS_CONFIGURATION "Build configuration (default Release)"
ask WEB_BUILD_CMD     "Web build command (Capacitor only, default: npm run build)"
echo "Done. Check it: Actions -> iOS Verify Setup -> Run workflow -> $APP"
