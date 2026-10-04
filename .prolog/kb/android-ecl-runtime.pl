% Durable KB: StarIntel Edge Android ECL runtime work.
% Loader: consult index.pl.

% --- ECL embedding (adapter C ABI) ---
ecl_embedding_fact(cl_shutdown_takes_no_args, 'ECL 26.x declares cl_shutdown(void); passing 0 is a compile error').
ecl_embedding_fact(cl_boot_returns_int, 'ECL 26.x cl_boot returns int (0 = failure), not cl_object').
ecl_embedding_fact(pthread_before_ecl_h, 'ECL headers need pthread.h included BEFORE ecl/ecl.h (pthread_rwlock_t typedef)').
ecl_embedding_fact(strict_ansi_hides_rwlock, '-std=c99 (strict __STRICT_ANSI__) hides pthread_rwlock_t; use -std=gnu99').
ecl_embedding_fact(cl_package_locked, 'ecl_make_symbol cannot intern fresh names in locked COMMON-LISP; use COMMON-LISP-USER for eval-built variable names').
ecl_embedding_fact(si_safe_eval_swallows_conditions, 'si_safe_eval(form, Cnil, OBJNULL) returns OBJNULL on any Lisp error with no message; for boot diagnostics, print progress/conditions from the trusted Lisp boot file').
ecl_embedding_fact(load_truename_nil_with_relative_paths, 'In embedded ECL, (load "relative/path") can leave *load-truename* nil downstream; realpath() the runtime directory in C before building the startup.lisp path').
ecl_embedding_fact(embedded_load_pattern, 'Working pattern: cl_boot(1, argv) -> si_safe_eval((LOAD "<abs>/lisp/startup.lisp")) -> si_safe_eval((INSTALL-ADAPTER-HOST)) with the install call deferred via find-symbol in the boot file').
ecl_embedding_fact(android_static_modules, 'On Android, statically link ECL libcmp.a and libasdf.a into the adapter with --whole-archive, then call ecl_init_module for CMP and ASDF after cl_boot; dynamic REQUIRE from app-private FAS files aborts before a Lisp condition handler runs').
ecl_embedding_fact(android_private_environment, 'Canonicalize the app-private runtime root before cl_boot; set ECLDIR to its bundled ecl directory and TMPDIR/XDG_CACHE_HOME to a mode-0700 runtime/tmp directory').
ecl_embedding_fact(android_source_load, 'Android has no in-app C compiler: ASDF LOAD-SOURCE-OP loads the pinned runtime closure; dependencies whose EVAL-WHEN omitted :EXECUTE need explicit source-load compatibility patches in the Nix vendor derivation').

% --- Lisp reader/print gotchas ---
lisp_fact(no_c_escapes_in_strings, 'Standard CL string literals do NOT process \t or \n; construct control chars via #\tab/#\newline or format ~C. SBCL ~S prints tab/newline raw, so string= mismatches look baffling').

% --- Nix / tooling ---
nix_fact(flake_src_is_git_index, 'nix flake src = self only sees files present in the git index; git add (or add -N) new files before nix build').
nix_fact(lisp_modules_ecl_is_static, 'ecl.withPackages wraps a STATIC ecl (no libecl.so/ecl-config); for C-linked embedding use pkgs.ecl and pin Lisp dep sources via fetchzip + CL_SOURCE_REGISTRY').
nix_fact(host_actor_test_deps, 'Host adapter fixture and Android bundle share the pinned actorVendorTree in flake.nix; do not test against an ambient Quicklisp closure').
nix_fact(nixpkgs_ecl_version, 'nixpkgs nixos-unstable ecl = 26.5.5; lisp-modules ecl = 24.5.10 (mismatch matters for fasl reuse)').
nix_fact(ecl_cross_short_bits, 'ECL 26.5.5 Android cross_config must define CL_SHORT_BITS=16 for both x86_64 and arm64-v8a bootstraps').
nix_fact(android_actor_vendor, 'Pin the complete Sento/Quicklisp source closure; generate cl-unicode lists/hash-tables/methods in a writable native derivation and package the resulting immutable sources').

% --- Project conventions ---
project_fact(android_ops_structure, 'runtime/android.lisp: star.edge.android mirrors star.edge.linux (make-android-host, install-adapter-host, handle-request, encode-json); closed JSON responses from plist shapes').
project_fact(fixture_is_trusted_boot, 'tests/android/fixture/lisp/startup.lisp is the host-test equivalent of the shipped bundle boot file; loads real runtime sources via *load-truename*, installs the adapter host; no simulation').
project_fact(android_acceptance_gate, 'tests/android/run_emulator_test.sh owns an ephemeral API-36 x86_64 AVD, exact adb serial, temporary signing key, Wi-Fi/data-off local Sento round-trip, UI/logcat assertions, and teardown; it installs only the Edge diagnostic APK').
