#!/usr/bin/env python3
"""Interactive and headless installer for StarIntel Edge distribution profiles."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any


DISTRO_FORMAT = "STARINTEL-DISTRO-PLAN/1"
ACTOR_LOCK_FORMAT = "STARINTEL-ACTOR-LOCK/1"
ACTOR_PACKAGE_FORMAT = "STARINTEL-ACTOR-PACKAGE/1"
ACTOR_SYSTEMS = frozenset({"sento", "pykka", "starlang"})
PLATFORMS = frozenset({"debian", "nixos", "termux"})
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,127}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
TAG_RE = re.compile(r"^[A-Za-z0-9_.+-]+$")
ASSET_RE = re.compile(r"^[A-Za-z0-9_.+-]+\.tar\.(?:gz|xz)$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MAX_ARCHIVE_MEMBERS = 10_000
MAX_UNPACKED_BYTES = 1 << 30


class InstallerError(RuntimeError):
    """An operator-actionable installer error."""


def share_dir() -> Path:
    override = os.environ.get("STARINTEL_DISTRO_SHARE")
    return Path(override) if override else Path(__file__).resolve().parent


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise InstallerError(f"cannot read JSON from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise InstallerError(f"{path} must contain a JSON object")
    return value


def load_profiles() -> dict[str, Any]:
    catalog = load_json(share_dir() / "profiles.json")
    if catalog.get("format") != "STARINTEL-DISTRO-PROFILES/1":
        raise InstallerError("unsupported distro profile catalog")
    return catalog


def load_spec_lock() -> dict[str, Any]:
    candidates = [
        share_dir().parent / "schema" / "starintel-schema.lock.json",
        share_dir() / "schema" / "starintel-schema.lock.json",
    ]
    for candidate in candidates:
        if candidate.is_file():
            lock = load_json(candidate)
            required = {
                "release_version",
                "schema_version",
                "canonical_repository",
                "canonical_commit",
            }
            if not required.issubset(lock):
                raise InstallerError(f"incomplete StarIntel schema lock: {candidate}")
            return lock
    raise InstallerError("StarIntel schema lock is missing from the installation")


def require_string(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value:
        raise InstallerError(f"{label} must be a non-empty string")
    if pattern is not None and pattern.fullmatch(value) is None:
        raise InstallerError(f"{label} has an invalid value")
    return value


def validate_compatibility(value: Any, spec: dict[str, Any], label: str) -> dict[str, str]:
    if not isinstance(value, dict) or set(value) != {"releaseVersion", "schemaVersion"}:
        raise InstallerError(f"{label}.starintel must contain releaseVersion and schemaVersion")
    release = require_string(value.get("releaseVersion"), f"{label}.starintel.releaseVersion")
    schema = require_string(value.get("schemaVersion"), f"{label}.starintel.schemaVersion")
    if release != spec["release_version"] or schema != spec["schema_version"]:
        raise InstallerError(
            f"{label} targets StarIntel {release}/{schema}, expected "
            f"{spec['release_version']}/{spec['schema_version']}"
        )
    return {"releaseVersion": release, "schemaVersion": schema}


def validate_actor_entry(value: Any, spec: dict[str, Any], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InstallerError(f"{label} must be an object")
    expected = {"name", "version", "actorSystem", "entrypoint", "starintel", "github"}
    if set(value) != expected:
        raise InstallerError(f"{label} must contain exactly {sorted(expected)}")
    name = require_string(value.get("name"), f"{label}.name", NAME_RE)
    version = require_string(value.get("version"), f"{label}.version", VERSION_RE)
    actor_system = require_string(value.get("actorSystem"), f"{label}.actorSystem")
    if actor_system not in ACTOR_SYSTEMS:
        raise InstallerError(f"{label}.actorSystem must be one of {sorted(ACTOR_SYSTEMS)}")
    entrypoint = require_string(value.get("entrypoint"), f"{label}.entrypoint")
    if len(entrypoint) > 512:
        raise InstallerError(f"{label}.entrypoint is too long")
    starintel = validate_compatibility(value.get("starintel"), spec, label)
    github = value.get("github")
    if not isinstance(github, dict):
        raise InstallerError(f"{label}.github must be an object")
    expected_github = {"repository", "tag", "asset", "sha256"}
    if set(github) != expected_github:
        raise InstallerError(f"{label}.github must contain exactly {sorted(expected_github)}")
    normalized_github = {
        "repository": require_string(github.get("repository"), f"{label}.github.repository", REPOSITORY_RE),
        "tag": require_string(github.get("tag"), f"{label}.github.tag", TAG_RE),
        "asset": require_string(github.get("asset"), f"{label}.github.asset", ASSET_RE),
        "sha256": require_string(github.get("sha256"), f"{label}.github.sha256", SHA256_RE),
    }
    return {
        "name": name,
        "version": version,
        "actorSystem": actor_system,
        "entrypoint": entrypoint,
        "starintel": starintel,
        "github": normalized_github,
    }


def load_actor_lock(path: Path, spec: dict[str, Any]) -> list[dict[str, Any]]:
    lock = load_json(path)
    if set(lock) != {"format", "packages"} or lock.get("format") != ACTOR_LOCK_FORMAT:
        raise InstallerError(f"{path} is not a {ACTOR_LOCK_FORMAT} document")
    packages = lock.get("packages")
    if not isinstance(packages, list) or not packages:
        raise InstallerError("actor lock packages must be a non-empty array")
    result = [validate_actor_entry(entry, spec, f"packages[{index}]") for index, entry in enumerate(packages)]
    identities = [(entry["name"], entry["version"]) for entry in result]
    if len(identities) != len(set(identities)):
        raise InstallerError("actor lock contains duplicate name/version entries")
    return result


def select_actor_packages(
    packages: list[dict[str, Any]], actor_systems: list[str] | None
) -> list[dict[str, Any]]:
    if not actor_systems:
        return packages
    selected = [package for package in packages if package["actorSystem"] in actor_systems]
    if not selected:
        raise InstallerError("the actor-system selection matched no locked packages")
    return selected


def build_plan(
    profile_name: str,
    heavy: list[str],
    actor_packages: list[dict[str, Any]],
    catalog: dict[str, Any],
    spec: dict[str, Any],
    platform: str = "nixos",
) -> dict[str, Any]:
    profiles = catalog["profiles"]
    if profile_name not in profiles:
        raise InstallerError(f"unknown profile: {profile_name}")
    profile = profiles[profile_name]
    valid_heavy = set(catalog["heavyOptions"])
    unknown_heavy = set(heavy) - valid_heavy
    if unknown_heavy:
        raise InstallerError(f"unknown heavy options: {', '.join(sorted(unknown_heavy))}")
    if profile_name != "full" and heavy:
        raise InstallerError("heavy options are only valid with the full profile")
    if profile["requiresActorPackages"] and not actor_packages:
        raise InstallerError("the actors profile requires --actor-lock")
    distribution = catalog.get("distribution")
    if not isinstance(distribution, dict) or platform not in distribution.get(
        "supportedPlatforms", []
    ):
        raise InstallerError(f"unsupported distribution platform: {platform}")
    return {
        "format": DISTRO_FORMAT,
        "distribution": distribution["name"],
        "platform": platform,
        "defaultShell": distribution["defaultShell"],
        "profile": profile_name,
        "components": profile["components"],
        "transport": profile["transport"],
        "storage": profile["storage"],
        "heavy": sorted(set(heavy)),
        "actors": actor_packages,
        "actorServices": [
            {
                "name": package["name"],
                "actorSystem": package["actorSystem"],
                "entrypoint": package["entrypoint"],
            }
            for package in actor_packages
        ],
        "systemApis": catalog["systemApis"],
        "starintel": {
            "releaseVersion": spec["release_version"],
            "schemaVersion": spec["schema_version"],
            "canonicalRepository": spec["canonical_repository"],
            "canonicalCommit": spec["canonical_commit"],
        },
    }


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def github_release_url(package: dict[str, Any]) -> str:
    github = package["github"]
    repository = github["repository"]
    tag = urllib.parse.quote(github["tag"], safe="._+-")
    asset = urllib.parse.quote(github["asset"], safe="._+-")
    return f"https://github.com/{repository}/releases/download/{tag}/{asset}"


def download_asset(package: dict[str, Any], destination: Path) -> None:
    request = urllib.request.Request(
        github_release_url(package),
        headers={"User-Agent": "starintel-edge-installer/1"},
    )
    digest = hashlib.sha256()
    try:
        with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as output:
            while block := response.read(1024 * 1024):
                digest.update(block)
                output.write(block)
    except OSError as exc:
        raise InstallerError(f"failed to download {package['name']}: {exc}") from exc
    actual = digest.hexdigest()
    expected = package["github"]["sha256"]
    if actual != expected:
        destination.unlink(missing_ok=True)
        raise InstallerError(f"SHA-256 mismatch for {package['name']}: expected {expected}, got {actual}")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def validate_archive_members(archive: tarfile.TarFile) -> list[tarfile.TarInfo]:
    members = archive.getmembers()
    if len(members) > MAX_ARCHIVE_MEMBERS:
        raise InstallerError("actor package has too many archive members")
    total_size = 0
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise InstallerError(f"unsafe actor package path: {member.name}")
        if member.issym() or member.islnk() or member.isdev():
            raise InstallerError(f"actor package links/devices are forbidden: {member.name}")
        total_size += member.size
        if total_size > MAX_UNPACKED_BYTES:
            raise InstallerError("actor package exceeds the 1 GiB unpacked limit")
    return members


def validate_embedded_manifest(path: Path, package: dict[str, Any]) -> None:
    manifest = load_json(path)
    required = {"format", "name", "version", "actorSystem", "entrypoint", "starintel"}
    allowed = required | {"capabilities"}
    if not required.issubset(manifest) or set(manifest) - allowed:
        raise InstallerError(f"{path} has unsupported actor manifest fields")
    if manifest.get("format") != ACTOR_PACKAGE_FORMAT:
        raise InstallerError(f"{path} is not a {ACTOR_PACKAGE_FORMAT} manifest")
    for key in ("name", "version", "actorSystem", "entrypoint", "starintel"):
        if manifest.get(key) != package[key]:
            raise InstallerError(f"embedded actor manifest {key} does not match the lock")
    capabilities = manifest.get("capabilities", [])
    if (
        not isinstance(capabilities, list)
        or any(not isinstance(item, str) or not item for item in capabilities)
        or len(capabilities) != len(set(capabilities))
    ):
        raise InstallerError("embedded actor manifest capabilities must be unique strings")


def install_actor_archive(archive_path: Path, actor_root: Path, package: dict[str, Any]) -> Path:
    target = actor_root / package["name"] / package["version"]
    if target.exists():
        validate_embedded_manifest(target / "actor-package.json", package)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = Path(tempfile.mkdtemp(prefix=f".{package['version']}.", dir=target.parent))
        try:
            with tarfile.open(archive_path, mode="r:*") as archive:
                members = validate_archive_members(archive)
                archive.extractall(temporary, members=members, filter="data")
            validate_embedded_manifest(temporary / "actor-package.json", package)
            os.replace(temporary, target)
        except (OSError, tarfile.TarError) as exc:
            raise InstallerError(f"cannot install actor package {package['name']}: {exc}") from exc
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    current = target.parent / "current"
    temporary_link = target.parent / ".current.tmp"
    temporary_link.unlink(missing_ok=True)
    temporary_link.symlink_to(target.name)
    os.replace(temporary_link, current)
    return target


def fetch_actor_packages(root: Path, packages: list[dict[str, Any]]) -> None:
    actor_root = root / "var" / "lib" / "starintel" / "actors"
    cache = root / "var" / "cache" / "starintel" / "actors"
    cache.mkdir(parents=True, exist_ok=True)
    for package in packages:
        asset = cache / f"{package['name']}-{package['version']}-{package['github']['asset']}"
        if not asset.exists() or file_sha256(asset) != package["github"]["sha256"]:
            asset.unlink(missing_ok=True)
            download_asset(package, asset)
        install_actor_archive(asset, actor_root, package)


def resolve_profile(profile: str | None, non_interactive: bool, catalog: dict[str, Any]) -> str:
    if profile:
        return profile
    if non_interactive or not sys.stdin.isatty():
        raise InstallerError("--profile is required for headless installation")
    names = list(catalog["profiles"])
    for index, name in enumerate(names, 1):
        entry = catalog["profiles"][name]
        print(f"{index}. {entry['title']} — {entry['description']}")
    selection = input("Select a StarIntel distribution profile: ").strip()
    try:
        return names[int(selection) - 1]
    except (ValueError, IndexError) as exc:
        raise InstallerError("invalid profile selection") from exc


def add_plan_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--profile", choices=("edge", "actors", "full"))
    parser.add_argument("--platform", choices=sorted(PLATFORMS), default="nixos")
    parser.add_argument("--actor-lock", type=Path)
    parser.add_argument("--actor-system", action="append", choices=sorted(ACTOR_SYSTEMS))
    parser.add_argument("--heavy", action="append", default=[])
    parser.add_argument("--non-interactive", action="store_true")


def plan_from_args(args: argparse.Namespace) -> dict[str, Any]:
    catalog = load_profiles()
    spec = load_spec_lock()
    profile = resolve_profile(args.profile, args.non_interactive, catalog)
    packages = load_actor_lock(args.actor_lock, spec) if args.actor_lock else []
    packages = select_actor_packages(packages, args.actor_system)
    return build_plan(profile, args.heavy, packages, catalog, spec, args.platform)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="starintel-install")
    subparsers = parser.add_subparsers(dest="command", required=True)
    profiles = subparsers.add_parser("profiles", help="list available profiles")
    profiles.add_argument("--json", action="store_true")
    plan = subparsers.add_parser("plan", help="render a deterministic installation plan")
    add_plan_arguments(plan)
    plan.add_argument("--output", type=Path)
    install = subparsers.add_parser("install", help="write a plan and optionally fetch actor packages")
    add_plan_arguments(install)
    install.add_argument("--root", type=Path, default=Path("/"))
    install.add_argument("--fetch-actors", action="store_true")
    install.add_argument("--yes", action="store_true", help="confirm writes without a prompt")
    validate = subparsers.add_parser("validate-actor-lock", help="validate a package lock")
    validate.add_argument("path", type=Path)
    return parser.parse_args(argv)


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.command == "profiles":
        catalog = load_profiles()
        if args.json:
            print(json.dumps(catalog, indent=2, sort_keys=True))
        else:
            for name, profile in catalog["profiles"].items():
                print(f"{name:7} {profile['title']}: {profile['description']}")
        return 0
    if args.command == "validate-actor-lock":
        packages = load_actor_lock(args.path, load_spec_lock())
        print(f"valid {ACTOR_LOCK_FORMAT}: {len(packages)} package(s)")
        return 0
    plan = plan_from_args(args)
    if args.command == "plan":
        if args.output:
            atomic_write_json(args.output, plan)
        else:
            print(json.dumps(plan, indent=2, sort_keys=True))
        return 0
    root = args.root.resolve()
    if root == Path("/") and not args.yes:
        if args.non_interactive or not sys.stdin.isatty():
            raise InstallerError("--yes is required for a headless system installation")
        if input("Install StarIntel configuration under /? [y/N] ").strip().lower() != "y":
            raise InstallerError("installation cancelled")
    config_path = root / "etc" / "starintel" / "distro.json"
    if args.fetch_actors:
        if not plan["actors"]:
            raise InstallerError("--fetch-actors requires --actor-lock")
        fetch_actor_packages(root, plan["actors"])
    atomic_write_json(config_path, plan)
    print(config_path)
    return 0


def main() -> None:
    try:
        raise SystemExit(run(sys.argv[1:]))
    except InstallerError as exc:
        print(f"starintel-install: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
