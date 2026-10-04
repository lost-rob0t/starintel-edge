;;;; Separate CL-only operation/result correlation gate. No socket is opened.
;;;; Real Sento actors use the existing explicit synthetic-transport test double.
(require :asdf)
(asdf:load-asd (truename "runtime/starintel-edge.asd"))
(asdf:load-system "starintel-edge/mesh-sento")
(load "tests/mesh-sento.lisp")
(in-package #:star.edge.mesh)
(defun interop-expected-error (thunk message)
  (handler-case (progn (funcall thunk) nil)
    (simple-error (condition) (string= (princ-to-string condition) message))))

(let* ((system (sento.actor-system:make-actor-system
                '(:dispatchers (:shared (:workers 2)))))
       (calls 0)
       (server (sento.actor-context:actor-of
                system :name "star:v1:resolver:echo"
                :receive (make-mesh-receiver
                          (lambda (peer request)
                            (check (equal peer "peer-a"))
                            (incf calls)
                            (make-result :ok (request-payload request)))
                          (lambda (peer request)
                            (and (equal peer "peer-a")
                                 (not (equal "denied" (request-id request)))))
                          :clock (lambda () 1000))))
       (left (make-instance 'synthetic-transport :identity "peer-a"))
       (right (make-instance 'synthetic-transport :identity "peer-a"))
       (a (runtime left))
       (b (runtime right :dispatch
            (make-sento-dispatcher
             (lambda (name) (and (equal name "star:v1:resolver:echo") server))
             :clock (lambda () 1000))))
       ;; Raw octets: NUL, non-BMP emoji/music, accented Latin and CJK.
       ;; Mesh treats these as opaque bytes; metadata remains bounded ASCII.
       (payload (make-array 14 :element-type '(unsigned-byte 8)
                            :initial-contents '(0 240 159 153 130 240 157 132 158 195 169 228 184 173)))
       (requests (loop for id in '("first" "second" "third" "denied")
                       collect (request :id id :payload payload
                                        :correlation (concatenate 'string "parent-" id)
                                        :causation "cause" :trace "trace"
                                        :authorization-context "receipt"
                                        :idempotency-key (concatenate 'string "key-" id)))))
  (unwind-protect
       (progn
         (setf (receiver left) right (receiver right) left)
         (start-mesh a) (start-mesh b)
         (dolist (req requests) (check (eq :pending (submit-request a "peer-a" req))))
         ;; None of these plausible responses may settle the genuine pending call.
         (dolist (index '(1 3 4 5 6 7 8 9 10 11 12 13))
           (let ((frames (encode-message (first requests) (make-result :ok (bytes "spoof")))))
             (setf (nth index frames) (bytes (if (= index 9) "4999" "wrong")))
             (push (make-delivery :peer "peer-a" :frames frames) (inbox left))
             (step-mesh a)
             (check (null (take-result a "first")))))
         ;; A future protocol version is rejected before actor delivery.
         (let ((frames (encode-message (request :id "future" :payload payload))))
           (setf (second frames) (bytes "STARROUTER/2.0/edge-private-1"))
           (check (interop-expected-error (lambda () (decode-message frames 65536))
                                          "Unsupported protocol or required field"))
           (push (make-delivery :peer "peer-a" :frames frames) (inbox right)))
         (let ((deadline (+ (get-internal-real-time) (* 5 internal-time-units-per-second)))
               (remaining (copy-list requests)))
           (loop while remaining do
             (when (> (get-internal-real-time) deadline) (error "Real Sento integration timeout"))
             (step-mesh b) (step-mesh a)
             ;; Observe out of submission order; request IDs still select the right result.
             (dolist (req (reverse (copy-list remaining)))
               (let ((result (take-result a (request-id req))))
                 (when result
                   (if (equal "denied" (request-id req))
                       (progn (check (eq :forbidden (result-status result)))
                              (check (zerop (length (result-payload result)))))
                       (progn (check (eq :ok (result-status result)))
                              (check (equalp payload (result-payload result)))))
                   (setf remaining (remove req remaining)))))
             (sleep 0.005)))
         (check (= 3 calls))
         (check (zerop (getf (mesh-status a) :pending)))
         ;; Unicode/NUL metadata is not silently accepted as token identities.
         (dolist (id (list "🙂" (concatenate 'string "prefix" (string (code-char 0)) "suffix")))
           (check (interop-expected-error (lambda () (request :id id)) "Invalid actor request")))
         (format t "ACTOR_MESH_CHECKS~C~D~%" #\Tab *checks*))
    (stop-mesh a) (stop-mesh b)
    (sento.actor-context:shutdown system :wait t)))
