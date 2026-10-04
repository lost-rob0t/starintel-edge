;;;; REAL TCP/CURVE/ZAP acceptance test. Run only on an authorized socket-capable
;;;; 64-bit SBCL/Linux host with existing finite RLIMIT_AS soft AND hard bounds.
;;;; No secrets, enrollment, or key files are persisted. No external endpoints.
(require :asdf)
(asdf:load-asd (truename "runtime/starintel-edge.asd"))
(asdf:load-system "starintel-edge/mesh-zmq")
(asdf:load-system "starintel-edge/mesh-sento")
(in-package #:star.edge.mesh)
(unless (equal "1" (uiop:getenv "EDGE_RUN_ZMQ_LOOPBACK"))
  (error "Explicit EDGE_RUN_ZMQ_LOOPBACK=1 required; this is not a synthetic test"))
(unless (verify-linux-process-memory-limit)
  (error "Existing native process containment is absent/unsupported; test did not open sockets"))
(cffi:use-foreign-library edge-libzmq)
(defun ephemeral-curve-keypair ()
  (cffi:with-foreign-objects ((public :char 41) (secret :char 41) (decoded :unsigned-char 32))
    (unwind-protect
         (progn
           (zmq-check (cffi:foreign-funcall "zmq_curve_keypair" :pointer public :pointer secret :int))
           (let ((result nil))
             (dolist (pair (list (cons :public-key public) (cons :secret-key secret)))
               (when (cffi:null-pointer-p
                      (cffi:foreign-funcall "zmq_z85_decode" :pointer decoded :pointer (cdr pair) :pointer))
                 (error "Invalid ephemeral key encoding"))
               (let ((key (make-array 32 :element-type '(unsigned-byte 8))))
                 (dotimes (i 32) (setf (aref key i) (cffi:mem-aref decoded :unsigned-char i)))
                 (setf (getf result (car pair)) key))) result))
      (dotimes (i 41) (setf (cffi:mem-aref secret :unsigned-char i) 0))
      (dotimes (i 32) (setf (cffi:mem-aref decoded :unsigned-char i) 0)))))
(defun native-test-config (node port peer peer-port key-ref)
  (make-config :node-id node :bind-endpoint (format nil "tcp://127.0.0.1:~D" port)
               :credential-reference node
               :peers (list (make-peer :id peer :endpoint (format nil "tcp://127.0.0.1:~D" peer-port)
                                      :key-reference key-ref :callers '("star:v1:projector:client")
                                      :actors '("star:v1:resolver:echo")))
               :operations (list (make-operation :name "star.edge.echo" :retry-safe t))))
(defun tick-peers (peers seconds)
  (let ((end (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (loop while (< (get-internal-real-time) end) do (mapc #'step-mesh peers) (sleep 0.005))))
(let* ((keys (list (cons "node-a" (ephemeral-curve-keypair))
                   (cons "node-b" (ephemeral-curve-keypair))
                   (cons "unknown-node" (ephemeral-curve-keypair))))
       (provider (lambda (reference) (or (cdr (assoc reference keys :test #'equal)) (error "No test key"))))
       (system (sento.actor-system:make-actor-system '(:dispatchers (:shared (:workers 2)))))
       (received 0)
       (actor (sento.actor-context:actor-of system :name "star:v1:resolver:echo"
                 :receive (make-mesh-receiver
                           (lambda (peer request)
                             (assert (member peer '("node-a" "node-b") :test #'equal))
                             (incf received) (make-result :ok (request-payload request)))
                           (lambda (&rest args) (declare (ignore args)) t))))
       (dispatch (make-sento-dispatcher (lambda (name) (and (equal name "star:v1:resolver:echo") actor))))
       (a (make-mesh :config (native-test-config "node-a" 49101 "node-b" 49102 "node-b")
                     :transport (make-zmq-transport) :credential-provider provider :dispatch dispatch
                     :authorize (lambda (&rest args) (declare (ignore args)) t)))
       (b (make-mesh :config (native-test-config "node-b" 49102 "node-a" 49101 "node-a")
                     :transport (make-zmq-transport) :credential-provider provider :dispatch dispatch
                     :authorize (lambda (&rest args) (declare (ignore args)) t)))
       (stranger (make-mesh :config (native-test-config "unknown-node" 49103 "node-b" 49102 "node-b")
                            :transport (make-zmq-transport) :credential-provider provider
                            :authorize (lambda (&rest args) (declare (ignore args)) t)))
       (peers (list a b stranger)))
  (unwind-protect
       (progn
         (dolist (mesh peers) (assert (eq :running (getf (start-mesh mesh) :state))))
         (tick-peers peers 1)
         (dolist (pair (list (list a "node-b" "native-a-b") (list b "node-a" "native-b-a")))
           (let* ((req (make-request :id (third pair) :caller "star:v1:projector:client"
                                     :destination "star:v1:resolver:echo" :operation "star.edge.echo"
                                     :deadline (+ (unix-milliseconds) 10000) :payload (ascii-octets "private-echo")))
                  (result nil))
             (assert (eq :pending (submit-request (first pair) (second pair) req)))
             (loop repeat 400 until (setf result (take-result (first pair) (request-id req)))
                   do (tick-peers peers 0.01))
             (assert (and result (eq :ok (result-status result))
                          (equalp (ascii-octets "private-echo") (result-payload result))))))
         (assert (= received 2))
         ;; Stranger knows the server public key but its client key is not enrolled.
         (let ((result (submit-request stranger "node-b"
                        (make-request :id "unknown-key" :caller "star:v1:projector:client"
                                      :destination "star:v1:resolver:echo" :operation "star.edge.echo"
                                      :deadline (+ (unix-milliseconds) 3000) :payload (ascii-octets "reject-me")))))
           (assert (or (eq result :pending) (eq :overloaded (result-status result)))))
         (tick-peers peers 3.5)
         (assert (= received 2))
         ;; Prove an actual authentication denial was observed, not just silence.
         (assert (plusp (zmq-zap-denials (mesh-transport b))))
         (let ((result (take-result stranger "unknown-key")))
           (assert (or (null result) (not (eq :ok (result-status result))))))
         (format t "REAL two-peer TCP/CURVE/ZAP Sento roundtrip and unknown-client-key rejection passed.~%"))
    (dolist (mesh (reverse peers)) (stop-mesh mesh))
    (sento.actor-context:shutdown system :wait t)
    (dolist (entry keys) (fill (getf (cdr entry) :secret-key) 0))))
