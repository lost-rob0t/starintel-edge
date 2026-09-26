{
  description = "Reproducible StarIntel Edge runtimes and Android ECL artifacts";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkPackages = system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
          apiLevel = "24";
          ndkVersion = "28.2.13676358";
          android = pkgs.androidenv.composeAndroidPackages {
            platformVersions = [ "36" ];
            buildToolsVersions = [ "36.0.0" ];
            includeNDK = true;
            ndkVersions = [ ndkVersion ];
            includeEmulator = true;
            includeSystemImages = true;
            systemImageTypes = [ "google_apis" ];
            abiVersions = [ "x86_64" ];
          };
          androidSdkRoot = "${android.androidsdk}/libexec/android-sdk";
          androidJar = "${androidSdkRoot}/platforms/android-36/android.jar";
          androidBuildTools = "${androidSdkRoot}/build-tools/36.0.0";
          ndkRoot = "${android.ndk-bundle}/libexec/android-sdk/ndk/${ndkVersion}";
          toolchain = "${ndkRoot}/toolchains/llvm/prebuilt/linux-x86_64";
          # ECL's target bootstrap must use a host ECL built from the same
          # source with the target's C99-complex setting.
          eclHost = pkgs.ecl.overrideAttrs (old: {
            pname = "starintel-ecl-cross-host";
            configureFlags = (old.configureFlags or [ ]) ++ [ "--disable-c99complex" ];
            # The target build only needs the matched compiler bootstrap.
            # Upstream ECL's full ANSI suite remains covered by nixpkgs.
            doCheck = false;
            doInstallCheck = false;
          });

          mkAndroidEcl = { abi, hostTriple, clangTriple, crossConfig }:
            pkgs.stdenv.mkDerivation {
              pname = "starintel-ecl-android-${abi}";
              inherit (pkgs.ecl) version src;
              sourceRoot = "ecl-${pkgs.ecl.version}";
              nativeBuildInputs = with pkgs; [
                autoconf
                automake
                libtool
                texinfo
                which
              ];
              enableParallelBuilding = true;
              dontStrip = true;
              configurePhase = ''
                runHook preConfigure
                patchShebangs .
                export ECL_TO_RUN=${eclHost}/bin/ecl
                export CC=${toolchain}/bin/${clangTriple}${apiLevel}-clang
                export CXX=${toolchain}/bin/${clangTriple}${apiLevel}-clang++
                export AR=${toolchain}/bin/llvm-ar
                export AS=${toolchain}/bin/llvm-as
                export LD=${toolchain}/bin/ld.lld
                export NM=${toolchain}/bin/llvm-nm
                export RANLIB=${toolchain}/bin/llvm-ranlib
                export STRIP=${toolchain}/bin/llvm-strip
                export SYSROOT=${toolchain}/sysroot
                export CPPFLAGS="--sysroot=$SYSROOT"
                export CFLAGS="--sysroot=$SYSROOT -fPIC"
                export CXXFLAGS="$CFLAGS"
                export LDFLAGS="--sysroot=$SYSROOT -Wl,--build-id=sha1"
                ./configure \
                  --build=${pkgs.stdenv.buildPlatform.config} \
                  --host=${hostTriple} \
                  --prefix=$out \
                  --disable-c99complex \
                  --with-tcp=no \
                  --with-cross-config=${crossConfig}
                runHook postConfigure
              '';
              meta = {
                description = "ECL for the StarIntel Edge Android ${abi} runtime";
                license = pkgs.lib.licenses.lgpl2Plus;
                platforms = [ system ];
              };
            };

          eclX86_64 = mkAndroidEcl {
            abi = "x86_64";
            hostTriple = "x86_64-linux-android";
            clangTriple = "x86_64-linux-android";
            crossConfig = ./platforms/android/nix/android-x86_64.cross_config;
          };

          eclArm64 = mkAndroidEcl {
            abi = "arm64-v8a";
            hostTriple = "aarch64-linux-android";
            clangTriple = "aarch64-linux-android";
            crossConfig = ./platforms/android/nix/android-arm64.cross_config;
          };

          # Host-compiled adapter + native test suite. This is the
          # lifecycle/ownership/bounds/error gate from docs/ANDROID-RUNTIME.md;
          # it is not evidence of Android ART execution.
          # Pinned Lisp sources shared by the host fixture and Android bundle.
          bordeauxThreadsSrc = pkgs.fetchzip {
            url = "https://beta.quicklisp.org/archive/bordeaux-threads/2024-10-12/bordeaux-threads-v0.9.4.tgz";
            hash = "sha256-raBBgkg7pDqP05wzqMFTrXYWUcSpcRtiwRCNlodSQbc=";
          };

          alexandriaSrc = pkgs.fetchzip {
            url = "https://beta.quicklisp.org/archive/alexandria/2024-10-12/alexandria-20241012-git.tgz";
            hash = "sha256-vPHp/dXX24zUPF1t7EdBryzqlG33A0fOoD5loFOxAEs=";
          };

          globalVarsSrc = pkgs.fetchzip {
            url = "https://beta.quicklisp.org/archive/global-vars/2014-11-06/global-vars-20141106-git.tgz";
            hash = "sha256-bXxeNNnFsGbgP/any8rR3xBvHE9Rb4foVfrdQRHroxo=";
          };

          trivialFeaturesSrc = pkgs.fetchzip {
            url = "https://beta.quicklisp.org/archive/trivial-features/2025-06-22/trivial-features-20250622-git.tgz";
            hash = "sha256-2KxtbGtnlf6JgWDlX7LVdvaWCsPOUxb2aIZnrYvndGQ=";
          };

          trivialGarbageSrc = pkgs.fetchzip {
            url = "https://beta.quicklisp.org/archive/trivial-garbage/2023-10-21/trivial-garbage-20231021-git.tgz";
            hash = "sha256-TZuXds3ACc5z/So1hBfR0zU3sy8DRA2BUuxO8Pju3GU=";
          };

          quicklispSource = name: url: hash: {
            inherit name;
            src = pkgs.fetchzip { inherit url hash; };
          };

          clPpcreSrc = pkgs.fetchzip {
            url = "https://beta.quicklisp.org/archive/cl-ppcre/2025-06-22/cl-ppcre-20250622-git.tgz";
            hash = "sha256-tk+BJyCeLOmrayCMGfo9EgdxJYYakdFAd/MGlK+A+jg=";
          };
          clUnicodeSrc = pkgs.fetchzip {
            url = "https://beta.quicklisp.org/archive/cl-unicode/2024-10-12/cl-unicode-20241012-git.tgz";
            hash = "sha256-1OTtDdn4mVoNqSVfKKUJvD56RkD8CL0B6bWSJKdkzZM=";
          };
          flexiStreamsSrc = pkgs.fetchzip {
            url = "https://beta.quicklisp.org/archive/flexi-streams/2024-10-12/flexi-streams-20241012-git.tgz";
            hash = "sha256-cCpCBttChCko6+50ancWv6BGX9quPYGrrZpH5zMRYq4=";
          };
          trivialGrayStreamsSrc = pkgs.fetchzip {
            url = "https://beta.quicklisp.org/archive/trivial-gray-streams/2024-10-12/trivial-gray-streams-20241012-git.tgz";
            hash = "sha256-NXMvoSlMC/PyrKS0EVoGdempGZN6z3h0YRr102HBhkc=";
          };
          clSpeedyQueueSrc = pkgs.fetchzip {
            url = "https://beta.quicklisp.org/archive/cl-speedy-queue/2015-03-02/cl-speedy-queue-20150302-git.tgz";
            hash = "sha256-OGaqhBkHKNUwHY3FgnMbWGdsUfBn0QDTl2vTZPu28DM=";
          };
          clSpeedyQueueSourceLoad = pkgs.runCommand
            "cl-speedy-queue-source-load" { } ''
              cp -R ${clSpeedyQueueSrc}/. "$out"
              chmod -R u+w "$out"
              substituteInPlace "$out/cl-speedy-queue.lisp" \
                --replace-fail \
                '(eval-when (:compile-toplevel)' \
                '(eval-when (:compile-toplevel :load-toplevel :execute)'
            '';

          # The Quicklisp cl-unicode archive omits three generated source
          # files and tries to regenerate them beside its read-only source.
          # Generate them once in a reproducible writable derivation so ART
          # never needs a build-time Unicode data generator.
          clUnicodeGenerated = pkgs.runCommand "cl-unicode-generated-source" {
            nativeBuildInputs = [ pkgs.ecl ];
          } ''
            cp -R ${clUnicodeSrc}/. "$out"
            chmod -R u+w "$out"
            export CL_SOURCE_REGISTRY="${clPpcreSrc}//:${flexiStreamsSrc}//:${trivialGrayStreamsSrc}//:$out//"
            export ASDF_OUTPUT_TRANSLATIONS="/:$TMPDIR/fasl/"
            ecl -norc \
              -eval '(require :asdf)' \
              -eval '(asdf:load-system :cl-unicode)' \
              -eval '(quit)'
            test -f "$out/lists.lisp"
            test -f "$out/hash-tables.lisp"
            test -f "$out/methods.lisp"
          '';

          actorVendorSources = [
            { name = "alexandria"; src = alexandriaSrc; }
            { name = "bordeaux-threads"; src = bordeauxThreadsSrc; }
            { name = "global-vars"; src = globalVarsSrc; }
            { name = "trivial-features"; src = trivialFeaturesSrc; }
            { name = "trivial-garbage"; src = trivialGarbageSrc; }
            (quicklispSource "sento"
              "https://beta.quicklisp.org/archive/cl-gserver/2026-01-01/cl-gserver-20260101-git.tgz"
              "sha256-3ciuNOgeonfKAgbMeW5jMoYdltDtUJm8oLK2vhQUitM=")
            (quicklispSource "log4cl"
              "https://beta.quicklisp.org/archive/log4cl/2023-06-18/log4cl-20230618-git.tgz"
              "sha256-8/jWyw1+FTDWMIiQPaAsSumjEtfhKxQsoT7NMrxOIVg=")
            { name = "cl-speedy-queue"; src = clSpeedyQueueSourceLoad; }
            (quicklispSource "str"
              "https://beta.quicklisp.org/archive/cl-str/2026-01-01/cl-str-20260101-git.tgz"
              "sha256-SflmU0BZ4BkwV9+h0gNfDYNbpdykfIpf0jYAo30walY=")
            (quicklispSource "blackbird"
              "https://beta.quicklisp.org/archive/blackbird/2024-10-12/blackbird-20241012-git.tgz"
              "sha256-qKq6rR5jriB5pXuuj17UCeJ9wBRMcBBIVg6bgKxGDy8=")
            (quicklispSource "binding-arrows"
              "https://beta.quicklisp.org/archive/binding-arrows/2024-10-12/binding-arrows-20241012-git.tgz"
              "sha256-QkDGjkKkp7JdVpYaZcDo+Mv0o+2Wip3gZ4ksigtf/k8=")
            (quicklispSource "timer-wheel"
              "https://beta.quicklisp.org/archive/timer-wheel/2026-01-01/timer-wheel-20260101-git.tgz"
              "sha256-Pgr6yKZJtvMKN/i8TPkSb6Px1FQBc6/ioIYYWyDBJHE=")
            (quicklispSource "local-time-duration"
              "https://beta.quicklisp.org/archive/local-time-duration/2018-04-30/local-time-duration-20180430-git.tgz"
              "sha256-ps21NLe2t1FRo9QaM4KU4RbUkPR4y/Qpo2FsisKrIzg=")
            (quicklispSource "local-time"
              "https://beta.quicklisp.org/archive/local-time/2026-01-01/local-time-20260101-git.tgz"
              "sha256-Ac7JkJBtsh4KlPF9V4vBJa7KnUTzzVgXwuWO7tEzQuY=")
            (quicklispSource "esrap"
              "https://beta.quicklisp.org/archive/esrap/2026-01-01/esrap-20260101-git.tgz"
              "sha256-zWzmRXUWWa+1WocIhlFONwMa/09TXNNNCk+EzR95oVk=")
            (quicklispSource "trivial-with-current-source-form"
              "https://beta.quicklisp.org/archive/trivial-with-current-source-form/2026-01-01/trivial-with-current-source-form-20260101-git.tgz"
              "sha256-fObonQsjD1YeJNlqHESnE7B2WDShYmvyTcb0y9arL3g=")
            (quicklispSource "atomics"
              "https://beta.quicklisp.org/archive/atomics/2026-01-01/atomics-20260101-git.tgz"
              "sha256-PNdpxJ2qsBBoCyBfBpFd/NTUGXtdV3AdCz5nBmEzWyU=")
            (quicklispSource "documentation-utils"
              "https://beta.quicklisp.org/archive/documentation-utils/2026-01-01/documentation-utils-20260101-git.tgz"
              "sha256-6c+Qwbb9RIqRKBumlp+LASE/zxCpLUdBYzWFD2OdDHQ=")
            (quicklispSource "trivial-indent"
              "https://beta.quicklisp.org/archive/trivial-indent/2026-01-01/trivial-indent-20260101-git.tgz"
              "sha256-cEl2aTV2/a3K0fQTgVYGZ+/a/kdDcHDM/Bf3jBOfaok=")
            { name = "cl-ppcre"; src = clPpcreSrc; }
            { name = "cl-unicode"; src = clUnicodeGenerated; }
            { name = "flexi-streams"; src = flexiStreamsSrc; }
            { name = "trivial-gray-streams"; src = trivialGrayStreamsSrc; }
            (quicklispSource "cl-change-case"
              "https://beta.quicklisp.org/archive/cl-change-case/2025-06-22/cl-change-case-20250622-git.tgz"
              "sha256-qB+iYSMs1IQ0Nz7E/JWOV+GYvLSDPAjHCV7NXb/A3Go=")
            (quicklispSource "vom"
              "https://beta.quicklisp.org/archive/vom/2024-10-12/vom-20241012-git.tgz"
              "sha256-JeVHEh5yDOuSVpap1P/i4UC5xH7KsfFNhRfJAZPJ2eY=")
          ];

          populateActorVendor = pkgs.lib.concatMapStringsSep "\n"
            (source: ''
              cp -R ${source.src} \
                "$out/${source.name}"
            '') actorVendorSources;
          actorVendorTree = pkgs.runCommand "starintel-edge-actor-vendor" { } ''
            mkdir -p "$out"
            ${populateActorVendor}
            substituteInPlace "$out/vom/vom.lisp" \
              --replace-fail \
              '(eval-when (:load-toplevel :compile-toplevel)' \
              '(eval-when (:load-toplevel :compile-toplevel :execute)'
            substituteInPlace "$out/local-time/src/local-time.lisp" \
              --replace-fail \
              '(eval-when (:compile-toplevel :load-toplevel)' \
              '(eval-when (:compile-toplevel :load-toplevel :execute)'
            for source in \
              "$out/global-vars/global-vars.lisp" \
              "$out/log4cl/src/logger.lisp" \
              "$out/sento/src/actor-system.lisp" \
              "$out/sento/src/actor.lisp" \
              "$out/sento/src/dispatcher.lisp"
            do
              substituteInPlace "$source" \
                --replace-fail \
                '(eval-when (:compile-toplevel)' \
                '(eval-when (:compile-toplevel :load-toplevel :execute)'
            done
          '';
          actorSourceRegistry = "${actorVendorTree}//";
          installActorVendor = ''
            cp -R ${actorVendorTree}/. \
              "$out/assets/starintel-edge/lisp/vendor/"
          '';

          mkAndroidRuntime = { abi, clangTriple, ecl }:
            pkgs.stdenvNoCC.mkDerivation {
              pname = "starintel-edge-android-runtime-${abi}";
              version = "0.1.0";
              src = self;
              nativeBuildInputs = [ pkgs.jq ];
              dontConfigure = true;
              buildPhase = ''
                runHook preBuild
                android_cc=${toolchain}/bin/${clangTriple}${apiLevel}-clang
                lmdb_dir=${pkgs.lmdb.src}/libraries/liblmdb

                "$android_cc" -O2 -fPIC -shared -DMDB_USE_ROBUST=0 \
                  -Wl,-soname,liblmdb.so \
                  "$lmdb_dir/mdb.c" "$lmdb_dir/midl.c" \
                  -o liblmdb.so

                "$android_cc" -O2 -fPIC -shared -pthread \
                  -Wl,-z,defs -Wl,-soname,libstarintel_ecl_adapter.so \
                  -I${ecl}/include -Iplatforms/android/native \
                  platforms/android/native/starintel_ecl_adapter.c \
                  -Wl,--whole-archive \
                  ${ecl}/lib/ecl-${ecl.version}/libcmp.a \
                  ${ecl}/lib/ecl-${ecl.version}/libasdf.a \
                  -Wl,--no-whole-archive \
                  -L${ecl}/lib -lecl -ldl -lm -llog \
                  -o libstarintel_ecl_adapter.so

                "$android_cc" -O2 -fPIC -shared \
                  -Wl,-z,defs -Wl,-soname,libstarintel_ecl_jni.so \
                  -I${toolchain}/sysroot/usr/include \
                  -Iplatforms/android/native \
                  platforms/android/native/starintel_ecl_jni.c \
                  -L. -lstarintel_ecl_adapter \
                  -o libstarintel_ecl_jni.so
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                mkdir -p "$out/jni/${abi}" \
                  "$out/include" \
                  "$out/kotlin/actor/starintel/edge" \
                  "$out/assets/starintel-edge/ecl" \
                  "$out/assets/starintel-edge/lisp/runtime" \
                  "$out/assets/starintel-edge/lisp/vendor"
                install -m755 ${ecl}/lib/libecl.so \
                  "$out/jni/${abi}/libecl.so"
                install -m755 liblmdb.so \
                  "$out/jni/${abi}/liblmdb.so"
                install -m755 libstarintel_ecl_adapter.so \
                  "$out/jni/${abi}/libstarintel_ecl_adapter.so"
                install -m755 libstarintel_ecl_jni.so \
                  "$out/jni/${abi}/libstarintel_ecl_jni.so"
                install -m644 platforms/android/native/starintel_ecl_adapter.h \
                  "$out/include/starintel_ecl_adapter.h"
                install -m644 \
                  platforms/android/kotlin/actor/starintel/edge/StarIntelEdgeRuntime.kt \
                  "$out/kotlin/actor/starintel/edge/StarIntelEdgeRuntime.kt"
                install -m644 platforms/android/assets/lisp/startup.lisp \
                  "$out/assets/starintel-edge/lisp/startup.lisp"
                cp -R ${ecl}/lib/ecl-${ecl.version}/. \
                  "$out/assets/starintel-edge/ecl/"
                install -m644 runtime/starintel-edge.asd runtime/package.lisp \
                  runtime/host.lisp runtime/runtime-package.lisp \
                  runtime/actors.lisp runtime/lifecycle.lisp \
                  runtime/outbox.lisp runtime/power.lisp runtime/linux.lisp \
                  runtime/android.lisp \
                  "$out/assets/starintel-edge/lisp/runtime/"
                ${installActorVendor}

                ecl_hash=$(sha256sum "$out/jni/${abi}/libecl.so")
                ecl_hash=''${ecl_hash%% *}
                lmdb_hash=$(sha256sum "$out/jni/${abi}/liblmdb.so")
                lmdb_hash=''${lmdb_hash%% *}
                adapter_hash=$(sha256sum \
                  "$out/jni/${abi}/libstarintel_ecl_adapter.so")
                adapter_hash=''${adapter_hash%% *}
                jni_hash=$(sha256sum \
                  "$out/jni/${abi}/libstarintel_ecl_jni.so")
                jni_hash=''${jni_hash%% *}
                jq -n \
                  --arg abi "${abi}" \
                  --arg api "${apiLevel}" \
                  --arg eclVersion "${ecl.version}" \
                  --arg eclSha256 "$ecl_hash" \
                  --arg lmdbSha256 "$lmdb_hash" \
                  --arg adapterSha256 "$adapter_hash" \
                  --arg jniSha256 "$jni_hash" \
                  '{abi: $abi, androidMinApi: ($api | tonumber),
                    adapterAbiVersion: 1, eclVersion: $eclVersion,
                    artifacts: {
                      "libecl.so": $eclSha256,
                      "liblmdb.so": $lmdbSha256,
                      "libstarintel_ecl_adapter.so": $adapterSha256,
                      "libstarintel_ecl_jni.so": $jniSha256
                    }}' > "$out/manifest.json"
                runHook postInstall
              '';
            };

          runtimeX86_64 = mkAndroidRuntime {
            abi = "x86_64";
            clangTriple = "x86_64-linux-android";
            ecl = eclX86_64;
          };

          runtimeArm64 = mkAndroidRuntime {
            abi = "arm64-v8a";
            clangTriple = "aarch64-linux-android";
            ecl = eclArm64;
          };

          runtimeDiagnosticApk = pkgs.stdenvNoCC.mkDerivation {
            pname = "starintel-edge-runtime-diagnostic";
            version = "0.1.0";
            src = self;
            nativeBuildInputs = [ pkgs.jdk17 pkgs.kotlin pkgs.zip ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              mkdir -p classes dex package/lib/x86_64 package/assets
              kotlinc \
                ${runtimeX86_64}/kotlin/actor/starintel/edge/StarIntelEdgeRuntime.kt \
                tests/android/diagnostic/RuntimeDiagnosticActivity.kt \
                -classpath ${androidJar} \
                -jvm-target 1.8 \
                -d classes
              jar --create --file diagnostic.jar -C classes .
              ${androidBuildTools}/d8 \
                --min-api ${apiLevel} \
                --lib ${androidJar} \
                --output dex \
                diagnostic.jar ${pkgs.kotlin}/lib/kotlin-stdlib.jar
              cp dex/classes.dex package/classes.dex
              cp -R ${runtimeX86_64}/jni/x86_64/. package/lib/x86_64/
              cp -R ${runtimeX86_64}/assets/. package/assets/
              ${androidBuildTools}/aapt2 link \
                --manifest tests/android/diagnostic/AndroidManifest.xml \
                -I ${androidJar} \
                -o linked.apk
              cp linked.apk diagnostic-unaligned.apk
              (cd package && zip -q -r ../diagnostic-unaligned.apk \
                classes.dex lib assets)
              ${androidBuildTools}/zipalign -f 4 \
                diagnostic-unaligned.apk diagnostic-unsigned.apk
              runHook postBuild
            '';
            installPhase = ''
              install -Dm644 diagnostic-unsigned.apk \
                "$out/starintel-edge-runtime-diagnostic-unsigned.apk"
            '';
          };

          hostAdapterTest = pkgs.stdenv.mkDerivation {
            name = "starintel-ecl-adapter-host-test";
            src = self;
            nativeBuildInputs = [ pkgs.ecl ];
            dontConfigure = true;
            buildPhase = ''
              cc -O2 -Wall -Werror -std=gnu99 $(ecl-config --cflags) \
                -Iplatforms/android/native \
                -o native_test \
                platforms/android/native/starintel_ecl_adapter.c \
                tests/android/native_test.c \
                $(ecl-config --libs)
            '';
            doCheck = true;
            checkPhase = ''
              export CL_SOURCE_REGISTRY="${actorSourceRegistry}"
              export XDG_CACHE_HOME="$TMPDIR/cache"
              ./native_test tests/android/fixture
            '';
            installPhase = ''
              install -Dm755 native_test $out/bin/native_test
            '';
          };
        in {
          inherit pkgs android eclHost eclX86_64 eclArm64
            runtimeX86_64 runtimeArm64 runtimeDiagnosticApk hostAdapterTest;
        };
    in {
      packages = forAllSystems (system:
        let p = mkPackages system;
        in {
          android-ecl-x86_64 = p.eclX86_64;
          android-ecl-arm64-v8a = p.eclArm64;
          android-runtime-x86_64 = p.runtimeX86_64;
          android-runtime-arm64-v8a = p.runtimeArm64;
          android-runtime-diagnostic-apk = p.runtimeDiagnosticApk;
          default = p.runtimeX86_64;
        });

      checks = forAllSystems (system:
        let p = mkPackages system;
        in {
          host-adapter-test = p.hostAdapterTest;
        });

      devShells = forAllSystems (system:
        let p = mkPackages system;
        in {
          default = p.pkgs.mkShell {
            packages = [
              p.pkgs.ecl
              p.pkgs.cmake
              p.pkgs.ninja
              p.pkgs.jdk17
              p.pkgs.kotlin
              p.android.androidsdk
              p.android.ndk-bundle
            ];
            ANDROID_SDK_ROOT = "${p.android.androidsdk}/libexec/android-sdk";
            STARINTEL_ANDROID_NDK = "${p.android.ndk-bundle}/libexec/android-sdk/ndk/28.2.13676358";
          };
        });
    };
}
