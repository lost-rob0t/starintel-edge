;;;; Host-test boot fixture: equivalent of the shipped Android runtime
;;;; bundle's trusted lisp/startup.lisp. Loads the real runtime sources
;;;; relative to this file (the bundle loads the same sources compiled),
;;;; then installs the one process-owned adapter host. This file is trusted
;;;; boot code shipped with the runtime; request data is never loaded.

(require :asdf)
(let* ((load-dir (make-pathname :defaults *load-truename*
                                :name nil :type nil))
       (runtime-dir (make-pathname
                     :defaults load-dir
                     :directory (append (butlast (pathname-directory load-dir) 4)
                                        '("runtime")))))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,runtime-dir) :inherit-configuration))
  (asdf:operate 'asdf:load-source-op :starintel-edge/runtime)
  ;; The package is defined by runtime-package.lisp above, so resolve the
  ;; entrypoint after those trusted sources load instead of naming that
  ;; package while this startup file is still being read.
  (let* ((package (find-package "STAR.EDGE.ANDROID"))
         (install (and package (find-symbol "INSTALL-ADAPTER-HOST" package))))
    (unless (and install (fboundp install))
      (error "Android runtime adapter entrypoint is unavailable"))
    (funcall install)))
