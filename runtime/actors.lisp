;;;; Edge actor runtime on Sento.
;;;; Adapted from starintel-server@f8e20c0b source/actors.lisp
;;;; (GPL-3.0-or-later, Copyright (C) 2024 nsaspy). The CouchDB/RabbitMQ
;;;; storage and transport actors are server-only and are not carried over;
;;;; the pinned-agent fail-fast publish pattern is preserved over an
;;;; injected sink port.

(in-package #:star.edge.actors)

(defvar *actor-system* nil "The edge actor system.")

(defvar *actors-start-hook* nil
  "Functions to run after the actor system and index are started.
Replaces the server's nhooks-backed hook with a plain list.")

(defun add-actors-start-hook (fn)
  "Register FN to run on every actor runtime start."
  (pushnew fn *actors-start-hook*))

(defun run-actors-start-hook ()
  (dolist (fn *actors-start-hook*) (funcall fn)))

(defun start-actor-system (&key (workers 2))
  "Start the edge actor system with a pinned dispatcher of WORKERS threads."
  (when *actor-system*
    (error "Edge actor system is already running"))
  (setf *actor-system*
        (sento.actor-system:make-actor-system
         `(:dispatchers (:pinned (:workers ,workers :strategy :random))
           :timeout-timer (:resolution 500 :max-size 1000)
           :eventstream (:dispatcher-id :shared)
           :scheduler (:enabled :true :resolution 100 :max-size 500))))
  (start-actor-index *actor-system*)
  *actor-system*)

(defun current-actor-system ()
  (or *actor-system*))

(defun stop-actor-system (&key (timeout-seconds 5))
  "Stop process-owned actor resources without touching unrelated threads."
  (when *actor-system*
    (handler-case
        (bordeaux-threads:with-timeout (timeout-seconds)
          (sento.actor-context:shutdown *actor-system* :wait t))
      (error (condition)
        (warn "Edge actor system shutdown failed: ~a" condition)))
    (setf *actor-system* nil
          *actor-index-agent* nil
          *publisher-agent* nil))
  t)

(defun actor-of (&key name receive)
  "Create an actor on the current edge actor system."
  (unless *actor-system* (error "Edge actor system is not running"))
  (sento.actor-context:actor-of *actor-system* :name name :receive receive))

;;;; Actor index: actors must register here before receiving targets.
;;;; Adapted from starintel-server source/actors.lisp target routing.

(defvar *actor-index-agent* nil
  "Agent holding a hash-table of registered actor names to actors.")

(defun start-actor-index (system)
  (declare (ignore system))
  (setf *actor-index-agent*
        (sento.agent:make-agent (lambda () (make-hash-table :test #'equal))
                                *actor-system*
                                :pinned)))

(defun register-actor (actor-name actor)
  "Register ACTOR under ACTOR-NAME in the actor index."
  (unless *actor-index-agent* (error "Actor index is not running"))
  (sento.agent:agent-update *actor-index-agent*
                            (lambda (index)
                              (setf (gethash actor-name index) actor)
                              index)))

(defun get-dest-actor (actor-name)
  "Resolve the registered actor for ACTOR-NAME, or NIL."
  (when *actor-index-agent*
    (sento.agent:agent-get *actor-index-agent*
                           (lambda (index) (gethash actor-name index)))))

(defun route-target (target actor-name)
  "Send TARGET to the actor registered under ACTOR-NAME; unregistered names are dropped."
  (let ((dest (get-dest-actor actor-name)))
    (when dest
      (sento.actor:tell dest target))))

;;;; define-actor: declare an actor and its start function, registered
;;;; into the start hook. Adapted from the server macro; system global
;;;; replaces the per-system argument.

(defmacro define-actor ((name) &body body)
  "Define an actor message handler registered under NAME on start."
  (let ((start-fn-name (intern (format nil "START-~A"
                                       (string-upcase
                                        (remove #\* (symbol-name name)))))))
    `(progn
       (defvar ,name nil)
       (defun ,start-fn-name ()
         (setf ,name (actor-of :name ,(symbol-name name)
                               :receive ,(car body))))
       (add-actors-start-hook #',start-fn-name))))

;;;; Publisher: bounded fail-fast publish through a pinned agent.
;;;; The sink port is injected; RabbitMQ remains a server-only transport.

(defvar *publisher-agent* nil
  "Sento agent pinning the publish sink to one thread.")

(defparameter *publish-timeout-seconds* 5
  "Maximum time for a publish before failing fast instead of blocking callers.")

(defun start-publisher (sink)
  "Start the publisher pinning SINK (function of one message) to its own thread."
  (unless *actor-system* (error "Edge actor system is not running"))
  (setf *publisher-agent*
        (sento.agent:make-agent (lambda () sink) *actor-system* :pinned)))

(defun stop-publisher ()
  (setf *publisher-agent* nil)
  t)

(defun publish (message &key (timeout-seconds *publish-timeout-seconds*))
  "Publish MESSAGE through the pinned sink, failing fast on timeout or missing publisher."
  (assert *publisher-agent* () "publish: publisher is not started")
  (handler-case
      (bordeaux-threads:with-timeout (timeout-seconds)
        (sento.agent:agent-get *publisher-agent*
                               (lambda (sink) (funcall sink message))))
    (bordeaux-threads:timeout (condition)
      (declare (ignore condition))
      (error "publish: timed out after ~ds" timeout-seconds))))
