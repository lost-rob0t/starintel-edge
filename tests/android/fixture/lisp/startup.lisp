;;;; Host-only boot fixture. Loads/compiles the real runtime and dependencies in
;;;; normal ASDF order, then installs the one process-owned adapter host.
;;;; The Android bundle instead loads its patched vendored source tree; this
;;;; fixture cannot establish that packaged startup path. Request data is never
;;;; read as code. This file is not packaged in the app.

(require :asdf)
(let* ((load-dir (make-pathname :defaults *load-truename*
                                :name nil :type nil))
       (runtime-dir (make-pathname
                     :defaults load-dir
                     :directory (append (butlast (pathname-directory load-dir) 4)
                                        '("runtime")))))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,runtime-dir) :inherit-configuration)))

;; Dependencies contain read-time constants/macros which require their normal
;; ASDF compile/load order; LOAD-SOURCE-OP is not a valid substitute. Keep this
;; top-level, outside the interpreted lexical frame used to resolve paths.
(asdf:load-system :starintel-edge/runtime)

;; Resolve only after the runtime package is loaded.
(let* ((package (find-package "STAR.EDGE.ANDROID"))
       (install (and package (find-symbol "INSTALL-ADAPTER-HOST" package))))
  (unless (and install (fboundp install))
    (error "Android runtime adapter entrypoint is unavailable"))
  (funcall install))
