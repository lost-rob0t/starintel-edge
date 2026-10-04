;;;; Trusted fenv regression fixture; never packaged or dispatched as an eval API.
(require :asdf)
(load (merge-pathnames "tests/interop/actor/startup.lisp"
      (uiop:ensure-directory-pathname (uiop:getenv "EDGE_ACTOR_INTEROP_ROOT"))))
(in-package #:star.edge.android)
(setf *adapter-host*
      (star.edge.host:make-host
       :platform "android"
       :capabilities (lambda () '("interop.fpe" "interop.error"))
       :authorize (lambda (capability payload) (declare (ignore capability payload)) t)
       :backend (lambda (operation payload capability)
                  (declare (ignore operation))
                  (cond
                    ((equal capability "interop.error") (error "trusted synthetic fenv error"))
                    ((equal capability "interop.fpe")
                     ;; Runtime-dependent zero prevents constant folding. The guarded
                     ;; ECL boundary must retain its division-by-zero Lisp condition.
                     (handler-case
                         (list :status :error :value (/ 1d0 (coerce (length payload) 'double-float)))
                       (division-by-zero () (list :status :ok :fpe :caught))))
                    (t (list :status :unavailable))))))
