(in-package #:star.edge.mesh)

(defstruct (actor-invocation (:constructor make-actor-invocation (peer request))) peer request)

(defun make-sento-dispatcher (resolver &key (clock #'unix-milliseconds))
  "Reuse the application's existing Sento registry (e.g. star.actors:get-dest-actor).
RESOLVER returns an already running managed actor. No new supervisor or registry.
The receive function gets the trusted ACTOR-INVOCATION and must return a RESULT. Socket-owner
polling never blocks waiting for a reply and never runs on an actor dispatcher."
  (unless (and (functionp resolver) (functionp clock)) (error "Invalid Sento ports"))
  (lambda (peer request)
    (let ((actor (funcall resolver (request-destination request))))
      (if (null actor)
          (lambda () (make-result :not-found))
          (let ((remaining (- (request-deadline request) (funcall clock))))
            (if (not (plusp remaining))
                (lambda () (make-result :deadline-exceeded))
                (let ((future ;; An ask timeout stops only Sento's waiter, NOT the actor work.
                               ;; Keep the future until actual completion so the mesh admission
                               ;; slot remains charged even when the caller deadline expires.
                               (sento.actor:ask actor (make-actor-invocation peer request))))
                  (lambda ()
                    (when (sento.future:complete-p future)
                      (let ((value (sento.future:fresult future)))
                        (cond
                          ((sento.future:error-p future)
                           ;; Submission may have queued work before its dispatcher failed.
                           ;; No completion proof: retain the charged admission slot.
                           (values (make-result :outcome-unknown) :unsettled))
                          ((and (consp value) (eq (car value) :handler-error))
                           (make-result :outcome-unknown))
                          ((result-p value) value)
                          (t (make-result :protocol-error)))))))))))))

(defun make-mesh-receiver (handler authorize &key (clock #'unix-milliseconds))
  "Wrap an actor receive function: recheck time/policy on its own mailbox.
HANDLER and AUTHORIZE take (authenticated-peer-id request). HANDLER returns RESULT
and must repeat authorization at any later privileged effect. Peer identity is
transport-owned metadata, never taken from a claimed envelope field."
  (unless (and (functionp handler) (functionp authorize) (functionp clock))
    (error "Invalid actor receive ports"))
  (lambda (invocation)
    (let ((result
            (handler-case
                (if (not (actor-invocation-p invocation))
                    (make-result :invalid)
                    (let ((request (actor-invocation-request invocation)) (peer (actor-invocation-peer invocation)))
                      (cond
                        ((not (request-p request)) (make-result :invalid))
                        ((<= (request-deadline request) (funcall clock)) (make-result :deadline-exceeded))
                        ((not (eq t (funcall authorize peer request))) (make-result :forbidden))
                        (t (funcall handler peer request)))))
              (error () (make-result :outcome-unknown)))))
      ;; Reject invalid handler return values before the underlying actor library
      ;; can log them as raw results. Only the payload-redacting RESULT crosses back.
      (unless (result-p result) (setf result (make-result :protocol-error)))
      ;; Sento async ASK uses an explicit waiter actor; return values alone are
      ;; observed only by ASK-S. Reply after the receive function actually finishes.
      (when sento.actor:*sender* (sento.actor:tell sento.actor:*sender* result))
      result)))
