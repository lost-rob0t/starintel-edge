;;;; Real Common Lisp/Sento test of the trusted service profile; synthetic local state only.
(require :asdf)
(asdf:initialize-source-registry
 `(:source-registry (:directory ,(uiop:merge-pathnames* "runtime/" (uiop:getcwd)))
                    :inherit-configuration))
(asdf:load-system :starintel-edge/runtime)
(star.edge.android:install-adapter-host)
(defvar *android-init-proof* nil)
(defvar *android-service-events* nil)
(let* ((root (merge-pathnames (format nil "edge-service-~D/" (random 1000000000))
                              (uiop:temporary-directory)))
       (init (merge-pathnames "init.lisp" root))
       (checks 0))
  (ensure-directories-exist init)
  (labels ((check (value) (incf checks) (unless value (error "Service check ~D failed" checks)))
           (write-init (text)
             (with-open-file (out init :direction :output :if-exists :supersede
                                      :if-does-not-exist :create)
               (write-string text out))))
    (unwind-protect
         (progn
           (check (not (star.edge.android:service-ready-p)))
           (write-init "(in-package :cl-user)
(setf *android-init-proof* :loaded)
(setf star.edge.android:*service-components*
      (list (star.edge.runtime:make-component \"synthetic-local\"
             :start (lambda () (push :started *android-service-events*))
             :stop (lambda () (push :stopped *android-service-events*)))))")
           (let ((before (uiop:read-file-string init)))
             (star.edge.android:start-service-runtime init)
             (check (eq *android-init-proof* :loaded))
             (check (star.edge.android:service-ready-p))
             (check (equal *android-service-events* '(:started)))
             (check (string= before (uiop:read-file-string init)))
             (check (search "\"init\":\"loaded\""
                            (star.edge.android:handle-request "service.status" nil nil)))
             (check (search "\"server-api\":\"unavailable\""
                            (star.edge.android:handle-request "service.status" nil nil)))
             ;; Data cannot turn the closed dispatcher into a reader/evaluator.
             (check (search "unknown-operation"
                            (star.edge.android:handle-request "load" "#.(error \"not-code\")" nil)))
             (check (string= (star.edge.android:handle-request "actor.roundtrip" nil nil)
                            "{\"status\":\"ok\",\"actor\":\"roundtrip\",\"message\":\"android-local\"}"))
             (check (search "\"state\":\"stopped\""
                            (star.edge.android:handle-request "service.stop" nil nil)))
             (check (not (star.edge.android:service-ready-p)))
             (check (null (star.edge.actors:current-actor-system)))
             (check (equal *android-service-events* '(:stopped :started)))
             (check (star.edge.android:stop-service-runtime)))
           ;; A later explicit start loads the same user-controlled Lisp file again.
           (setf *android-init-proof* nil)
           (star.edge.android:start-service-runtime init)
           (check (eq *android-init-proof* :loaded))
           (check (star.edge.android:service-ready-p))
           (star.edge.android:stop-service-runtime)
           (write-init "(error \"synthetic-private-value\")")
           (handler-case
               (progn (star.edge.android:start-service-runtime init) (check nil))
             (error (condition)
               (check (not (search "synthetic-private-value" (princ-to-string condition))))))
           (check (null (star.edge.actors:current-actor-system)))
           (check (not (star.edge.android:service-ready-p)))
           (write-init "(setf star.edge.android:*service-workers* 1000000)")
           (handler-case
               (progn (star.edge.android:start-service-runtime init) (check nil))
             (error () (check t)))
           (check (null (star.edge.actors:current-actor-system)))
           (format t "~D real Lisp/Sento Android service-profile checks passed; not ECL/ART/APK evidence.~%" checks))
      (star.edge.android:stop-service-runtime)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
