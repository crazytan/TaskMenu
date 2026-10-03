# Releasing TaskMenu

TaskMenu releases are published from GitHub Actions when a `vX.Y.Z` tag is pushed. The release workflow builds a signed archive, packages it into a DMG, notarizes the DMG with Apple, and uploads the DMG plus a SHA-256 checksum to the GitHub release.

Homebrew cask distribution is maintained in the public [`crazytan/homebrew-tap`](https://github.com/crazytan/homebrew-tap) repository.

TaskMenu ships an embedded macOS WidgetKit app extension, `TaskMenuWidget.appex`, nested inside `TaskMenu.app/Contents/PlugIns/`. The app and the extension are separately signed, sandboxed, and hardened-runtime, and are embedded by a build-time dependency in `project.yml` (`TaskMenu` target: `dependencies: [target: TaskMenuWidget, embed: true, codeSign: true]`). **Read "One-time Apple Developer portal setup" below before attempting any signed build** — it is a hard prerequisite that did not exist before this feature.

## One-time Apple Developer portal setup (required before any signed build)

The widget's App Group and shared Keychain access group entitlements make a provisioning profile mandatory. **Until the identifiers below are registered in the Apple Developer account, every signed build fails** — a local signed Debug build, the Developer ID `Release` archive, and the `AppStore` archive alike — with:

```text
No profiles for 'dev.crazytan.TaskMenu' were found
```

This is a one-time portal action **only the Apple Developer account owner can perform** (Certificates, Identifiers & Profiles at [developer.apple.com/account/resources](https://developer.apple.com/account/resources/identifiers/list)). No agent, script, or CI job in this repository registers portal identifiers or runs `xcodebuild -allowProvisioningUpdates`; see `scratch/issue-11-desktop-widget/OWNER-ACTIONS.md` for the full handoff. Register, in this order:

1. **App Group**: `group.dev.crazytan.TaskMenu.shared` (Identifiers → App Groups).
2. **App ID** `dev.crazytan.TaskMenu` (the main app): enable **App Groups** (assign the group above) and **Keychain Sharing**.
3. **App ID** `dev.crazytan.TaskMenu.Widget` (the widget extension): enable the same two capabilities, assigned to the same App Group.
4. Regenerate/download provisioning profiles for **both** distribution paths once the App IDs carry the new capabilities — the Developer ID profile (the `Release` configuration / DMG path below) and the Mac App Store profile (the `AppStore` configuration / Xcode Organizer path). Xcode regenerates automatic-signing profiles once the portal side is done; a manually managed profile needs a fresh download.

The entitlement/runtime string is **not** the same as the portal registration string, by design — macOS requires the team prefix on App Group identifiers, so `project.yml` builds the runtime value as `$(DEVELOPMENT_TEAM).group.dev.crazytan.TaskMenu.shared` (the portal registration itself stays unprefixed: `group.dev.crazytan.TaskMenu.shared`). The shared Keychain access group is `$(DEVELOPMENT_TEAM).dev.crazytan.TaskMenu.shared`. Both expand through `$(DEVELOPMENT_TEAM)` (the team ID, e.g. `V82M9YX8BR` — see `APPLE_TEAM_ID` below), never `$(AppIdentifierPrefix)`/`$(TeamIdentifierPrefix)`, which only expand once a provisioning profile is already present — using them here would leak a literal unexpanded `$(...)` into the entitlement on exactly the builds that need it to resolve.

An **unsigned** build — `CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""`, the invocation CI uses — is unaffected by any of this: it still compiles, links, and embeds `TaskMenuWidget.appex` without a provisioning profile. Runtime code (`SharedConstants.appGroupIdentifier` / `.keychainAccessGroup`) treats an empty/unexpanded value as absent and degrades gracefully (no shared container, no shared Keychain group) rather than crashing, which is what makes CI's unsigned build meaningful despite never resolving real identifiers.

### Verifying the embedded widget extension in a signed build

Confirm these on every release archive, not only when widget code itself changes — a signing or `project.yml` regression can silently drop the embed step without failing an unsigned CI build:

```bash
APP="build/TaskMenu.xcarchive/Products/Applications/TaskMenu.app"

# 1. The extension exists inside the archived app.
test -d "$APP/Contents/PlugIns/TaskMenuWidget.appex" && echo "widget appex present"

# 2. Both binaries carry the App Group and Keychain Sharing entitlements.
codesign -d --entitlements :- "$APP"
codesign -d --entitlements :- "$APP/Contents/PlugIns/TaskMenuWidget.appex"

# 3. Deep, strict signature verification across the whole nested bundle,
#    including the embedded extension.
codesign --verify --deep --strict --verbose=2 "$APP"
```

`scripts/make_dmg.sh` already runs step 3 before packaging the DMG, so a broken or unsigned nested extension fails the release job outright. The GitHub Actions release workflow additionally runs steps 1 and 2 (job step "Verify embedded widget extension", right after archiving) because `codesign --verify` alone only validates whatever it finds inside the bundle — it does not assert that `TaskMenuWidget.appex` exists at all, so a silently-broken embed step would otherwise pass unnoticed.

## One-time GitHub setup

Add these repository secrets in GitHub under **Settings -> Secrets and variables -> Actions -> Secrets**:

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded `.p12` export of your Developer ID Application certificate |
| `BUILD_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` file |
| `APP_STORE_CONNECT_API_KEY_BASE64` | Base64-encoded App Store Connect API private key (`.p8`) |
| `GOOGLE_CLIENT_ID` | Google OAuth client ID used by release builds |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect issuer ID |

Add these repository variables under **Settings -> Secrets and variables -> Actions -> Variables**:

| Variable | Value |
| --- | --- |
| `GOOGLE_REDIRECT_SCHEME` | Google OAuth redirect scheme, for example `com.googleusercontent.apps.<client-id-prefix>` |
| `APPLE_TEAM_ID` | Apple Developer Team ID, for example `V82M9YX8BR` |

The release workflow also accepts `GOOGLE_REDIRECT_SCHEME` and `APPLE_TEAM_ID` as secrets for compatibility, but variables are preferred when the values are not sensitive.

TaskMenu uses a native OAuth client with PKCE, so release builds do not embed a Google client secret.

## Export the signing certificate

1. Open **Keychain Access** on the Mac that has your Developer ID certificate.
2. Find **Developer ID Application: Your Name (TEAMID)**.
3. Expand the certificate row and make sure the private key is included.
4. Select the certificate and private key together, then choose **File -> Export Items...**.
5. Save as `DeveloperIDApplication.p12` and set a strong export password.
6. Copy the base64 form into the GitHub secret:

```bash
base64 -i DeveloperIDApplication.p12 | tr -d '\n' | pbcopy
```

Paste the clipboard into `BUILD_CERTIFICATE_BASE64`. Put the export password in `BUILD_CERTIFICATE_PASSWORD`.

### Replacing a Developer ID certificate

Use a **G2 Sub-CA** Developer ID Application certificate. Certificates from the previous Sub-CA stop working on February 1, 2027. Replace both `BUILD_CERTIFICATE_BASE64` and `BUILD_CERTIFICATE_PASSWORD` together, using a `.p12` that contains the new certificate and its matching private key.

After updating the secrets, run the **Check signing certificate** workflow with the new certificate's 40-character SHA-1 fingerprint. It checks the actual GitHub secrets, G2 issuer, at least 30 days of validity, private-key access, and timestamped signing on a macOS runner without publishing a release. Existing notarized, securely timestamped DMGs do not need to be replaced for this authority transition.

## Create the App Store Connect API key

Create an App Store Connect API key in **App Store Connect -> Users and Access -> Integrations -> App Store Connect API**. A key with Developer access is enough for notarization.

Download the `.p8` key once, then copy the base64 form into `APP_STORE_CONNECT_API_KEY_BASE64`:

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy
```

Store the key ID in `APP_STORE_CONNECT_KEY_ID` and the issuer ID in `APP_STORE_CONNECT_ISSUER_ID`.

## Notarization troubleshooting

If Apple rejects the submission (status `Invalid`), the release job prints the full notarization log from `notarytool log` before failing. The per-file issues in that log are the place to start.

If the release job fails with:

```text
HTTP status code: 401. Unauthenticated.
```

then Apple rejected the App Store Connect API credentials. Check these values first:

- `APP_STORE_CONNECT_API_KEY_BASE64` must be the base64 text of the downloaded `.p8` private key file, not the JSON key metadata.
- `APP_STORE_CONNECT_KEY_ID` must match the key ID shown for that same `.p8` file.
- `APP_STORE_CONNECT_ISSUER_ID` must be the issuer ID from App Store Connect API access.
- The API key must be active, team-scoped, and have at least Developer access.

You can validate the same credentials locally before pushing a tag:

```bash
xcrun notarytool history \
  --key "$HOME/private_keys/AuthKey_XXXXXXXXXX.p8" \
  --key-id "XXXXXXXXXX" \
  --issuer "00000000-0000-0000-0000-000000000000"
```

## Release checklist

1. Move changelog entries from `Unreleased` to a version heading:

```markdown
## vX.Y.Z (YYYY-MM-DD)
```

2. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
3. Regenerate the project if you want the checked-in `.xcodeproj` to reflect the new version:

```bash
xcodegen generate
```

4. Run tests:

```bash
xcodebuild test -project TaskMenu.xcodeproj -scheme TaskMenu \
  -configuration Debug \
  -destination "platform=macOS"
```

5. Commit and push to `main`.
6. Create and push the release tag:

```bash
git tag -a vX.Y.Z -m "TaskMenu vX.Y.Z"
git push origin main vX.Y.Z
```

The release workflow validates that the tag version matches `MARKETING_VERSION` and that `CHANGELOG.md` has a matching section before it publishes anything.

7. After the GitHub release publishes, update the Homebrew cask in `crazytan/homebrew-tap`:

```bash
brew tap crazytan/tap
cd "$(brew --repository crazytan/tap)"

version="${VERSION:-$(gh release view --repo crazytan/TaskMenu --json tagName --jq '.tagName | sub("^v"; "")')}"
sha256="$(curl -LfsS "https://github.com/crazytan/TaskMenu/releases/download/v${version}/TaskMenu-${version}.dmg.sha256" | awk '{print $1}')"

perl -0pi -e "s/version \"[^\"]+\"/version \"${version}\"/" Casks/taskmenu.rb
perl -0pi -e "s/sha256 \"[0-9a-f]+\"/sha256 \"${sha256}\"/" Casks/taskmenu.rb

brew audit --cask --strict crazytan/tap/taskmenu
brew livecheck --cask crazytan/tap/taskmenu

git add Casks/taskmenu.rb
git commit -m "Update TaskMenu to ${version}"
git push
```

## Manual workflow dispatch

You can also run **Release** manually from GitHub Actions. Enter the version without the leading `v` and choose whether the GitHub release should be marked as a prerelease. The workflow still expects `project.yml` and `CHANGELOG.md` to match that version.

Two guards apply to manual runs:

- If the tag `vX.Y.Z` already exists, the workflow must be dispatched from that tag (or a ref pointing at the same commit); it fails if the checked-out commit differs from the tagged commit. If the tag does not exist yet, publishing creates it at the dispatched commit.
- Release assets are immutable: if the release already has a DMG or checksum with the same name, the upload fails instead of replacing it. Delete the bad asset (or the release) manually first if you really need to republish.

## Local DMG packaging

After producing a signed app bundle, you can package it locally:

```bash
VERSION="X.Y.Z"
SIGNING_IDENTITY="Developer ID Application" \
APP_STORE_CONNECT_KEY_ID="XXXXXXXXXX" \
APP_STORE_CONNECT_ISSUER_ID="00000000-0000-0000-0000-000000000000" \
APP_STORE_CONNECT_KEY_PATH="$HOME/private_keys/AuthKey_XXXXXXXXXX.p8" \
./scripts/make_dmg.sh \
  --app build/TaskMenu.xcarchive/Products/Applications/TaskMenu.app \
  --version "$VERSION" \
  --output-dir build/artifacts
```

When the `APP_STORE_CONNECT_*` variables are set, the script notarizes the DMG, staples it, and runs a Gatekeeper assessment (`spctl --assess`) that must pass. Without them it skips notarization and prints `skipping Gatekeeper assessment (no notarization credentials)`; such a DMG is fine for local testing but is not distributable.

## Mac App Store builds

The Mac App Store gets a different binary from the DMG. Two App Review guidelines require it:

- **2.4.5(vii)** - the Mac App Store delivers its own updates, so the app must not ship a second update path. The `AppStore` configuration compiles out `GitHubUpdateChecker`, `Constants.githubLatestReleaseURL`, the automatic check loop, and the update UI in Settings.
- **3.1.1** - donations must go through In-App Purchase, so the "Buy Me a Coffee" link is compiled out too.

Both are gated on the `APP_STORE_BUILD` compilation condition, which only the `AppStore` configuration defines. `Debug` and `Release` are unchanged, so the DMG and Homebrew builds keep the update checker and the tip link. `TaskMenuWidget` compiles unconditionally in all three configurations (`Debug`, `Release`, `AppStore`) and is unaffected by `APP_STORE_BUILD` — the widget ships to Mac App Store users exactly as it does in the DMG.

Archive with the dedicated scheme:

```bash
xcodebuild archive -project TaskMenu.xcodeproj -scheme "TaskMenu (App Store)" -configuration AppStore -destination "platform=macOS" -archivePath build/TaskMenu-AppStore.xcarchive
```

Then upload the archive through Xcode's Organizer (Distribute App -> App Store Connect), which applies the Mac App Distribution signing and the App Store provisioning profile — the App Store provisioning profile from "One-time Apple Developer portal setup" above, which must carry the App Group and Keychain Sharing capabilities for both `dev.crazytan.TaskMenu` and `dev.crazytan.TaskMenu.Widget` or the archive step fails the same way the Developer ID path does. Before uploading, run the "Verifying the embedded widget extension" checks above against this archive's `.app` too.

To confirm the gating held before uploading, check the built binary for the strings that should be absent:

```bash
strings -a build/TaskMenu-AppStore.xcarchive/Products/Applications/TaskMenu.app/Contents/MacOS/TaskMenu | grep -E "api\.github\.com|buymeacoffee|Automatically check for updates"
```

That command must print nothing. Running the same check against a `Release` build prints matches, which is the expected difference between the two configurations.
