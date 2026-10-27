#!/usr/bin/env bash
# Works out what kind of project the private checkout is, so one workflow can
# build Flutter, React Native / Expo, Capacitor and native Xcode apps.
#
# In:  SRC (checkout dir), APP_DIR (sub folder, optional)
# Out: GITHUB_OUTPUT  type, app_root, ios_dir, node_version
set -euo pipefail

ROOT="$SRC/${APP_DIR:-.}"
ROOT="$(cd "$ROOT" && pwd)"
out() { echo "$1=$2" >> "$GITHUB_OUTPUT"; }

TYPE=native
if [ -f "$ROOT/pubspec.yaml" ]; then
  TYPE=flutter
elif [ -f "$ROOT/package.json" ]; then
  if grep -q '"@capacitor/ios"' "$ROOT/package.json"; then TYPE=capacitor
  elif grep -q '"expo"' "$ROOT/package.json" && [ ! -d "$ROOT/ios" ]; then TYPE=expo
  elif grep -q '"react-native"' "$ROOT/package.json"; then TYPE=react-native
  fi
fi

case "$TYPE" in
  capacitor) IOS_DIR="$ROOT/ios/App" ;;
  native)    IOS_DIR="$ROOT" ;;
  *)         IOS_DIR="$ROOT/ios" ;;
esac

NODE_VERSION=""
if [ -f "$ROOT/package.json" ]; then
  NODE_VERSION="$(cat "$ROOT/.nvmrc" "$ROOT/.node-version" 2>/dev/null | head -n1 | tr -d 'v[:space:]')"
  NODE_VERSION="${NODE_VERSION:-22}"
fi

out type "$TYPE"
out app_root "$ROOT"
out ios_dir "$IOS_DIR"
out node_version "$NODE_VERSION"
echo "Project type: $TYPE"
