;;;; Trusted Android runtime bootstrap. This file is copied from the APK's
;;;; assets into app-private storage before starintel_ecl_start is called.
;;;; Request data never reaches the reader or loader.

(handler-case
    (require :asdf)
  (error (condition)
    (with-open-file
        (stream (merge-pathnames "startup-error.txt" *load-truename*)
                :direction :output :if-exists :supersede
                :if-does-not-exist :create)
      (princ condition stream))
    (error condition)))

(let* ((lisp-dir (make-pathname :defaults *load-truename*
                                :name nil :type nil))
       (vendor-dir (merge-pathnames "vendor/" lisp-dir))
       (runtime-dir (merge-pathnames "runtime/" lisp-dir))
       (error-path (merge-pathnames "startup-error.txt" lisp-dir)))
  (when (probe-file error-path) (delete-file error-path))
  (handler-case
      (progn
        (asdf:initialize-source-registry
         `(:source-registry (:tree ,vendor-dir) (:tree ,runtime-dir)
                            :ignore-inherited-configuration))
        ;; Android has no in-app C toolchain. LOAD-SOURCE-OP recursively loads
        ;; the pinned dependency graph without ASDF's compile-before-load step.
        (asdf:operate 'asdf:load-source-op :starintel-edge/runtime)
        ;; STAR.EDGE.ANDROID is created by runtime-package.lisp, so resolve its
        ;; entrypoint after loading rather than naming the package while this
        ;; file itself is still being read.
        (let* ((package (find-package "STAR.EDGE.ANDROID"))
               (install (and package
                             (find-symbol "INSTALL-ADAPTER-HOST" package))))
          (unless (and install (fboundp install))
            (error "Android runtime adapter entrypoint is unavailable"))
          (funcall install)))
    (error (condition)
      (with-open-file (stream error-path :direction :output
                             :if-exists :supersede
                             :if-does-not-exist :create)
        (princ condition stream))
      (error condition))))
