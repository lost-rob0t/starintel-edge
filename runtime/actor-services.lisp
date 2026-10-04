;;;; Named actor services over the process-owned Sento actor system.

(in-package #:star.edge.actors)

(defstruct (actor-service (:constructor %make-actor-service))
  name start stop (state :stopped) handle)

(defvar *actor-services* (make-hash-table :test #'equal))
(defvar *actor-services-lock*
  (bordeaux-threads:make-lock "star-edge-actor-services"))

(defun valid-actor-service-name-p (name)
  (and (stringp name)
       (plusp (length name))
       (every (lambda (character)
                (or (lower-case-p character)
                    (digit-char-p character)
                    (member character '(#\. #\-))))
              name)))

(defun actor-handle-running-p (service)
  (and (actor-service-handle service)
       (handler-case
           (sento.actor-cell:running-p (actor-service-handle service))
         (error () nil))))

(defun actor-service-live-p (service)
  (and (eq :running (actor-service-state service))
       (actor-handle-running-p service)))

(defun refresh-actor-service-state (service)
  (when (and (eq :running (actor-service-state service))
             (not (actor-service-live-p service)))
    (when *actor-index-agent*
      (unregister-actor (actor-service-name service)))
    (setf (actor-service-state service) :stopped
          (actor-service-handle service) nil))
  service)

(defun actor-service-record (service)
  (refresh-actor-service-state service)
  (list :name (actor-service-name service)
        :state (actor-service-state service)))

(defun register-actor-service (name start &key stop)
  "Register a named service lifecycle owned by the current Sento actor system.

START receives the start request and must return the root actor. STOP, when
supplied, receives that actor and the stop request for package-specific cleanup.
The root actor is always stopped through Sento. A stopped definition may be
replaced; a live one may not."
  (unless (valid-actor-service-name-p name)
    (error "Invalid actor service name: ~S" name))
  (unless (functionp start)
    (error "Actor service start must be a function"))
  (unless (or (null stop) (functionp stop))
    (error "Actor service stop must be a function or NIL"))
  (bordeaux-threads:with-lock-held (*actor-services-lock*)
    (let ((existing (gethash name *actor-services*)))
      (when (and existing
                 (eq :running
                     (actor-service-state
                      (refresh-actor-service-state existing))))
        (error "Actor service ~A is running" name))
      (setf (gethash name *actor-services*)
            (%make-actor-service :name name :start start :stop stop))))
  name)

(defun register-sento-actor-service (name receive)
  "Register a one-actor Sento service with message handler RECEIVE."
  (unless (functionp receive)
    (error "Actor service receive must be a function"))
  (register-actor-service
   name
   (lambda (request)
     (declare (ignore request))
     (actor-of :name name :receive receive))))

(defun unregister-actor-service (name)
  "Remove a stopped service definition. Running services must be stopped first."
  (bordeaux-threads:with-lock-held (*actor-services-lock*)
    (let ((service (gethash name *actor-services*)))
      (when (and service
                 (eq :running
                     (actor-service-state
                      (refresh-actor-service-state service))))
        (error "Actor service ~A is running" name))
      (remhash name *actor-services*))))

(defun list-actor-services ()
  "Return stable status records for installed actor services."
  (bordeaux-threads:with-lock-held (*actor-services-lock*)
    (sort (loop for service being the hash-values of *actor-services*
                collect (actor-service-record service))
          #'string< :key (lambda (record) (getf record :name)))))

(defun actor-service-request-name (request)
  (let ((name (and (listp request) (getf request :name))))
    (unless (valid-actor-service-name-p name)
      (error "Actor service request requires a valid :NAME"))
    name))

(defun start-actor-service (service request)
  (unless *actor-system*
    (error "Edge actor system is not running"))
  (refresh-actor-service-state service)
  (unless (eq :running (actor-service-state service))
    (setf (actor-service-state service) :starting)
    (let (actor)
      (handler-case
          (progn
            (setf actor (funcall (actor-service-start service) request))
            (unless (and actor
                         (handler-case
                             (sento.actor-cell:running-p actor)
                           (error () nil)))
              (error "Actor service ~A returned no running root actor"
                     (actor-service-name service)))
            (register-actor (actor-service-name service) actor)
            (setf (actor-service-handle service) actor
                  (actor-service-state service) :running))
        (error (condition)
          (when actor
            (ignore-errors
              (sento.actor-context:stop *actor-system* actor :wait t))
            (when *actor-index-agent*
              (ignore-errors
                (unregister-actor (actor-service-name service)))))
          (setf (actor-service-handle service) nil
                (actor-service-state service) :failed)
          (error condition)))))
  (actor-service-record service))

(defun stop-actor-service (service request)
  (refresh-actor-service-state service)
  (when (eq :running (actor-service-state service))
    (setf (actor-service-state service) :stopping)
    (handler-case
        (progn
          (when (actor-service-stop service)
            (funcall (actor-service-stop service)
                     (actor-service-handle service) request))
          (sento.actor-context:stop *actor-system*
                                    (actor-service-handle service)
                                    :wait t)
          (when *actor-index-agent*
            (unregister-actor (actor-service-name service)))
          (setf (actor-service-handle service) nil
                (actor-service-state service) :stopped))
      (error (condition)
        (setf (actor-service-state service)
              (if (actor-handle-running-p service) :running :failed))
        (error condition))))
  (actor-service-record service))

(defun dispatch-actor-service (operation request)
  "Dispatch :START, :STOP, or :STATUS for the named installed service."
  (let ((name (actor-service-request-name request)))
    (bordeaux-threads:with-lock-held (*actor-services-lock*)
      (let ((service (gethash name *actor-services*)))
        (unless service
          (return-from dispatch-actor-service
            (list :name name :state :unavailable
                  :reason :actor-service-not-installed)))
        (ecase operation
          (:start (start-actor-service service request))
          (:stop (stop-actor-service service request))
          (:status (actor-service-record service)))))))

(defun make-actor-service-dispatcher ()
  "Return the port expected by INSTALL-STANDARD-CAPABILITIES."
  #'dispatch-actor-service)

(defun mark-actor-services-stopped ()
  (bordeaux-threads:with-lock-held (*actor-services-lock*)
    (loop for service being the hash-values of *actor-services*
          do (setf (actor-service-state service) :stopped
                   (actor-service-handle service) nil))))
