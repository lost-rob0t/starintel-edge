#!/usr/bin/env python3
"""Compile/run bounded HOST transport tests with an ABI stub, NEVER ECL/ART.

Run in a repository: python3 tests/android/test_owned_process.py --build-dir build/owned-host
Source-preparation mode also accepts --abi-include for verified baseline headers.
No downloads, SDK, Gradle, ECL, installs, emulator, or device are used.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--abi-include', type=Path, default=ROOT / 'platforms/android/native')
parser.add_argument('--build-dir', type=Path, default=ROOT / 'build/owned-host')
ARGS = parser.parse_args()
BUILD = ARGS.build_dir.resolve()
LIBS = BUILD / 'lib'
RUNTIME = BUILD / 'runtime'
RUNNER = LIBS / 'libstarintel_ecl_runner.so'
HELLO = b'{"transport":"starintel-owned/1","abi":1}'
ENV = dict(os.environ, LD_LIBRARY_PATH=str(LIBS))
ENV.pop('LD_PRELOAD', None)
ENV.pop('LD_AUDIT', None)

def command(argv):
    print('+', ' '.join(map(str, argv)), flush=True)
    subprocess.run(list(map(str, argv)), check=True, timeout=40)

# The minimal installed JDK lacks ct.sym/--release 17; source/target 17 uses
# the installed JDK API, not Android API stubs. This does not prove ART linkage.
def build():
    LIBS.mkdir(parents=True, exist_ok=True)
    RUNTIME.mkdir(exist_ok=True)
    (BUILD / 'classes').mkdir(exist_ok=True)
    include = ['-I', ARGS.abi_include.resolve()]
    common = ['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-pthread']
    command(common + include + ['-fPIC', '-shared', ROOT / 'tests/android/owned_process/transport_stub.c',
            '-Wl,-soname,libstarintel_ecl_adapter.so', '-o', LIBS / 'libstarintel_ecl_adapter.so'])
    command(common + include + ['-fPIE', '-pie', ROOT / 'platforms/android/native/starintel_ecl_runner.c',
            '-L', LIBS, '-lstarintel_ecl_adapter', '-Wl,-z,defs', '-o', RUNNER])
    command(['java', 'com.sun.tools.javac.Main', '-source', '17', '-target', '17', '-Xlint:all,-options', '-Werror', '-d', BUILD / 'classes',
            ROOT / 'platforms/android/edge-service/src/main/java/actor/starintel/edge/service/OwnedEclProcess.java',
            ROOT / 'tests/android/owned_process/OwnedProcessTest.java'])

def exact(stream, length, timeout=3):
    data = bytearray()
    end = time.monotonic() + timeout
    while len(data) < length:
        left = end - time.monotonic()
        if left <= 0 or not select.select([stream], [], [], left)[0]:
            raise AssertionError('host test timed out reading frame')
        chunk = os.read(stream.fileno(), length - len(data))
        if not chunk:
            raise AssertionError('unexpected EOF in test frame')
        data.extend(chunk)
    return bytes(data)

def frame(body):
    return struct.pack('>I', len(body)) + body

def read_frame(stream):
    length, = struct.unpack('>I', exact(stream, 4))
    assert length <= 4 * 1024 * 1024, length
    return exact(stream, length) if length else b''

class Transport(unittest.TestCase):
    def launch(self, hello=True, **environment):
        self.log = BUILD / (self._testMethodName + '.log')
        self.log.write_text('')
        env = dict(ENV, STUB_LOG=str(self.log), **environment)
        child = subprocess.Popen([str(RUNNER), str(RUNTIME)], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.addCleanup(self.cleanup, child)
        if hello:
            self.assertEqual(read_frame(child.stdout), HELLO)
        return child

    @staticmethod
    def cleanup(child):
        if child.poll() is None:
            child.kill()  # Only the exact test-owned subprocess; not an ART claim.
        child.wait(timeout=3)
        for stream in (child.stdin, child.stdout, child.stderr):
            stream.close()

    def test_handshake_echo_stop_owner_and_descriptors(self):
        child = self.launch()
        child.stdin.write(frame('é😀'.encode())); child.stdin.flush()
        self.assertEqual(read_frame(child.stdout), 'é😀'.encode())
        out, err = child.communicate(frame(b''), timeout=3)
        self.assertEqual((out, err, child.returncode), (frame(b''), b'', 0))
        log = self.log.read_text()
        for event in ('private-pipes-stdio-isolated', 'request', 'stop', 'own-write-sigpipe-preserved-stub-only'):
            self.assertIn(event, log)

    def test_clean_eof_stops(self):
        child = self.launch()
        out, err = child.communicate(timeout=3)
        self.assertEqual((out, err, child.returncode), (b'', b'', 0))
        self.assertIn('stop ', self.log.read_text())

    def test_truncated_header_and_body(self):
        for wire in (b'\x00', b'\x00\x00\x00', struct.pack('>I', 5), frame(b'five!')[:-1]):
            with self.subTest(wire=wire):
                child = self.launch()
                out, err = child.communicate(wire, timeout=3)
                self.assertEqual((out, err, child.returncode), (b'', b'', 65))
                self.assertNotIn('request ', self.log.read_text())

    def test_oversize_request_headers(self):
        for length in (1024 * 1024 + 1, 0x80000000, 0xffffffff):
            child = self.launch()
            out, err = child.communicate(struct.pack('>I', length), timeout=3)
            self.assertEqual((out, err, child.returncode), (b'', b'', 65))
            self.assertNotIn('request ', self.log.read_text())

    def test_invalid_utf8_and_literal_nul(self):
        for body in (b'x\0tail', b'\xc0\x80', b'\xed\xa0\x80', b'\xf4\x90\x80\x80', b'\xff', b'\xe2\x82'):
            child = self.launch()
            out, err = child.communicate(frame(body), timeout=3)
            self.assertEqual((out, err, child.returncode), (b'', b'', 65))
            self.assertNotIn('request ', self.log.read_text())

    def test_max_request_and_response(self):
        child = self.launch()
        body = b'x' * (1024 * 1024)
        out, err = child.communicate(frame(body) + frame(b'large') + frame(b''), timeout=5)
        expected = frame(body) + frame(b'x' * (4 * 1024 * 1024)) + frame(b'')
        self.assertEqual((out, err, child.returncode), (expected, b'', 0))

    def test_invalid_stub_response_rejected(self):
        for body in (b'oversize', b'bad-utf8', b'empty', b'null'):
            child = self.launch()
            out, err = child.communicate(frame(body), timeout=3)
            self.assertEqual((out, err, child.returncode), (b'', b'', 70))
            self.assertIn('stop ', self.log.read_text())

    def test_abi_mismatch_before_boot(self):
        child = self.launch(hello=False, STUB_WRONG_ABI='1')
        child.wait(timeout=3)  # Keep the parent writer alive through preboot.
        out, err = child.communicate(timeout=3)
        self.assertEqual((out, err, child.returncode), (b'', b'', 70))
        self.assertIn('abi ', self.log.read_text())
        self.assertNotIn('start ', self.log.read_text())

    def test_start_error_not_exposed(self):
        child = self.launch(hello=False, STUB_FAIL_START='1')
        child.wait(timeout=3)  # Do not accidentally test preboot HUP instead.
        out, err = child.communicate(timeout=3)
        self.assertEqual((out, err, child.returncode), (b'', b'', 70))
        self.assertIn('free ', self.log.read_text())

    def test_broken_output_does_not_run_sigpipe_handler(self):
        child = self.launch()
        child.stdout.close()
        child.stdin.write(frame(b'{}')); child.stdin.flush(); child.stdin.close()
        self.assertEqual(child.wait(timeout=3), 70)
        self.assertEqual(child.stderr.read(), b'')
        self.assertIn('own-write-sigpipe-preserved-stub-only', self.log.read_text())

    def test_preboot_input_hup(self):
        for buffered in (b'', frame(b'{}')):
            log = BUILD / 'preboot-hup.log'; log.write_text('')
            read, write = os.pipe()
            os.write(write, buffered); os.close(write)
            try:
                result = subprocess.run([str(RUNNER), str(RUNTIME)], stdin=read, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=dict(ENV, STUB_LOG=str(log)), timeout=3)
            finally:
                os.close(read)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (70, b'', b''))
            self.assertEqual(log.read_text(), '')

    def test_preboot_output_hup(self):
        log = BUILD / 'preboot-output-hup.log'; log.write_text('')
        read, write = os.pipe(); os.close(read)
        child = subprocess.Popen([str(RUNNER), str(RUNTIME)], stdin=subprocess.PIPE, stdout=write,
                                 stderr=subprocess.PIPE, env=dict(ENV, STUB_LOG=str(log)))
        os.close(write)
        try:
            self.assertEqual(child.wait(timeout=3), 70)
            self.assertEqual(child.stderr.read(), b'')
            self.assertEqual(log.read_text(), '')
        finally:
            if child.poll() is None: child.kill()
            child.wait(timeout=3); child.stdin.close(); child.stderr.close()

    def test_parent_death_kills_owned_child(self):
        # Process-local Linux test adoption lets us reap the exact owned grandchild.
        libc = ctypes.CDLL(None, use_errno=True)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)  # PR_SET_CHILD_SUBREAPER
        script = '''import os,subprocess,sys,struct
p=subprocess.Popen(sys.argv[1:],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
n=struct.unpack('>I',p.stdout.read(4))[0]
assert p.stdout.read(n)==b'{"transport":"starintel-owned/1","abi":1}'
print(p.pid,flush=True)
os._exit(0)
'''
        pid = None
        try:
            result = subprocess.run([sys.executable, '-c', script, str(RUNNER), str(RUNTIME)],
                                    env=ENV, capture_output=True, check=True, timeout=4)
            pid = int(result.stdout)
            end = time.monotonic() + 3
            while time.monotonic() < end:
                exited, status = os.waitpid(pid, os.WNOHANG)
                if exited:
                    self.assertTrue(os.WIFSIGNALED(status))
                    self.assertEqual(os.WTERMSIG(status), signal.SIGKILL)
                    pid = None
                    break
                time.sleep(.01)
            self.assertIsNone(pid, 'owned child did not exit after creator parent died')
        finally:
            if pid is not None:
                os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
            self.assertEqual(libc.prctl(36, 0, 0, 0, 0), 0)

if __name__ == '__main__':
    build()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Transport))
    if not result.wasSuccessful(): sys.exit(1)
    command(['java', '-cp', BUILD / 'classes', 'actor.starintel.edge.service.OwnedProcessTest', LIBS, RUNTIME])
    print('PASS host-only transport/framing/ownership tests. ECL, ART, JNI coexistence and device gates NOT RUN.')
