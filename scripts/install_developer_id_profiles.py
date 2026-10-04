#!/usr/bin/env python3
"""Validate and install the app and widget profiles supplied by CI secrets."""

import base64
import datetime
import fnmatch
import hashlib
import os
import pathlib
import plistlib
import re
import subprocess
import tempfile


def install_profiles():
    team = os.environ["APPLE_TEAM_ID"]
    identities = subprocess.check_output(
        ["security", "find-identity", "-v", "-p", "codesigning"], text=True
    )
    available = set(re.findall(r"\b[0-9A-F]{40}\b", identities))
    expected = os.environ.get("EXPECTED_CERTIFICATE_SHA1", "").upper()
    group = f"{team}.group.dev.crazytan.TaskMenu.shared"
    keychain_group = f"{team}.dev.crazytan.TaskMenu.shared"
    destinations = [
        pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
        pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles",
    ]
    profiles = []
    for suffix, bundle, variable in [
        ("APP", "dev.crazytan.TaskMenu", "TASKMENU_DEVELOPER_ID_PROFILE"),
        ("WIDGET", "dev.crazytan.TaskMenu.Widget", "TASKMENU_WIDGET_DEVELOPER_ID_PROFILE"),
    ]:
        content = base64.b64decode(
            os.environ[f"DEVELOPER_ID_{suffix}_PROFILE_BASE64"], validate=True
        )
        with tempfile.NamedTemporaryFile(suffix=".provisionprofile") as temporary:
            temporary.write(content)
            temporary.flush()
            decoded = subprocess.check_output(
                ["security", "cms", "-D", "-i", temporary.name]
            )
        profile = plistlib.loads(decoded)
        entitlements = profile["Entitlements"]
        if profile["TeamIdentifier"] != [team]:
            raise ValueError(f"Wrong team for {bundle}")
        identifier = entitlements.get("com.apple.application-identifier")
        if identifier != f"{team}.{bundle}":
            raise ValueError(f"Wrong app identifier for {bundle}")
        if "ProvisionedDevices" in profile or entitlements.get("get-task-allow"):
            raise ValueError(f"Expected a distribution profile for {bundle}")
        if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
            raise ValueError(f"Expired profile for {bundle}")
        for key, required in [
            ("com.apple.security.application-groups", group),
            ("keychain-access-groups", keychain_group),
        ]:
            if not any(fnmatch.fnmatchcase(required, allowed) for allowed in entitlements.get(key, [])):
                raise ValueError(f"Profile for {bundle} does not authorize {key}")
        fingerprints = {hashlib.sha1(certificate).hexdigest().upper() for certificate in profile["DeveloperCertificates"]}
        candidates = fingerprints & available
        if expected:
            candidates &= {expected}
        if not candidates:
            raise ValueError(f"Profile for {bundle} does not authorize an installed signing identity")
        profiles.append((variable, profile, content, candidates))

    common = profiles[0][3] & profiles[1][3]
    if len(common) != 1:
        raise ValueError("Both profiles must select the same single signing identity")
    certificate = common.pop()
    exports = {"DEVELOPER_ID_CERTIFICATE_SHA1": certificate}
    for variable, profile, content, _ in profiles:
        uuid = str(profile["UUID"])
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", uuid):
            raise ValueError("Invalid profile UUID")
        for directory in destinations:
            directory.mkdir(parents=True, exist_ok=True)
            (directory / f"{uuid}.provisionprofile").write_bytes(content)
        exports[variable] = uuid
        print(f"Installed {profile['Name']} ({uuid}), authorizing {certificate}")
    with open(os.environ["GITHUB_ENV"], "a") as environment:
        for key, value in exports.items():
            environment.write(f"{key}={value}\n")


if __name__ == "__main__":
    install_profiles()
