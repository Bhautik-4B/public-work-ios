#!/usr/bin/env bash
# Puts the App Store Connect key, the distribution certificate and the
# provisioning profile in place on the macOS runner and checks that they fit
# together. Used by both the build and the verify workflows.
#
# Signing mode:
#   manual - CERTIFICATES_P12 is set: the .p12 + App Store provisioning profile
#            from the secrets are used (same as the old setup).
#   auto   - no CERTIFICATES_P12: Xcode signs itself through the App Store
#            Connect API key (key must have the Admin role) and TEAM_ID.
#
# In:  ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 BUNDLE_ID TEAM_ID
#      CERTIFICATES_P12 P12_PASSWORD BUILD_PROVISION_PROFILE
# Out: GITHUB_ENV  SIGNING_MODE ASC_KEY_PATH KEYCHAIN_PATH TEAM_ID PROFILE_UUID PROFILE_NAME
set -uo pipefail

FAILS=0
ok()   { echo "  OK    $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
env_out() { echo "$1=$2" >> "$GITHUB_ENV"; }

echo "App Store Connect API key"
KEY_DIR="$RUNNER_TEMP/private_keys"
mkdir -p "$KEY_DIR"
ASC_KEY_PATH="$KEY_DIR/AuthKey_${ASC_KEY_ID:-missing}.p8"
# Clean PEM even if the secret was pasted on one line / with literal \n.
BODY="$(printf '%s' "${ASC_KEY_P8:-}" | sed 's/\\n/ /g; s/-----[^-]*-----//g' | tr -d ' \r\n\t')"
{ echo "-----BEGIN PRIVATE KEY-----"; printf '%s' "$BODY" | fold -w 64; echo; echo "-----END PRIVATE KEY-----"; } > "$ASC_KEY_PATH"
chmod 600 "$ASC_KEY_PATH"
[ -n "${ASC_KEY_ID:-}" ]     && ok "key id set"     || fail "ASC_KEY_ID missing"
[ -n "${ASC_ISSUER_ID:-}" ]  && ok "issuer id set"  || fail "ASC_ISSUER_ID missing"
grep -q 'BEGIN PRIVATE KEY' "$ASC_KEY_PATH" && ok ".p8 key looks valid" || fail "ASC_KEY_P8 is not a .p8 private key"
[ -n "${BUNDLE_ID:-}" ] && ok "bundle id set" || fail "BUNDLE_ID missing"
env_out ASC_KEY_PATH "$ASC_KEY_PATH"

if [ -z "${CERTIFICATES_P12:-}" ]; then
  echo "Signing: auto (Xcode cloud signing with the API key)"
  env_out SIGNING_MODE auto
  [ -n "${TEAM_ID:-}" ] && ok "team id set" || fail "TEAM_ID missing (needed for auto signing)"
  env_out TEAM_ID "${TEAM_ID:-}"
  [ "$FAILS" -eq 0 ] || { echo "$FAILS problem(s)"; exit 1; }
  exit 0
fi

echo "Signing: manual (.p12 + provisioning profile)"
env_out SIGNING_MODE manual
[ -n "${P12_PASSWORD:-}" ] || fail "P12_PASSWORD missing"
[ -n "${BUILD_PROVISION_PROFILE:-}" ] || { fail "BUILD_PROVISION_PROFILE missing"; echo "$FAILS problem(s)"; exit 1; }

CERT_PATH="$RUNNER_TEMP/dist.p12"
PP_PATH="$RUNNER_TEMP/app.mobileprovision"
PP_PLIST="$RUNNER_TEMP/app-profile.plist"
KEYCHAIN_PATH="$RUNNER_TEMP/app-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
printf '%s' "$CERTIFICATES_P12" | base64 --decode > "$CERT_PATH" 2>/dev/null || fail "CERTIFICATES_P12 is not valid base64"
printf '%s' "$BUILD_PROVISION_PROFILE" | base64 --decode > "$PP_PATH" 2>/dev/null || fail "BUILD_PROVISION_PROFILE is not valid base64"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
import_p12() { security import "$1" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH" >/dev/null 2>&1; }
if import_p12 "$CERT_PATH"; then
  ok "certificate imported (P12_PASSWORD correct)"
else
  # A .p12 made by OpenSSL 3 (modern encryption) is rejected by the keychain:
  # re-pack it in the legacy format with Homebrew's OpenSSL 3 and retry.
  OSSL="$(ls /opt/homebrew/bin/openssl /usr/local/bin/openssl 2>/dev/null | head -n1)"
  PEM="$RUNNER_TEMP/dist.pem"; LEGACY="$RUNNER_TEMP/dist-legacy.p12"
  if [ -n "$OSSL" ] \
    && "$OSSL" pkcs12 -in "$CERT_PATH" -passin env:P12_PASSWORD -nodes -out "$PEM" 2>/dev/null \
    && "$OSSL" pkcs12 -export -legacy -in "$PEM" -out "$LEGACY" -passout env:P12_PASSWORD 2>/dev/null \
    && import_p12 "$LEGACY"; then
    ok "certificate imported (re-packed to legacy format)"
  else
    fail "cannot import CERTIFICATES_P12 - wrong P12_PASSWORD or not a .p12"
  fi
  rm -f "$PEM" "$LEGACY"
fi
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null 2>&1
security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')
rm -f "$CERT_PATH"
env_out KEYCHAIN_PATH "$KEYCHAIN_PATH"

IDENTITY_SHA1="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | awk '/Distribution/ {print $2; exit}')"
if [ -n "$IDENTITY_SHA1" ]; then
  ok "Apple Distribution signing identity found"
  END="$(security find-certificate -a -Z -p "$KEYCHAIN_PATH" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  if [ -n "$END" ]; then
    END_TS="$(date -j -f '%b %e %T %Y %Z' "$END" +%s 2>/dev/null || echo 0)"
    if [ "$END_TS" -gt "$(date +%s)" ]; then ok "certificate valid until $END"; else fail "certificate expired ($END)"; fi
  fi
else
  fail "no 'Apple Distribution' identity (certificate + private key) in CERTIFICATES_P12"
fi

if security cms -D -i "$PP_PATH" > "$PP_PLIST" 2>/dev/null; then
  pp() { /usr/libexec/PlistBuddy -c "Print :$1" "$PP_PLIST" 2>/dev/null; }
  UUID="$(pp UUID)"; NAME="$(pp Name)"; PP_TEAM="$(pp TeamIdentifier:0)"
  APP_ID="$(pp Entitlements:application-identifier)"
  ok "provisioning profile decoded"
  if pp ProvisionedDevices >/dev/null || pp ProvisionsAllDevices >/dev/null; then
    fail "profile is Development/Ad Hoc/Enterprise - it must be an 'App Store' distribution profile"
  else
    ok "profile type is App Store"
  fi
  EXP="$(pp ExpirationDate)"
  EXP_TS="$(date -j -f '%a %b %d %T %Z %Y' "$EXP" +%s 2>/dev/null || echo 0)"
  if [ "$EXP_TS" -gt "$(date +%s)" ]; then ok "profile valid until $EXP"; else fail "profile expired ($EXP)"; fi
  if [ "$APP_ID" = "$PP_TEAM.${BUNDLE_ID:-}" ] || [ "$APP_ID" = "$PP_TEAM.*" ]; then
    ok "profile matches BUNDLE_ID"
  else
    fail "profile is for a different app id than BUNDLE_ID"
  fi
  if [ -n "${TEAM_ID:-}" ] && [ "$TEAM_ID" != "$PP_TEAM" ]; then fail "TEAM_ID differs from the profile's team"; fi
  MATCH=no; i=0
  while CERT_B64="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$PP_PLIST" 2>/dev/null)"; do
    SHA="$(printf '%s' "$CERT_B64" | base64 --decode | shasum -a 1 | awk '{print toupper($1)}')"
    [ "$SHA" = "$IDENTITY_SHA1" ] && MATCH=yes
    i=$((i + 1))
  done
  [ "$MATCH" = yes ] && ok "profile contains the .p12 certificate" || fail "profile was not made with the certificate in CERTIFICATES_P12"

  mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  cp "$PP_PATH" "$HOME/Library/MobileDevice/Provisioning Profiles/$UUID.mobileprovision"
  cp "$PP_PATH" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$UUID.mobileprovision"
  env_out PROFILE_UUID "$UUID"
  env_out PROFILE_NAME "$NAME"
  env_out TEAM_ID "${TEAM_ID:-$PP_TEAM}"
else
  fail "BUILD_PROVISION_PROFILE is not a .mobileprovision file"
fi
rm -f "$PP_PLIST"

[ "$FAILS" -eq 0 ] || { echo "$FAILS problem(s)"; exit 1; }
echo "Signing ready"
