#!/usr/bin/env python3
"""Run the host adapter against copied exact packaged Lisp assets, never target .fas.
Requires an already-built native_packaged_bootstrap_test and available host ECL.
Run inside the host ECL environment. This script downloads/installs nothing.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_hashes(path):
    return {str(file.relative_to(path)): digest(file)
            for file in sorted(path.rglob("*")) if file.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("assets", type=Path, help="Bundle's assets/starintel-edge directory")
    parser.add_argument("binary", type=Path, help="Real host-ECL native_packaged_bootstrap_test")
    parser.add_argument("--output", type=Path, default=Path("build/android-host-tests"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="packaged-source-", dir=args.output)).resolve()
    shutil.copytree(args.assets / "lisp", root / "lisp")
    init = root / "init.lisp"
    # Write the original template plus synthetic trusted Lisp into a new private
    # file. Do not alter the source bundle or any startup/runtime/vendor bytes.
    init.write_text((args.assets / "init.lisp").read_text() + '''
;; Synthetic private test state only. No networking, peers or secrets.
(let ((root (uiop:pathname-directory-pathname *load-truename*)))
  (with-open-file (out (merge-pathnames "init-loaded.txt" root)
                       :direction :output :if-exists :supersede)
    (write-string "trusted-init-ran" out))
  (setf star.edge.android:*service-components*
        (list (star.edge.runtime:make-component "synthetic-packaged-proof"
          :start (lambda ()
                   (with-open-file (out (merge-pathnames "component-started.txt" root)
                                        :direction :output :if-exists :supersede)
                     (write-string "started" out)))
          :stop (lambda ()
                  (with-open-file (out (merge-pathnames "component-stopped.txt" root)
                                       :direction :output :if-exists :supersede)
                    (write-string "stopped" out)))))))
''')
    expected = tree_hashes(args.assets / "lisp")
    assert tree_hashes(root / "lisp") == expected
    before_init = digest(init)
    run = subprocess.run([str(args.binary.resolve()), str(root)], text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (root / "host-test.log").write_text(run.stdout)
    assets_unchanged = tree_hashes(root / "lisp") == expected
    init_unchanged = digest(init) == before_init
    markers = {name: (root / name).read_text() if (root / name).exists() else None
               for name in ("init-loaded.txt", "component-started.txt", "component-stopped.txt")}
    proof = {"source_assets": str(args.assets.resolve()), "lisp_files": len(expected),
             "lisp_hashes": expected, "synthetic_init_sha256": before_init,
             "assets_unchanged": assets_unchanged, "init_unchanged": init_unchanged,
             "markers": markers, "native_exit_code": run.returncode,
             "compiled_lisp_files": [str(p.relative_to(root)) for p in root.rglob("*.fas*")],
             "evidence_scope": "Host ECL with exact packaged Lisp sources; no ART or syscall tracing claim"}
    (root / "asset-proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(run.stdout, end="")
    print(f"Evidence: {root}")
    assert run.returncode == 0, "Native packaged-source gate failed; see host-test.log"
    assert assets_unchanged and init_unchanged, "Startup/vendor/runtime/init bytes changed"
    assert markers == {"init-loaded.txt": "trusted-init-ran", "component-started.txt": "started",
                       "component-stopped.txt": "stopped"}, "Trusted init/component lifecycle markers missing"
    assert not proof["compiled_lisp_files"], "Unexpected compiled Lisp output under copied asset tree"
    print(f"Verified {len(expected)} unchanged packaged Lisp files, init preservation and lifecycle markers.")


if __name__ == "__main__":
    main()
