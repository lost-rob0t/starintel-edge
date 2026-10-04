(require :asdf)
(asdf:load-asd (truename "runtime/starintel-edge.asd"))
(asdf:load-system "starintel-edge/mesh-sento")
(load "tests/mesh.lisp")
(in-package #:star.edge.mesh)
(let* ((system (sento.actor-system:make-actor-system
                '(:dispatchers (:shared (:workers 2)) :timeout-timer (:resolution 100 :max-size 100))))
       (received-peer nil)
       (server (sento.actor-context:actor-of
                system :name "star:v1:resolver:echo"
                :receive (make-mesh-receiver
                          (lambda (peer request)
                            (setf received-peer peer)
                            (make-result :ok (request-payload request)))
                          (lambda (peer request) (declare (ignore request)) (equal peer "peer-a"))
                          :clock (lambda () 1000))))
       (client (sento.actor-context:actor-of system :name "star:v1:projector:client"
                :receive (lambda (value) (if (eq value :make-request) (request) value))))
       (left (make-instance 'synthetic-transport :identity "peer-a"))
       (right (make-instance 'synthetic-transport :identity "peer-a"))
       (a (runtime left))
       (b (runtime right :dispatch (make-sento-dispatcher
                                    (lambda (name) (and (equal name "star:v1:resolver:echo") server))
                                    :clock (lambda () 1000)))))
  (unwind-protect
       (progn
         (setf (receiver left) right (receiver right) left)
         (start-mesh a) (start-mesh b)
         ;; Real sending Sento actor -> owner-serialized synthetic wire -> real receiving actor.
         (let ((req (sento.actor:ask-s client :make-request :time-out 1)))
           (check (eq :pending (submit-request a "peer-a" req)))
           (let ((deadline (+ (get-internal-real-time) (* 3 internal-time-units-per-second))) (result nil))
             (loop until (setf result (take-result a (request-id req)))
                   do (when (> (get-internal-real-time) deadline) (error "Sento result timeout"))
                      (step-mesh b) (step-mesh a) (sleep 0.005))
             (check (eq :ok (result-status result)))
             (check (equalp (bytes "opaque") (sento.actor:ask-s client (result-payload result) :time-out 1)))
             (check (equal received-peer "peer-a"))))
         (let ((called nil)
               (receive (make-mesh-receiver (lambda (&rest ignored) (declare (ignore ignored))
                                              (error "Must never dispatch expired work"))
                                            (lambda (&rest ignored) (declare (ignore ignored)) t)
                                            :clock (lambda () 5001))))
           (declare (ignore called))
           (check (eq :deadline-exceeded
                      (result-status (funcall receive (make-actor-invocation "peer-a" (request))))))))
    (stop-mesh a) (stop-mesh b)
    (sento.actor-context:shutdown system :wait t)))
(format t "~D checks including real local Sento actor roundtrip over synthetic transport. No ZeroMQ/Android claim.~%" *checks*)
