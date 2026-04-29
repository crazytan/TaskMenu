# Releasing TaskMenu

TaskMenu releases are published from GitHub Actions when a `vX.Y.Z` tag is pushed. The release workflow builds a signed archive, packages it into a DMG, notarizes the DMG with Apple, and uploads the DMG plus a SHA-256 checksum to the GitHub release.

## One-time GitHub setup

Add these repository secrets in GitHub under **Settings -> Secrets and variables -> Actions**:

| Secret | Value |
| --- | --- |
| `GOOGLE_CLIENT_ID` | Google OAuth client ID used by release builds |
| `GOOGLE_CLIENT_SECRET` | Google OAuth client secret used by release builds |
| `MACOS_TEAM_ID` | Apple Developer Team ID, for example `V82M9YX8BR` |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded `.p12` export of your Developer ID Application certificate |
| `BUILD_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` file |
| `KEYCHAIN_PASSWORD` | Any strong temporary password for the CI keychain |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | Apple Developer Team ID used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for the Apple ID |

OAuth client secrets embedded in a desktop app are not truly private once the app is distributed. Keep them out of the repository, but treat them as client configuration rather than server-grade secrets.

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

## Create the Apple app-specific password

Create an app-specific password at <https://account.apple.com/> under **Sign-In and Security -> App-Specific Passwords**. Store that value in `APPLE_APP_SPECIFIC_PASSWORD`.

## Release checklist

1. Move changelog entries from `Unreleased` to a version heading:

```markdown
## v1.0.1 (YYYY-MM-DD)
```

2. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
3. Regenerate the project if you want the checked-in `.xcodeproj` to reflect the new version:

```bash
xcodegen generate
```

4. Run tests:

```bash
xcodebuild -scheme TaskMenu -configuration Debug test
```

5. Commit and push to `main`.
6. Create and push the release tag:

```bash
git tag -a v1.0.1 -m "TaskMenu v1.0.1"
git push origin main v1.0.1
```

The release workflow validates that the tag version matches `MARKETING_VERSION` and that `CHANGELOG.md` has a matching section before it publishes anything.

## Manual workflow dispatch

You can also run **Release** manually from GitHub Actions. Enter the version without the leading `v`. The workflow still expects `project.yml` and `CHANGELOG.md` to match that version.

## Local DMG packaging

After producing a signed app bundle, you can package it locally:

```bash
SIGNING_IDENTITY="Developer ID Application" \
APPLE_ID="you@example.com" \
APPLE_TEAM_ID="V82M9YX8BR" \
APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
./scripts/make_dmg.sh \
  --app build/TaskMenu.xcarchive/Products/Applications/TaskMenu.app \
  --version 1.0.1 \
  --output-dir build/artifacts
```
