;;;; Trusted host-only fixture. No test endpoint is installed in production.
;;;; Keep the production JSON encoder, closed dispatcher, C ABI and JNI intact.
(require :asdf)
;; Existing relocated host ECL prefixes may retain build-time compiler paths.
;; Configure only the trusted host compiler; no dispatcher/runtime function changes.
#+ecl (require :cmp)
#+ecl
(let ((prefix (uiop:getenv "ECL_PREFIX")))
  (when prefix
    (let ((root (uiop:ensure-directory-pathname prefix)))
      (setf c::*ecl-include-directory* (namestring (merge-pathnames "include/" root))
            c::*ecl-library-directory* (namestring (merge-pathnames "lib/" root))
            c::*ecl-data-directory* (or (uiop:getenv "ECLDIR") c::*ecl-data-directory*)))))
(asdf:initialize-source-registry
 `(:source-registry
   (:directory ,(merge-pathnames "runtime/" (uiop:ensure-directory-pathname
                  (or (uiop:getenv "EDGE_ACTOR_INTEROP_ROOT")
                      (error "EDGE_ACTOR_INTEROP_ROOT is required")))))
   :inherit-configuration))
(asdf:load-system "starintel-edge/runtime")
(in-package #:star.edge.android)
(format t "~&ACTOR_RUNTIME~C~A~%" #\Tab
        (encode-json (list :implementation (lisp-implementation-type)
                           :version (lisp-implementation-version)
                           :sento (asdf:component-version (asdf:find-system "sento"))
                           :bordeaux-threads (asdf:component-version (asdf:find-system "bordeaux-threads")))))
(defvar *interop-deliveries* 0)
(star.edge.actors:start-actor-system :workers 1)
(let ((actor (star.edge.actors:actor-of
              :name "interop-opaque-echo"
              :receive (lambda (message)
                         (destructuring-bind (payload capability) message
                           (incf *interop-deliveries*)
                           (list :status :ok :payload payload :capability capability
                                 :length (length payload)
                                 :codes (map 'list #'char-code payload)
                                 :sequence *interop-deliveries*))))))
  (setf *adapter-host*
        (star.edge.host:make-host
         :platform "android"
         :capabilities (lambda () '("interop.echo"))
         :authorize (lambda (capability payload)
                      (declare (ignore capability payload)) t)
         :backend (lambda (operation payload capability)
                    (cond
                      ((string= operation "dispatch")
                       (sento.actor:ask-s actor (list payload capability) :time-out 3))
                      ((string= operation "status")
                       (list :status :ok :actor-deliveries *interop-deliveries*))
                      (t (list :status :unavailable :reason :no-backend)))))))
