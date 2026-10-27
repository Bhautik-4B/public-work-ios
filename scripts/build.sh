#!/usr/bin/env bash
# Builds the signed .ipa from the private checkout.
#
# In:  TYPE APP_ROOT IOS_DIR (from detect.sh), BUNDLE_ID, BUILD_NUMBER,
#      APP_VERSION (optional), IOS_WORKSPACE / IOS_SCHEME / IOS_CONFIGURATION
#      (optional; workspace relative to IOS_DIR), WEB_BUILD_CMD (optional, Capacitor), NO_ENCRYPTION,
#      signing values from signing.sh (SIGNING_MODE TEAM_ID PROFILE_UUID PROFILE_NAME ASC_*)
# Out: GITHUB_ENV IPA_PATH
#
# Full tool output goes to files in $RUNNER_TEMP (never uploaded); only error
# lines are printed, because the logs of this public repo are public.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${IOS_CONFIGURATION:-Release}"
LOGS="$RUNNER_TEMP/logs"
mkdir -p "$LOGS"

# run <name> <cmd...>: quiet unless it fails.
run() {
  local name="$1"; shift
  echo "> $name"
  if ! "$@" > "$LOGS/$name.log" 2>&1; then
    echo "$name failed. Errors:"
    grep -E '(error|Error|ERROR|failed|Failed)[: ]' "$LOGS/$name.log" | grep -v '^\s*$' | tail -n 40 || tail -n 20 "$LOGS/$name.log"
    exit 1
  fi
}

node_install() {
  cd "$APP_ROOT"
  if [ -f pnpm-lock.yaml ]; then corepack enable && run deps-pnpm pnpm install --frozen-lockfile
  elif [ -f yarn.lock ]; then corepack enable && run deps-yarn yarn install
  elif [ -f package-lock.json ]; then run deps-npm npm ci
  else run deps-npm npm install
  fi
}

pods() {
  [ -f "$IOS_DIR/Podfile" ] || return 0
  cd "$IOS_DIR"
  if [ -f "$APP_ROOT/Gemfile" ] && grep -q cocoapods "$APP_ROOT/Gemfile"; then
    (cd "$APP_ROOT" && run bundle-install bundle install)
    run pod-install bash -c 'bundle exec pod install || bundle exec pod install --repo-update'
  else
    run pod-install bash -c 'pod install || pod install --repo-update'
  fi
}

# 1. Dependencies / native project
case "$TYPE" in
  flutter)
    cd "$APP_ROOT"
    # Same as the old per-repo workflow: CocoaPods only, no Swift Package Manager.
    flutter config --no-enable-swift-package-manager > /dev/null 2>&1 || true
    flutter config --no-enable-uiscene-migration > /dev/null 2>&1 || true
    mkdir -p build/ios/SourcePackages
    run flutter-pub-get flutter pub get
    run flutter-config flutter build ios --config-only --release --build-number="$BUILD_NUMBER" ${APP_VERSION:+--build-name="$APP_VERSION"}
    [ -d "$IOS_DIR/Pods" ] || pods
    ;;
  react-native)
    node_install; pods ;;
  expo)
    node_install
    cd "$APP_ROOT"; run expo-prebuild npx expo prebuild --platform ios --no-install
    pods ;;
  capacitor)
    node_install
    cd "$APP_ROOT"
    run web-build bash -c "${WEB_BUILD_CMD:-npm run build --if-present}"
    run cap-sync npx cap sync ios
    [ -d "$IOS_DIR/Pods" ] || pods
    ;;
  native)
    pods ;;
esac

# 2. Workspace / project and scheme
cd "$IOS_DIR"
if [ -n "${IOS_WORKSPACE:-}" ]; then
  CONTAINER="$IOS_WORKSPACE"
else
  CONTAINER="$(find . -maxdepth 2 -name '*.xcworkspace' -not -path '*/Pods/*' -not -path '*.xcodeproj/*' | head -n1)"
  [ -n "$CONTAINER" ] || CONTAINER="$(find . -maxdepth 2 -name '*.xcodeproj' -not -path '*/Pods/*' | head -n1)"
fi
[ -n "$CONTAINER" ] || { echo "No .xcworkspace/.xcodeproj found - set the IOS_WORKSPACE secret"; exit 1; }
case "$CONTAINER" in *.xcworkspace) FLAG=-workspace ;; *) FLAG=-project ;; esac

