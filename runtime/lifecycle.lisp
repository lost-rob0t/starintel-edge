;;;; Managed edge runtime lifecycle.
;;;; Adapted from the star.runtime layer of starintel-server@f8e20c0b
;;;; source/runtime-lifecycle.lisp (GPL-3.0-or-later, Copyright (C) 2024
;;;; nsaspy). Server-only subsystems (HTTP API, Rabbit consumers, CouchDB,
;;;; lparallel kernel, lease store) are replaced by a generic managed
;;;; component list; start rollback and dependency-safe idempotent stop
;;;; semantics are preserved.

(in-package #:star.edge.runtime)

(defparameter *shutdown-timeout-seconds* 5)

(defvar *runtime* nil)
(defvar *signal-stop-requested* nil)
(defvar *signal-handlers-installed-p* nil)
(defvar *runtime-lock* (bordeaux-threads:make-lock "star-edge-runtime"))

(defstruct (component
             (:constructor make-component (name &key start stop)))
  name
  start
  stop)

(defstruct (edge-runtime
             (:constructor %make-runtime
                 (&key components (state :created) started-at
                       (lock (bordeaux-threads:make-lock "edge-runtime")))))
  components
  state
  started-at
  stop-reason
  lock)

(defun current-runtime () *runtime*)

(defun runtime-state (runtime)
  (and runtime (edge-runtime-state runtime)))

(defun runtime-stop-reason (runtime)
  (and runtime (edge-runtime-stop-reason runtime)))

(defun runtime-live-p (&optional (runtime *runtime*))
  (and runtime
       (member (edge-runtime-state runtime)
               '(:starting :running :stopping)
               :test #'eq)
       t))

(defun runtime-mark-stopping (runtime reason)
  (bordeaux-threads:with-lock-held ((edge-runtime-lock runtime))
    (case (edge-runtime-state runtime)
      ((:stopped :stopping) nil)
      (otherwise
       (setf (edge-runtime-state runtime) :stopping
             (edge-runtime-stop-reason runtime) reason)
       t))))

(defun stop-component (component)
  "Stop one component; stop failures never abort the teardown of others."
  (when (component-stop component)
    (handler-case
        (funcall (component-stop component))
      (error (condition)
        (warn "Edge component ~a stop failed: ~a"
              (component-name component) condition)))))

(defun stop-runtime (&optional (runtime *runtime*) &key (reason :explicit-stop))
  "Stop one edge runtime in dependency-safe (reverse start) order. Idempotent."
  (when (null runtime)
    (return-from stop-runtime t))
  (unless (runtime-mark-stopping runtime reason)
    (return-from stop-runtime
      (eq :stopped (edge-runtime-state runtime))))
  (dolist (component (reverse (edge-runtime-components runtime)))
    (stop-component component))
  (bordeaux-threads:with-lock-held ((edge-runtime-lock runtime))
    (setf (edge-runtime-state runtime) :stopped))
  (when (eq runtime *runtime*)
    (bordeaux-threads:with-lock-held (*runtime-lock*)
      (setf *runtime* nil)))
  t)

(defun start-runtime (components)
  "Start the edge runtime with COMPONENTS in order, rolling back on partial
failure. Component failures do not signal: the runtime returns stopped with
stop reason :startup-failure. Starting while another runtime is active signals."
  (bordeaux-threads:with-lock-held (*runtime-lock*)
    (when (and *runtime*
               (not (eq :stopped (edge-runtime-state *runtime*))))
      (error "Edge runtime is already active"))
    (let ((runtime (%make-runtime :components (copy-list components)
                                  :state :starting
                                  :started-at (get-universal-time)))
          (started nil))
      (setf *runtime* runtime *signal-stop-requested* nil)
      (flet ((rollback ()
               (setf (edge-runtime-stop-reason runtime) :startup-failure)
               (dolist (component (reverse started))
                 (stop-component component))
               (setf (edge-runtime-state runtime) :stopped)))
        (dolist (component components)
          (handler-case
              (progn
                (funcall (component-start component))
                (push component started))
            (error (condition)
              (warn "Edge component ~a failed to start: ~a"
                    (component-name component) condition)
              (rollback)
              (return-from start-runtime runtime))))
        (bordeaux-threads:with-lock-held ((edge-runtime-lock runtime))
          (setf (edge-runtime-state runtime) :running))
        runtime))))

(defun request-stop (reason)
  "Record a stop request with REASON, e.g. from a signal handler."
  (setf *signal-stop-requested* reason)
  reason)

(defun run-until-stopped (&optional (runtime *runtime*))
  "Keep the owning thread alive until an explicit/signal stop is requested."
  (unless runtime (error "No edge runtime to run"))
  (loop while (member (edge-runtime-state runtime) '(:starting :running) :test #'eq)
        do (when *signal-stop-requested*
             (let ((reason *signal-stop-requested*))
               (setf *signal-stop-requested* nil)
               (stop-runtime runtime :reason reason)))
           (sleep 0.1))
  runtime)

(defun install-signal-handlers ()
  "Install SIGTERM/SIGINT handlers that request a graceful stop."
  (unless *signal-handlers-installed-p*
    #+sbcl
    (progn
      (sb-sys:enable-interrupt
       sb-unix:sigterm
       (lambda (&rest ignored)
         (declare (ignore ignored))
         (request-stop :sigterm)))
      (sb-sys:enable-interrupt
       sb-unix:sigint
       (lambda (&rest ignored)
         (declare (ignore ignored))
         (request-stop :sigint))))
    (setf *signal-handlers-installed-p* t))
  t)
