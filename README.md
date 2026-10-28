# public-work-ios

Runner repo for iOS releases without a Mac: only GitHub Actions workflows live here
(public = free macOS runners). App code stays in its private repo and is fetched at
build time with a read-only token. No app code, app names beyond the env names, bundle
ids or keys are stored in this repo.

| Workflow | What it does |
| --- | --- |
| **iOS TestFlight** | Build the app from its private repo, sign it, upload to TestFlight |
| **iOS Production** | Submit a build that is already on TestFlight to App Store review (needs approval) |
| **iOS Verify Setup** | Check secrets, repo access, certificate/profile, App Store Connect key, without building |
| Clean up runs | Deletes every finished run (and its logs) when an iOS run ends (public repo) |

Apps: `suum`, `pillowo`, `splik`. Run any workflow from **Actions → workflow → Run workflow**.

## Security model

- Each app has two GitHub **environments**: `<app>` (TestFlight build) and `<app>-production`
  (App Store submit, **requires your approval** before it runs). Both only accept runs from `main`.
- All values are **environment secrets** (masked in logs, never readable back, not available to forks).
- Workflows only start manually (`workflow_dispatch`), so only repo admins/writers can run them.
  No `pull_request` triggers, fork PR runs need approval, `GITHUB_TOKEN` is read-only.
- Actions are pinned to commit SHAs and only GitHub-owned actions + `subosito/flutter-action` are allowed.
- Build output goes to files on the runner; only error lines are printed. Nothing is uploaded as an
  artifact. The run and its logs are **deleted automatically** when it finishes. To keep a run for debugging,
  set the repository variable `KEEP_LOGS=true`, re-run, then delete the variable.
- Signing keychain, keys and profiles are deleted at the end of the job (the runner VM is also discarded).

## Secrets per app

Set them with the helper (asks each value, nothing echoed or saved):

```bash
gh auth login                       # as Bhautik-4B
bash scripts/set-secrets.sh suum    # then pillowo, splik
```

| Secret | Env | Value |
| --- | --- | --- |
| `PRIVATE_REPO` | `<app>` | `owner/repo` of the app's private repo |
| `PRIVATE_REPO_TOKEN` | repo-level (shared) | Read-only token for that repo (see below) |
| `GAHAN_PRIVATE_REPO_TOKEN` | repo-level | Token for Splik's repo (different owner); used instead of `PRIVATE_REPO_TOKEN` for `splik` |
| `PRIVATE_REF` | `<app>` | Branch built by default (optional; e.g. `testflight-productions`) |
| `BUNDLE_ID` | both | e.g. `com.company.app` |
| `TEAM_ID` | `<app>` | Apple Team ID (optional in manual signing: taken from the profile) |
| `ASC_KEY_ID` | both | App Store Connect API key ID |
| `ASC_ISSUER_ID` | both | App Store Connect issuer ID |
| `ASC_KEY_P8` | both | Full text of `AuthKey_XXXX.p8` |
| `CERTIFICATES_P12` | `<app>` | base64 of the Apple Distribution `.p12` (manual signing) |
| `P12_PASSWORD` | `<app>` | its password |
| `BUILD_PROVISION_PROFILE` | `<app>` | base64 of the **App Store** `.mobileprovision` |
| `APP_DIR`, `IOS_WORKSPACE`, `IOS_SCHEME`, `IOS_CONFIGURATION`, `WEB_BUILD_CMD` | `<app>` | optional overrides; auto-detected otherwise |

**Signing modes.** With `CERTIFICATES_P12` set: manual signing with the .p12 + profile (the old setup).
Without it: Xcode signs automatically through the API key (key role **Admin**, `TEAM_ID` required) —
use this for apps with extensions (widgets, notification service) that need several profiles.

### Private repo token

On the account that owns the private app repos: **Settings → Developer settings → Fine-grained
tokens → Generate new token**

- Resource owner: the account/org that owns the app repos
- Repository access: **Only select repositories** → the Suum, Pillowo, Splik repos
- Permissions: **Contents: Read-only** (Metadata read-only is added automatically). Nothing else.
- Expiration: e.g. 1 year (renew and re-run `set-secrets.sh` before it ends)

The same token can be used for all three apps.

## One-time Apple setup on Linux (no Mac)

App Store Connect API key: **App Store Connect → Users and Access → Integrations → App Store Connect API →
(+)**, role **App Manager** (manual signing) or **Admin** (automatic signing). Download the `.p8` once.

Distribution certificate (one per team, reuse for all apps of that team):

```bash
openssl req -nodes -newkey rsa:2048 -keyout dist.key -out dist.csr -subj "/CN=Distribution/C=IN"
# developer.apple.com → Certificates → (+) → Apple Distribution → upload dist.csr → download distribution.cer
openssl x509 -in distribution.cer -inform DER -out dist.pem
openssl pkcs12 -export -legacy -inkey dist.key -in dist.pem -out dist.p12   # -legacy: macOS keychain can read it
```

Profile per app: **Profiles → (+) → App Store Connect → the app's App ID → the certificate above** → download.

The app record must exist in App Store Connect (**Apps → (+) New App** with the same bundle id) before
the first upload.

## Running

- **TestFlight:** Actions → *iOS TestFlight* → app, optional branch/version. Build number is automatic
  (`yyDDDHHMM`, always increasing). Apple processes the build in ~5–30 min.
- **Production:** Actions → *iOS Production* → app; empty version/build = latest TestFlight build.
  Approve the run on the run page. Fill the store listing in App Store Connect first.
- **Verify:** Actions → *iOS Verify Setup* → `all` after changing any secret.
