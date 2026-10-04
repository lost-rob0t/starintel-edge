(in-package #:star.edge.mesh)

;; One managed transport thread, owned by the existing Edge component lifecycle.
;; No actor supervisor, durable queue, remote code loader or independent service.
(defstruct (mesh-component-handle (:constructor %make-mesh-component-handle))
  mesh thread (lock (bordeaux-threads:make-lock "edge-mesh-owner"))
  (changed (bordeaux-threads:make-condition-variable))
  (state :stopped) stop queue (tickets (make-hash-table :test #'equal)))
(defstruct (mesh-ticket (:constructor %make-mesh-ticket)) id peer request result)

(defun mesh-component-status (handle)
  (bordeaux-threads:with-lock-held ((mesh-component-handle-lock handle))
    (list :state (mesh-component-handle-state handle) :mode :private :public-swarm nil
          :tickets (hash-table-count (mesh-component-handle-tickets handle)))))
(defun component-stopping-p (handle)
  (bordeaux-threads:with-lock-held ((mesh-component-handle-lock handle))
    (mesh-component-handle-stop handle)))
(defun publish-ticket-result (handle ticket result)
  (bordeaux-threads:with-lock-held ((mesh-component-handle-lock handle))
    (unless (mesh-ticket-result ticket) (setf (mesh-ticket-result ticket) result))))
(defun run-mesh-owner (handle)
  (let ((mesh (mesh-component-handle-mesh handle)) (active nil) (failed nil))
    (unwind-protect
         (handler-case
             (progn
               (unless (eq :running (getf (start-mesh mesh) :state)) (error "Mesh startup unavailable"))
               (bordeaux-threads:with-lock-held ((mesh-component-handle-lock handle))
                 (when (mesh-component-handle-stop handle) (error "Mesh startup cancelled"))
                 (setf (mesh-component-handle-state handle) :running)
                 (bordeaux-threads:condition-notify (mesh-component-handle-changed handle)))
               (loop until (component-stopping-p handle) do
                 (let ((commands
                         (bordeaux-threads:with-lock-held ((mesh-component-handle-lock handle))
                           (prog1 (mesh-component-handle-queue handle)
                             (setf (mesh-component-handle-queue handle) nil)))))
                   (dolist (ticket commands)
                     (if (component-stopping-p handle)
                         (publish-ticket-result handle ticket (make-result :dependency-unavailable))
                         (let ((result (submit-request mesh (mesh-ticket-peer ticket) (mesh-ticket-request ticket))))
                           (if (eq result :pending) (push ticket active)
                               (publish-ticket-result handle ticket result)))))
                   (step-mesh mesh)
                   (setf active
                         (remove-if
                          (lambda (ticket)
                            (let ((result (take-result mesh (mesh-ticket-id ticket))))
                              (when result (publish-ticket-result handle ticket result) t))) active))
                   (unless (eq :running (getf (mesh-status mesh) :state)) (error "Mesh owner unavailable")))
                 (sleep 0.01)))
           (error () (setf failed t)))
      ;; Only this owner touches transport shutdown. Never wait for actor completion.
      (handler-case (stop-mesh mesh) (error () (setf failed t)))
      (dolist (ticket active)
        (publish-ticket-result handle ticket (or (take-result mesh (mesh-ticket-id ticket))
                                                (make-result :outcome-unknown))))
      (bordeaux-threads:with-lock-held ((mesh-component-handle-lock handle))
        (maphash (lambda (id ticket)
                   (unless (mesh-ticket-result ticket)
                     (setf (mesh-ticket-result ticket)
                           (or (take-result mesh id) (make-result :dependency-unavailable)))))
                 (mesh-component-handle-tickets handle))
        (setf (mesh-component-handle-queue handle) nil
              (mesh-component-handle-state handle) (if failed :unavailable :stopped))
        (bordeaux-threads:condition-notify (mesh-component-handle-changed handle))))))

(defun start-mesh-component (handle timeout)
  (bordeaux-threads:with-lock-held ((mesh-component-handle-lock handle))
    (when (and (mesh-component-handle-thread handle)
               (bordeaux-threads:thread-alive-p (mesh-component-handle-thread handle)))
      (error "Mesh owner is already alive"))
    (setf (mesh-component-handle-state handle) :starting (mesh-component-handle-stop handle) nil)
    (setf (mesh-component-handle-thread handle)
          (bordeaux-threads:make-thread (lambda () (run-mesh-owner handle)) :name "star-edge-private-mesh"))
    (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
      (loop while (eq (mesh-component-handle-state handle) :starting) do
        (when (>= (get-internal-real-time) deadline)
          (setf (mesh-component-handle-stop handle) t)
          (error "Mesh owner startup timed out"))
        (bordeaux-threads:condition-wait (mesh-component-handle-changed handle)
                                        (mesh-component-handle-lock handle) :timeout 0.1)))
    (unless (eq (mesh-component-handle-state handle) :running) (error "Private mesh prerequisites unavailable")))
  t)
(defun stop-mesh-component (handle timeout)
  (let ((thread nil))
    (bordeaux-threads:with-lock-held ((mesh-component-handle-lock handle))
      (setf (mesh-component-handle-stop handle) t thread (mesh-component-handle-thread handle))
      (when (eq (mesh-component-handle-state handle) :running)
        (setf (mesh-component-handle-state handle) :stopping)))
    (when thread
      (when (eq thread (bordeaux-threads:current-thread)) (error "Owner cannot join itself"))
      (bordeaux-threads:with-timeout (timeout) (bordeaux-threads:join-thread thread))))
  t)
(defun make-mesh-component (mesh &key (timeout-seconds 5))
  "Return (values existing-edge-component handle). Add after the actor component.
Start/stop run on the host lifecycle thread; only the owned thread opens, ticks or
closes transport. Missing native/auth/budget prerequisites fail component startup.
Ticket submission is bounded and safe from other threads, including Sento actors."
  (unless (and (mesh-p mesh) (realp timeout-seconds) (<= 0.1 timeout-seconds 30))
    (error "Invalid mesh component"))
  (let ((handle (%make-mesh-component-handle :mesh mesh)))
    (values (star.edge.runtime:make-component
             :private-mesh
             :start (lambda ()
                      (unless star.edge.runtime:*require-confirmed-shutdown*
                        (error "Mesh component requires confirmed-shutdown lifecycle policy"))
                      (start-mesh-component handle timeout-seconds))
             :stop (lambda () (stop-mesh-component handle timeout-seconds))) handle)))
(defun submit-to-mesh (handle peer request)
  "Return a bounded ticket or terminal RESULT. Never access libzmq from caller threads."
  (let* ((mesh (mesh-component-handle-mesh handle)) (config (mesh-config mesh))
         (frozen (decode-message (encode-message request) (config-max-message-bytes config))))
    (bordeaux-threads:with-lock-held ((mesh-component-handle-lock handle))
      (cond
        ((or (mesh-component-handle-stop handle)
             (not (eq :running (mesh-component-handle-state handle)))) (make-result :dependency-unavailable))
        ((gethash (request-id frozen) (mesh-component-handle-tickets handle)) (make-result :conflict))
        ((>= (hash-table-count (mesh-component-handle-tickets handle)) (config-max-pending config)) (make-result :overloaded))
        (t
         (let ((ticket (%make-mesh-ticket :id (request-id frozen) :peer (copy-seq peer) :request frozen)))
           (setf (gethash (request-id frozen) (mesh-component-handle-tickets handle)) ticket
                 (mesh-component-handle-queue handle) (nconc (mesh-component-handle-queue handle) (list ticket)))
           ticket))))))
(defun take-mesh-result (handle ticket)
  (bordeaux-threads:with-lock-held ((mesh-component-handle-lock handle))
    (when (and (mesh-ticket-p ticket)
               (eq ticket (gethash (mesh-ticket-id ticket) (mesh-component-handle-tickets handle)))
               (mesh-ticket-result ticket))
      (remhash (mesh-ticket-id ticket) (mesh-component-handle-tickets handle))
      (mesh-ticket-result ticket))))
