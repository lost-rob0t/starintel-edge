(load "tests/mesh-sento.lisp")
(in-package #:star.edge.mesh)
(defun wait-sento (predicate)
  (let ((deadline (+ (get-internal-real-time) (* 2 internal-time-units-per-second))))
    (loop until (funcall predicate) do
      (when (> (get-internal-real-time) deadline) (error "Sento security test timeout")) (sleep 0.005))))
(let* ((system (sento.actor-system:make-actor-system '(:dispatchers (:shared (:workers 2)))))
       (lock (bordeaux-threads:make-lock "queued-policy"))
       (entered nil) (release nil) (allowed t) (handled 0) (observed-peer nil)
       (receive (make-mesh-receiver
                 (lambda (peer req) (declare (ignore peer req)) (incf handled) (make-result :ok))
                 (lambda (peer req) (declare (ignore req)) (setf observed-peer peer)
                   (bordeaux-threads:with-lock-held (lock) allowed)) :clock (lambda () 1000)))
       (actor (sento.actor-context:actor-of system :name "queued-auth"
                :receive (lambda (msg)
                           (if (eq msg :block)
                               (progn (bordeaux-threads:with-lock-held (lock) (setf entered t))
                                      (loop until (bordeaux-threads:with-lock-held (lock) release) do (sleep 0.005)))
                               (funcall receive msg)))))
       (dispatcher (make-sento-dispatcher (lambda (name) (declare (ignore name)) actor) :clock (lambda () 1000))))
  (unwind-protect
       (progn
         (sento.actor:tell actor :block)
         (wait-sento (lambda () (bordeaux-threads:with-lock-held (lock) entered)))
         (let ((poll (funcall dispatcher "authenticated-peer-a" (request))) (result nil))
           (check (null (funcall poll)))
           (bordeaux-threads:with-lock-held (lock) (setf allowed nil release t))
           (wait-sento (lambda () (setf result (funcall poll))))
           (check (eq :forbidden (result-status result)))
           (check (equal "authenticated-peer-a" observed-peer))
           (check (zerop handled)))
         ;; The handler error is caught before Sento can log its condition. Its
         ;; default result log sees only the mesh result's redacted printer.
         (let* ((failing (sento.actor-context:actor-of system :name "secret-handler"
                           :receive (make-mesh-receiver
                                     (lambda (peer req) (declare (ignore peer req)) (error "MESH-SECRET-MARKER"))
                                     (lambda (&rest args) (declare (ignore args)) t) :clock (lambda () 1000))))
                (poll (funcall (make-sento-dispatcher (lambda (name) (declare (ignore name)) failing)
                                                     :clock (lambda () 1000))
                               "authenticated-peer-a" (request :payload (bytes "MESH-SECRET-MARKER"))))
                (result nil))
           (wait-sento (lambda () (setf result (funcall poll))))
           (check (eq :outcome-unknown (result-status result)))
           (check (zerop (length (result-payload result))))
           (check (not (search "MESH-SECRET-MARKER" (write-to-string result))))))
    (bordeaux-threads:with-lock-held (lock) (setf release t))
    (sento.actor-context:shutdown system :wait t)))

(let* ((system (sento.actor-system:make-actor-system '(:dispatchers (:shared (:workers 1)))))
       (actor (sento.actor-context:actor-of system :name "invalid-secret-result"
                :receive (make-mesh-receiver
                          (lambda (&rest args) (declare (ignore args)) "MESH-SECRET-MARKER")
                          (lambda (&rest args) (declare (ignore args)) t) :clock (lambda () 1000))))
       (poll (funcall (make-sento-dispatcher (lambda (name) (declare (ignore name)) actor)
                                           :clock (lambda () 1000)) "peer-a" (request)))
       (result nil))
  (unwind-protect
       (progn
         (wait-sento (lambda () (setf result (funcall poll))))
         (check (eq :protocol-error (result-status result)))
         (check (zerop (length (result-payload result)))))
    (sento.actor-context:shutdown system :wait t)))

;; Rejected futures can mean admission already occurred. Keep the slot unsettled.
(let ((ask (symbol-function 'sento.actor:ask)) (done (symbol-function 'sento.future:complete-p))
      (errorp (symbol-function 'sento.future:error-p)) (value (symbol-function 'sento.future:fresult)))
  (unwind-protect
       (progn
         (setf (symbol-function 'sento.actor:ask) (lambda (&rest args) (declare (ignore args)) :test-future)
               (symbol-function 'sento.future:complete-p) (lambda (future) (declare (ignore future)) t)
               (symbol-function 'sento.future:error-p) (lambda (future) (declare (ignore future)) t)
               (symbol-function 'sento.future:fresult) (lambda (future) (declare (ignore future)) "MESH-SECRET-MARKER"))
         (let ((poll (funcall (make-sento-dispatcher (lambda (name) (declare (ignore name)) :actor)
                                                   :clock (lambda () 1000)) "peer-a" (request))))
           (multiple-value-bind (result disposition) (funcall poll)
             (check (eq :outcome-unknown (result-status result))) (check (eq :unsettled disposition))
             (check (zerop (length (result-payload result)))))))
    (setf (symbol-function 'sento.actor:ask) ask (symbol-function 'sento.future:complete-p) done
          (symbol-function 'sento.future:error-p) errorp (symbol-function 'sento.future:fresult) value)))
(format t "~D checks including queued peer revocation and default Sento error/result redaction.~%" *checks*)
