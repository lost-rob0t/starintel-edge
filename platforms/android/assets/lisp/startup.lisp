;;;; Trusted Android runtime bootstrap. This file is copied from the APK's
;;;; assets into app-private storage before starintel_ecl_start is called.
;;;; Request data never reaches the reader or loader.

(require :asdf)

(let* ((lisp-dir (make-pathname :defaults *load-truename* :name nil :type nil))
       (vendor-dir (merge-pathnames "vendor/" lisp-dir))
       (runtime-dir (merge-pathnames "runtime/" lisp-dir))
       ;; Fixed trusted path, preserved by the host; never supplied through JSON.
       (init-file (merge-pathnames "../init.lisp" lisp-dir)))
  (handler-case
      (progn
        (asdf:initialize-source-registry
         `(:source-registry (:tree ,vendor-dir) (:tree ,runtime-dir)
                            :ignore-inherited-configuration))
        (asdf:operate 'asdf:load-source-op :starintel-edge/runtime)
        ;; Resolve only these packaged entrypoints after the package exists.
        (let* ((package (find-package "STAR.EDGE.ANDROID"))
               (install (and package (find-symbol "INSTALL-ADAPTER-HOST" package)))
               (start (and package (find-symbol "START-SERVICE-RUNTIME" package))))
          (unless (and install start (fboundp install) (fboundp start))
            (error "Android runtime adapter entrypoint is unavailable"))
          (funcall install)
          (funcall start init-file)))
    (error ()
      ;; Never persist or log a rendered user-init condition or secret-bearing text.
      (error "android-trusted-startup-failed"))))
