---
name: release
description: >
  Prepare and publish a TaskMenu macOS release. Bumps the XcodeGen project version,
  updates CHANGELOG.md, regenerates TaskMenu.xcodeproj, runs macOS build/test
  verification, commits, tags, and pushes to trigger the GitHub Actions release
  workflow that signs, notarizes, packages, and publishes the DMG, then updates
  the Homebrew cask in crazytan/homebrew-tap. Use whenever the user wants to cut
  a release, create a release candidate, bump the version, ship a new version,
  prepare a build, or push a new TaskMenu release.
---

# TaskMenu Release Workflow

This is a sequential, high-stakes workflow. Do not skip steps or continue past a
failed validation. TaskMenu releases are published by GitHub Actions when a
`vX.Y.Z` tag is pushed.

## Usage

The user normally invokes this skill with a version:

```bash
/release 1.0.1
```

If no version is provided, read `MARKETING_VERSION` from `project.yml`, suggest
the next patch bump, and ask the user to confirm before editing files.

## Step 1: Validate Release State

1. Read `project.yml` and extract the current global `MARKETING_VERSION`.
2. Run `git status --short`; if unrelated changes are present, stop and ask how
   to proceed. Do not stage or commit unrelated work.
3. Run `git tag --list 'v*'` and verify `v{version}` does not already exist.
4. Verify the requested version:
   - Uses strict semver: `MAJOR.MINOR.PATCH`.
   - Is greater than the current `MARKETING_VERSION`.
   - Will use the corresponding release tag `v{version}`.

If validation fails, explain the specific problem and ask for a corrected
version. Do not proceed until validation passes.

## Step 2: Draft and Confirm Release Notes

1. Read `CHANGELOG.md`.
2. Leave `## TODO` untouched.
3. Find `## Unreleased` and collect entries until the next `## v...` heading.
4. If `Unreleased` is empty, warn the user and ask before creating an empty
   release section. The GitHub release workflow rejects empty notes.
5. Organize the collected entries into a small set of high-level, public
   release-note categories. Prefer familiar headings such as `Added`, `Changed`,
   `Fixed`, `Removed`, `Security`, or `Known Issues`; merge sparse categories
   instead of creating many one-off headings, and omit empty categories.
6. Strip away internal-only notes before showing or writing release notes:
   remove implementation details, PR bookkeeping, local testing notes, debug
   notes, file paths, refactor-only commentary, TODOs, and maintainer rationale
   unless they directly describe user-visible behavior. Do not invent features;
   rewrite only enough to make the notes public-facing.
7. Present the organized release notes draft to the user and ask whether it
   looks good. Stop until the user approves or requests edits. Do not update
   `CHANGELOG.md`, `project.yml`, or generated files until the release notes are
   confirmed.

## Step 3: Update CHANGELOG.md

Move the confirmed notes into a new section directly below `## Unreleased`:

```markdown
## Unreleased

## v{version} ({YYYY-MM-DD})

### Added
- ...
```

Preserve the confirmed public-facing wording exactly except for mechanical
Markdown formatting needed to fit the changelog.

## Step 4: Update project.yml

TaskMenu keeps version settings in the global `settings.base` block.

1. Set `MARKETING_VERSION` to the requested version string.
2. Set `CURRENT_PROJECT_VERSION` to `"1"` unless the user explicitly requested a
   different build number.

Use a precise edit. Do not edit `TaskMenu.xcodeproj` directly.

## Step 5: Regenerate and Verify

Regenerate the project after changing `project.yml`:

```bash
xcodegen generate
```

Run local release verification:

```bash
xcodebuild build \
  -project TaskMenu.xcodeproj \
  -scheme TaskMenu \
  -configuration Debug \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=""

xcodebuild test \
  -project TaskMenu.xcodeproj \
  -scheme TaskMenu \
  -configuration Debug \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=""
```

Confirm the release notes section is extractable:

```bash
./scripts/extract_changelog.sh "{version}"
```

If `Config.xcconfig` is missing locally, create a temporary untracked
`Config.xcconfig` with dummy OAuth values before running verification. Do not
overwrite an existing config file and do not commit this file. If verification
fails, stop, report the failure, and help fix it if asked.

## Step 6: Commit, Tag, and Push

Only reach this step after build and tests pass.

1. Stage only release files:

```bash
git add project.yml CHANGELOG.md TaskMenu.xcodeproj
```

2. Commit:

```bash
git commit -m "Release v{version}"
```

3. Create an annotated tag:

```bash
git tag -a "v{version}" -m "TaskMenu v{version}"
```

4. Push main and the tag:

```bash
git push origin main "v{version}"
```

After pushing, tell the user that GitHub Actions will build the signed archive,
notarize the DMG, upload the checksum, and publish or update the GitHub release.
The workflow validates that the tag version matches `MARKETING_VERSION` and that
`CHANGELOG.md` contains a non-empty matching section. Do not call the release
complete until Step 7 updates the Homebrew cask, or until you have clearly told
the user that the release workflow is still running and the Homebrew update is
pending.

## Step 7: Update Homebrew Cask

Only reach this step after the GitHub release has published the DMG and
`TaskMenu-{version}.dmg.sha256` assets. If the release workflow is still
running, check its status with `gh run list` or `gh run watch` and wait when the
user asked you to complete the release end to end.

1. Verify the GitHub release and checksum asset exist:

```bash
gh release view "v{version}" --repo crazytan/TaskMenu
curl -LfsS \
  "https://github.com/crazytan/TaskMenu/releases/download/v{version}/TaskMenu-{version}.dmg.sha256"
```

2. Update the cask in the Homebrew tap:

```bash
brew tap crazytan/tap
cd "$(brew --repository crazytan/tap)"

sha256="$(curl -LfsS "https://github.com/crazytan/TaskMenu/releases/download/v{version}/TaskMenu-{version}.dmg.sha256" | awk '{print $1}')"

perl -0pi -e 's/version "[^"]+"/version "{version}"/' Casks/taskmenu.rb
perl -0pi -e "s/sha256 \"[0-9a-f]+\"/sha256 \"${sha256}\"/" Casks/taskmenu.rb
```

3. Validate the updated cask:

```bash
brew audit --cask --strict crazytan/tap/taskmenu
brew livecheck --cask crazytan/tap/taskmenu
```

4. Commit and push only the cask change:

```bash
git add Casks/taskmenu.rb
git commit -m "Update TaskMenu to {version}"
git push
```

Report the Homebrew install command in the final release summary:

```bash
brew install --cask crazytan/tap/taskmenu
```

## Manual Dispatch Alternative

If the user explicitly wants a manual workflow dispatch instead of pushing a tag,
ensure `project.yml` and `CHANGELOG.md` already match the version, then use the
GitHub Actions `Release` workflow with the version input without the leading `v`.
After the workflow publishes the release assets, still complete Step 7.
