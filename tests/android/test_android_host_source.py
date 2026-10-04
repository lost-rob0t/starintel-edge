"""Manifest/source invariants only: no Android build or device assertion."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / "platforms/android"
NS = "{http://schemas.android.com/apk/res/android}"
JAVA = ANDROID / "edge-service/src/main/java/actor/starintel/edge/service"

class AndroidSourceContract(unittest.TestCase):
    def test_manifest_is_private_visible_and_opt_in(self):
        tree = ET.parse(ANDROID / "edge-service/src/main/AndroidManifest.xml").getroot()
        permissions = {x.attrib[NS + "name"] for x in tree.findall("uses-permission")}
        self.assertEqual(permissions, {"android.permission." + p for p in (
            "INTERNET", "FOREGROUND_SERVICE", "FOREGROUND_SERVICE_SPECIAL_USE", "POST_NOTIFICATIONS")})
        service = tree.find("application/service")
        self.assertEqual(service.attrib[NS + "exported"], "false")
        self.assertEqual(service.attrib[NS + "process"], ":starintel_runtime")
        self.assertEqual(service.attrib[NS + "foregroundServiceType"], "specialUse")
        self.assertEqual(service.find("property").attrib[NS + "name"], "android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE")
        self.assertEqual(tree.findall(".//receiver"), [])
    def test_no_silent_restart_or_runtime_substitution(self):
        source = (JAVA / "EdgeRuntimeService.java").read_text()
        self.assertIn("return START_NOT_STICKY;", source)
        self.assertNotIn("return START_STICKY;", source)
        self.assertIn("return new AndroidEclBackend(getApplicationContext());", source)
        self.assertIn("FLAG_IMMUTABLE", source)
        self.assertNotIn("Runtime.getRuntime().exec", source)
        self.assertNotIn("System.loadLibrary", source)
        self.assertIn("snapshot != controller.snapshot()", source)
    def test_process_owns_native_thread_and_timeout_target(self):
        owner = (JAVA / "RuntimeOwner.java").read_text()
        service = (JAVA / "EdgeRuntimeService.java").read_text()
        self.assertIn("static RuntimeOwner instance", owner)
        self.assertIn("Process.killProcess(Process.myPid())", owner)
        self.assertIn("!isOwnedRuntimeProcess()", owner)
        self.assertIn('application.getPackageName() + ":starintel_runtime"', owner)
        self.assertNotIn("controller.close()", service)
        self.assertIn("owner.detachAndStop(stateListener)", service)
        self.assertNotIn("RuntimeStatus.destroyed()", service)
    def test_kotlin_registration_and_rejected_foreground_launch(self):
        gradle = (ANDROID / "edge-service/build.gradle.kts").read_text()
        self.assertIn('kotlin.directories += "../kotlin"', gradle)
        self.assertIn('extensions.configure<com.android.build.api.dsl.LibraryExtension>', gradle)
        self.assertNotIn('android.sourceSets.named', gradle)
        self.assertNotIn('java.srcDir("../kotlin")', gradle)
        service = (JAVA / "EdgeRuntimeService.java").read_text()
        reject = service.split("private void rejectForegroundStart", 1)[1].split("private boolean notificationsVisible", 1)[0]
        self.assertIn("stopSelfResult(startId)", reject)
        self.assertNotIn("finishIfIdle", reject)
        self.assertEqual(service.count("rejectForegroundStart(startId);"), 2)
    def test_native_boot_is_one_shot(self):
        native = (ANDROID / "native/starintel_ecl_adapter.c").read_text()
        self.assertIn("if (starintel_ecl_booted_once)", native)
        self.assertIn('"process-restart-required"', native)
        self.assertEqual(native.count("starintel_ecl_booted_once = 0"), 1)
        owner = (JAVA / "RuntimeOwner.java").read_text()
        self.assertIn("controller.requiresFreshProcess()", owner)
        self.assertIn("RuntimeStatus.persistBeforeExit", owner)
    def test_packaged_native_modules_strip_build_host_rpath(self):
        flake = (ROOT / "flake.nix").read_text()
        self.assertIn('pkgs.jq pkgs.patchelf', flake)
        self.assertIn('patchelf --remove-rpath "$module"', flake)
        self.assertIn("-name '*.so' -o -name '*.fas'", flake)
        self.assertLess(flake.index('patchelf --remove-rpath "$module"'),
                        flake.index('ecl_hash=$(sha256sum'))
    def test_no_backup_or_cleartext_client_default(self):
        app = ET.parse(ANDROID / "diagnostic/src/main/AndroidManifest.xml").find("application")
        self.assertEqual(app.attrib[NS + "allowBackup"], "false")
        self.assertEqual(app.attrib[NS + "fullBackupContent"], "false")
        self.assertEqual(app.attrib[NS + "usesCleartextTraffic"], "false")
    def test_template_keeps_lisp_and_loopback(self):
        source = (JAVA / "EdgeRuntimeService.java").read_text()
        template = (ANDROID / "edge-service/src/main/assets/starintel-edge-host/init.lisp").read_text()
        self.assertIn('(in-package :cl-user)', template)
        config = (JAVA / "LocalRuntimeBackend.java").read_text()
        self.assertIn('listenAddress = "127.0.0.1"', config)
        self.assertIn('getNoBackupFilesDir()', source)
        self.assertNotIn('getExternal', source)
    def test_ui_is_honest(self):
        source = (ANDROID / "diagnostic/src/main/java/actor/starintel/edge/diagnostic/MainActivity.java").read_text()
        self.assertIn('Full star-server HTTP/CouchDB/RabbitMQ is not included.', source)
        self.assertIn('tap Start again', source)
        self.assertIn('runtime.send(request)', source)
        self.assertNotIn('onRequestPermissionsResult', source) # Grant never implicitly starts the runtime.

if __name__ == '__main__': unittest.main()
