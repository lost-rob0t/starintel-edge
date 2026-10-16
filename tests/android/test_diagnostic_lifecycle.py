"""Exercise the actual diagnostic Activity with host Android/backend stubs, NOT ART."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DiagnosticLifecycle(unittest.TestCase):
    def test_recreation_runs_one_phase_and_preserves_fresh_data_assertion(self):
        sources = {
            'android/os/Process.java': 'package android.os; public class Process { public static int myPid() { return 1; } }',
            'android/content/pm/ApplicationInfo.java': 'package android.content.pm; public class ApplicationInfo { public String nativeLibraryDir; }',
            'android/os/Bundle.java': 'package android.os; public class Bundle {}',
            'android/content/Intent.java': 'package android.content; public class Intent { public String getStringExtra(String key) { return System.getProperty("phase", "first"); } }',
            'android/app/Activity.java': '''package android.app;
                public class Activity {
                    public void onCreate(android.os.Bundle state) {}
                    public void setContentView(Object view) {}
                    public android.content.pm.ApplicationInfo getApplicationInfo() { return new android.content.pm.ApplicationInfo(); }
                    public android.content.Intent getIntent() { return new android.content.Intent(); }
                    public java.io.File getNoBackupFilesDir() { return new java.io.File(System.getProperty("fixture")); }
                    public void runOnUiThread(Runnable run) { run.run(); }
                }''',
            'android/widget/TextView.java': 'package android.widget; public class TextView { public TextView(Object context) {} public void setText(String text) {} }',
            'android/util/Log.java': '''package android.util; public class Log {
                public static final java.util.List<String> messages = new java.util.concurrent.CopyOnWriteArrayList<>();
                public static int i(String tag, String text) { messages.add(text); return 0; }
                public static int e(String tag, String text, Throwable error) { messages.add(text + ": " + error.getMessage()); return 0; }
            }''',
            'actor/starintel/edge/service/AndroidEclBackend.java': '''package actor.starintel.edge.service;
                public class AndroidEclBackend implements LocalRuntimeBackend {
                    static final java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1);
                    static final java.util.concurrent.CountDownLatch release = new java.util.concurrent.CountDownLatch(1);
                    static int opens;
                    public AndroidEclBackend(Object context) {}
                    public Session open(Config config, Cancellation cancellation) throws Exception {
                        opens++; entered.countDown(); release.await(); return () -> {};
                    }
                }''',
            'actor/starintel/edge/service/DiagnosticTest.java': '''package actor.starintel.edge.service;
                public class DiagnosticTest {
                    public static void main(String[] args) throws Exception {
                        boolean stale = args.length > 0;
                        if (stale) new java.io.File(System.getProperty("fixture"), "runtime").mkdirs();
                        new RuntimeDiagnosticActivity().onCreate(null);
                        if (!stale) {
                            if (!AndroidEclBackend.entered.await(2, java.util.concurrent.TimeUnit.SECONDS)) throw new AssertionError("No first startup");
                            new RuntimeDiagnosticActivity().onCreate(new android.os.Bundle());
                            long observed = System.nanoTime() + 2_000_000_000L;
                            while (System.nanoTime() < observed && android.util.Log.messages.stream().noneMatch(s -> s.startsWith("RECREATED ") || s.startsWith("FAIL "))) Thread.sleep(10);
                            if (android.util.Log.messages.stream().noneMatch(s -> s.startsWith("RECREATED "))) throw new AssertionError("Recreation was not coalesced: " + android.util.Log.messages);
                            AndroidEclBackend.release.countDown();
                        }
                        long end = System.nanoTime() + 2_000_000_000L;
                        while (System.nanoTime() < end && android.util.Log.messages.stream().noneMatch(s -> s.startsWith(stale ? "FAIL " : "HOLD "))) Thread.sleep(10);
                        String logs = android.util.Log.messages.toString();
                        if (stale) {
                            if (!logs.contains("Fresh APK data required") || AndroidEclBackend.opens != 0) throw new AssertionError(logs);
                        } else {
                            if (logs.contains("FAIL ") || !logs.contains("HOLD ") || AndroidEclBackend.opens != 3) throw new AssertionError(logs);
                            if (android.util.Log.messages.stream().filter(s -> s.startsWith("STOPPED ")).count() != 2) throw new AssertionError(logs);
                        }
                    }
                }''',
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = []
            for name, body in sources.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(body)
                paths.append(str(path))
            src = ROOT / 'platforms/android/edge-service/src/main/java/actor/starintel/edge/service'
            subprocess.run(['java', 'com.sun.tools.javac.Main', '-encoding', 'UTF-8', '-d', str(root), *paths,
                            str(src / 'LocalRuntimeBackend.java'), str(src / 'OwnedEclProcess.java'),
                            str(ROOT / 'tests/android/diagnostic/RuntimeDiagnosticActivity.java')], check=True, timeout=30)
            for case in ('recreate', 'stale'):
                fixture = root / case
                fixture.mkdir()
                subprocess.run(['java', '-cp', str(root), '-Dfixture=' + str(fixture),
                                'actor.starintel.edge.service.DiagnosticTest', *(['stale'] if case == 'stale' else [])], check=True, timeout=5)