if [ -n "${IOS_SCHEME:-}" ]; then SCHEME="$IOS_SCHEME"
else
  case "$TYPE" in
    flutter) SCHEME=Runner ;;
    capacitor) SCHEME=App ;;
    *) SCHEME="$(basename "$CONTAINER")"; SCHEME="${SCHEME%.*}" ;;
  esac
fi
echo "Scheme found"

# 3. The app target's settings (target name, project, Info.plist)
xcodebuild -showBuildSettings "$FLAG" "$CONTAINER" -scheme "$SCHEME" -configuration "$CONFIG" -json \
  > "$LOGS/settings.json" 2> "$LOGS/settings.err" \
  || { echo "Scheme not usable - set the IOS_SCHEME secret"; tail -n 5 "$LOGS/settings.err" | grep -i error || true; exit 1; }
eval "$(python3 - "$LOGS/settings.json" <<'PY'
import json, os, shlex, sys
items = json.load(open(sys.argv[1]))
want = os.environ.get("BUNDLE_ID", "")
apps = [i["buildSettings"] for i in items if i["buildSettings"].get("WRAPPER_EXTENSION") == "app"]
pick = next((s for s in apps if s.get("PRODUCT_BUNDLE_IDENTIFIER") == want), apps[0] if apps else items[0]["buildSettings"])
for k, v in (("TARGET", "TARGET_NAME"), ("PROJECT_PATH", "PROJECT_FILE_PATH"), ("INFOPLIST", "INFOPLIST_FILE"),
             ("SRCROOT_DIR", "SRCROOT"), ("PROJECT_BUNDLE_ID", "PRODUCT_BUNDLE_IDENTIFIER")):
    print(f"{k}={shlex.quote(pick.get(v, ''))}")
PY
)"
if [ "$PROJECT_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  echo "Warning: the project's bundle id differs from the BUNDLE_ID secret"
fi

# 4. Build number / version / export compliance in the app's Info.plist
PLIST=""
[ -n "$INFOPLIST" ] && PLIST="$SRCROOT_DIR/$INFOPLIST"
if [ -n "$PLIST" ] && [ -f "$PLIST" ] && [ "$TYPE" != flutter ]; then
  CUR="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
  case "$CUR" in '$('*|'') ;; *) /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST" ;; esac
  if [ -n "${APP_VERSION:-}" ]; then
    CUR="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
    case "$CUR" in '$('*|'') ;; *) /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$PLIST" ;; esac
  fi
fi
if [ "${NO_ENCRYPTION:-false}" = true ] && [ -n "$PLIST" ] && [ -f "$PLIST" ]; then
  /usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$PLIST" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c 'Add :ITSAppUsesNonExemptEncryption bool false' "$PLIST"
fi

# 5. Signing
ARCHIVE="$RUNNER_TEMP/app.xcarchive"
EXPORT="$RUNNER_TEMP/export"
EXPORT_PLIST="$RUNNER_TEMP/ExportOptions.plist"
SETTINGS=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
[ -n "${APP_VERSION:-}" ] && SETTINGS+=(MARKETING_VERSION="$APP_VERSION")
[ "${NO_ENCRYPTION:-false}" = true ] && SETTINGS+=(INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO)
AUTH=()

if [ "$SIGNING_MODE" = manual ]; then
  run signing-settings ruby "$SCRIPTS/manual_signing.rb" "$PROJECT_PATH" "$TARGET" "$CONFIG" \
    "$TEAM_ID" "$PROFILE_NAME" "$PROFILE_UUID"
  SETTINGS+=(OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN_PATH")
  STYLE=manual
  PROFILES="<key>provisioningProfiles</key><dict><key>$BUNDLE_ID</key><string>$PROFILE_UUID</string></dict>"
else
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  SETTINGS+=(DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic)
  STYLE=automatic
  PROFILES=""
fi

cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>$STYLE</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  $PROFILES
</dict>
</plist>
EOF

# 6. Archive + export
run archive xcodebuild "$FLAG" "$CONTAINER" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" "${AUTH[@]}" archive "${SETTINGS[@]}"
run export xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$EXPORT" "${AUTH[@]}"

IPA="$(find "$EXPORT" -maxdepth 1 -name '*.ipa' | head -n1)"
[ -n "$IPA" ] || { echo "No .ipa produced"; exit 1; }
echo "IPA_PATH=$IPA" >> "$GITHUB_ENV"
echo "Built .ipa ($(du -h "$IPA" | cut -f1))"
