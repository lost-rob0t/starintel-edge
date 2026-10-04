;;;; Trusted local Android service lifecycle over the existing managed Sento runtime.
;;;; No remote config/eval/load operation is exposed by this module.
(in-package #:star.edge.android)

(defvar *service-components* nil
  "Extra managed components supplied by trusted local init.lisp; disabled by default.")
(defvar *service-workers* 1 "Pinned actor workers for the Android local profile (1..4).")
(defvar *service-init-loaded-p* nil)
(defvar *service-stop-unconfirmed-p* nil)

(defun service-ready-p ()
  (and *service-init-loaded-p*
       (eq :running (star.edge.runtime:runtime-state (star.edge.runtime:current-runtime)))
       (not (null (star.edge.actors:current-actor-system)))))

(defun start-service-runtime (init-file)
  "Load the fixed trusted app-private INIT-FILE and start the local actor profile.
The caller is packaged startup code, never a JSON request. This is not the full
HTTP/CouchDB/RabbitMQ server personality. Component STOP hooks must handle partial
startup and bound cleanup; strict rollback retains any unconfirmed ownership."
  (when (or (star.edge.runtime:runtime-live-p) (star.edge.actors:current-actor-system))
    (error "Android service runtime is already active"))
  (setf *service-components* nil *service-workers* 1 *service-init-loaded-p* nil
        *service-stop-unconfirmed-p* nil)
  (let ((star.edge.runtime:*require-confirmed-shutdown* t)
        (star.edge.runtime:*redact-diagnostics* t)
        (star.edge.runtime:*diagnostic-failures* nil))
    (handler-case
      (progn
        (unless (and init-file (probe-file init-file))
          (error "Trusted init.lisp is missing"))
        (let ((*default-pathname-defaults* (uiop:pathname-directory-pathname init-file)))
          (load init-file :verbose nil :print nil))
        (unless (typep *service-workers* '(integer 1 4))
          (error "Invalid worker bound"))
        (unless (and (listp *service-components*)
                     (every (lambda (component)
                              (typep component 'star.edge.runtime::component))
                            *service-components*))
          (error "Invalid managed components"))
        (let* ((actors
                 (star.edge.runtime:make-component
                  "local-actors"
                  :start (lambda ()
                           (handler-case
                               (progn
                                 (star.edge.actors:start-actor-system :workers *service-workers*)
                                 (star.edge.actors:run-actors-start-hook))
                             (serious-condition ()
                               (star.edge.actors:stop-actor-system)
                               (error "Local actor startup failed"))))
                  :stop (lambda ()
                          (unless (star.edge.actors:stop-actor-system)
                            (error "actor-shutdown-unconfirmed")))))
               (runtime (star.edge.runtime:start-runtime
                         (cons actors (copy-list *service-components*)))))
          (unless (eq :running (star.edge.runtime:runtime-state runtime))
            (error "Managed runtime startup failed"))
          (setf *service-init-loaded-p* t)
          runtime))
    (serious-condition ()
      (stop-service-runtime)
      ;; Redact conditions: user init may contain private configuration details.
      (error "android-service-initialization-failed")))))

(defun stop-service-runtime ()
  "Release all components; retain unconfirmed ownership and report cleanup failure."
  (let ((star.edge.runtime:*require-confirmed-shutdown* t)
        (star.edge.runtime:*redact-diagnostics* t)
        (star.edge.runtime:*diagnostic-failures* nil)
        (confirmed nil))
    (unwind-protect
         (setf confirmed
               (star.edge.runtime:stop-runtime (star.edge.runtime:current-runtime)
                                              :reason :android-service-stop))
      (setf *service-init-loaded-p* nil)
      ;; Only partial startup without a live managed owner needs a fallback actor stop.
      (when (and (star.edge.actors:current-actor-system)
                 (not (star.edge.runtime:runtime-live-p)))
        (unless (star.edge.actors:stop-actor-system) (setf confirmed nil))))
    (let ((complete (and confirmed (null star.edge.runtime:*diagnostic-failures*)
                         (null (star.edge.actors:current-actor-system))
                         (not (star.edge.runtime:runtime-live-p)))))
      (setf *service-stop-unconfirmed-p* (not complete))
      complete)))

(defun service-status ()
  (list :status (if (service-ready-p) :ok :unavailable)
        :state (if *service-stop-unconfirmed-p* :stop-failed
                   (or (star.edge.runtime:runtime-state (star.edge.runtime:current-runtime)) :stopped))
        :profile :local-actors
        :init (if *service-init-loaded-p* :loaded :missing)
        :server-api :unavailable
        :mesh :not-integrated))
