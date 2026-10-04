# Release scripts

- `extract_changelog.sh` extracts release notes for a version from `CHANGELOG.md`.
- `install_developer_id_profiles.py` validates the app and widget profiles against the installed signing identity, team, bundle IDs, expiration, and shared capabilities; installs them and exports their UUIDs for manual signing in GitHub Actions.
- `make_dmg.sh` verifies the signed app and widget, packages the DMG, and notarizes it.
- `stamp_build_metadata.sh` records the checked-out commit in generated build metadata.

Signing certificates and provisioning profiles are supplied through repository secrets; do not commit them.
