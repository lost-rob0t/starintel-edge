(in-package #:star.edge.mesh)

;; Narrow libzmq 4.x binding. No socket/context exists merely by loading this file.
;; Native libzmq packaging/audit and Android CFFI support remain separate gates.
(cffi:define-foreign-library edge-libzmq
  (:unix (:or "libzmq.so.5" "libzmq.so"))
  (t (:default "libzmq")))
(cffi:defcfun ("zmq_has" %zmq-has) :int (capability :string))
(cffi:defcfun ("zmq_ctx_new" %zmq-context) :pointer)
(cffi:defcfun ("zmq_ctx_term" %zmq-terminate) :int (context :pointer))
(cffi:defcfun ("zmq_socket" %zmq-socket) :pointer (context :pointer) (kind :int))
(cffi:defcfun ("zmq_close" %zmq-close) :int (socket :pointer))
(cffi:defcfun ("zmq_bind" %zmq-bind) :int (socket :pointer) (endpoint :string))
(cffi:defcfun ("zmq_connect" %zmq-connect) :int (socket :pointer) (endpoint :string))
(cffi:defcfun ("zmq_setsockopt" %zmq-option) :int
  (socket :pointer) (option :int) (value :pointer) (size :size))
(cffi:defcfun ("zmq_send" %zmq-send) :int
  (socket :pointer) (value :pointer) (size :size) (flags :int))
(cffi:defcfun ("zmq_errno" %zmq-errno) :int)
(cffi:defcfun ("zmq_msg_init" %msg-init) :int (message :pointer))
(cffi:defcfun ("zmq_msg_close" %msg-close) :int (message :pointer))
(cffi:defcfun ("zmq_msg_recv" %msg-recv) :int (message :pointer) (socket :pointer) (flags :int))
(cffi:defcfun ("zmq_msg_size" %msg-size) :size (message :pointer))
(cffi:defcfun ("zmq_msg_data" %msg-data) :pointer (message :pointer))
(cffi:defcfun ("zmq_msg_more" %msg-more) :int (message :pointer))
(cffi:defcfun ("zmq_msg_gets" %msg-property) :pointer (message :pointer) (name :string))

#+(and sbcl linux 64-bit)
(progn
  (cffi:defcstruct linux-rlimit (current :unsigned-long) (maximum :unsigned-long))
  (cffi:defcfun ("getrlimit" %getrlimit) :int (resource :int) (limits :pointer))
  (cffi:defcfun ("geteuid" %geteuid) :unsigned-int))

(defun proc-status-words (line prefix)
  (remove "" (split-on #\Space (substitute #\Space #\Tab (subseq line (length prefix))))
          :test #'equal))
(defun proc-status-unsigned (text radix max-digits)
  (unless (and (<= 1 (length text) max-digits)
               (every (lambda (char) (digit-char-p char radix)) text))
    (error "Invalid native process observation"))
  (parse-integer text :radix radix))
(defun parse-linux-process-observation (stream)
  "Read only aggregate VmSize and capability masks, never VMA addresses.
Kernel VmSize is total virtual address space in KiB, not resident memory."
  (let ((mapped nil) (permitted nil) (effective nil))
    (loop for line = (read-line stream nil) while line do
      (cond
        ((and (>= (length line) 7) (string= "VmSize:" line :end2 7))
         (let ((words (proc-status-words line "VmSize:")))
           (unless (and (null mapped) (= 2 (length words)) (equal "kB" (second words)))
             (error "Invalid native mapping observation"))
           (setf mapped (* 1024 (proc-status-unsigned (first words) 10 20)))))
        ((and (>= (length line) 7) (string= "CapPrm:" line :end2 7))
         (let ((words (proc-status-words line "CapPrm:")))
           (unless (and (null permitted) (= 1 (length words)))
             (error "Invalid native capability observation"))
           (setf permitted (proc-status-unsigned (first words) 16 16))))
        ((and (>= (length line) 7) (string= "CapEff:" line :end2 7))
         (let ((words (proc-status-words line "CapEff:")))
           (unless (and (null effective) (= 1 (length words)))
             (error "Invalid native capability observation"))
           (setf effective (proc-status-unsigned (first words) 16 16))))))
    (unless (and mapped (plusp mapped) permitted effective
                 ;; Effective capabilities must be a subset of permitted state.
                 (zerop (logand effective (lognot permitted))))
      (error "Unavailable or inconsistent native process observation"))
    (values mapped permitted effective)))
(defun read-linux-process-observation ()
  (with-open-file (status "/proc/self/status" :direction :input)
    (parse-linux-process-observation status)))

(defun verify-linux-process-memory-limit (&key (maximum-bytes (* 4 1024 1024 1024)))
  "Read-only verifier for native 64-bit SBCL/Linux. Require finite RLIMIT_AS
soft/hard limits, current kernel VmSize <= hard <= MAXIMUM-BYTES, and no root or
retained CAP_SYS_RESOURCE privilege. Limits must match before/after inspection.
Never changes limits, reads/logs raw VMA addresses, or certifies availability.
Returns NIL on Android/ECL, other platforms, errors or inconsistent observations."
  (unless (and (integerp maximum-bytes) (<= (* 64 1024 1024) maximum-bytes (* 16 1024 1024 1024)))
    (return-from verify-linux-process-memory-limit nil))
  #+(and sbcl linux 64-bit)
  (handler-case
      (cffi:with-foreign-objects ((limits '(:struct linux-rlimit)) (after '(:struct linux-rlimit)))
        (and (plusp (%geteuid)) ; do not claim containment for a privileged runtime
             (zerop (%getrlimit 9 limits)) ; Linux RLIMIT_AS on this ABI
             (let ((soft (cffi:foreign-slot-value limits '(:struct linux-rlimit) 'current))
                   (hard (cffi:foreign-slot-value limits '(:struct linux-rlimit) 'maximum)))
               (and (<= (* 64 1024 1024) soft hard maximum-bytes)
                    (multiple-value-bind (mapped permitted effective) (read-linux-process-observation)
                      (and (integerp mapped) (plusp mapped) (<= mapped hard)
                           (integerp permitted) (not (minusp permitted))
                           (integerp effective) (not (minusp effective))
                           (zerop (logand effective (lognot permitted)))
                           ;; Permitted-only privilege can be made effective again.
                           (not (logbitp 24 permitted)) (not (logbitp 24 effective))
                           (zerop (%getrlimit 9 after))
                           (= soft (cffi:foreign-slot-value after '(:struct linux-rlimit) 'current))
                           (= hard (cffi:foreign-slot-value after '(:struct linux-rlimit) 'maximum))))))))
    (error () nil))
  #-(and sbcl linux 64-bit) nil)

(defvar *zmq-context* nil)
(defvar *zmq-owner* nil)
(defvar *zmq-zap* nil)
(defvar *zmq-domains* (make-hash-table :test #'equal))
(defvar *zmq-context-lock* (bordeaux-threads:make-lock "edge-zmq-context"))
(defclass zmq-transport (transport)
  ((native-budget-check :initarg :native-budget-check :initform nil :reader native-budget-check)
   (owner :initform nil :accessor zmq-owner)
   (config :initform nil :accessor zmq-config)
   (router :initform nil :accessor zmq-router)
   (dealers :initform nil :accessor zmq-dealers)
   (keys :initform nil :accessor zmq-keys)
   (enrollment :initform nil :accessor zmq-enrollment)
   (zap-denials :initform 0 :accessor zmq-zap-denials)
   (open-p :initform nil :accessor zmq-open-p)))
(defun make-zmq-transport (&key (native-budget-check #'verify-linux-process-memory-limit))
  "NATIVE-BUDGET-CHECK must verify an external hard process/container memory limit.
libzmq queues incomplete multipart frames before application frame-count checks;
MAXMSGSIZE and HWM alone do not contain hostile enrolled peers. Missing guard fails
closed. This callback verifies existing host policy; it must not change permissions."
  (unless (or (null native-budget-check) (functionp native-budget-check))
    (error "Invalid native containment port"))
  (make-instance 'zmq-transport :native-budget-check native-budget-check))

(defun zmq-check (value)
  (when (minusp value) (error "ZeroMQ operation failed (errno ~D)" (%zmq-errno))) value)
(defun assert-zmq-owner (transport)
  (unless (and (eq (bordeaux-threads:current-thread) (zmq-owner transport))
               (eq (bordeaux-threads:current-thread) *zmq-owner*))
    (error "ZeroMQ operation outside exclusive socket owner")))
(defun option-int (socket option value &optional (type :int))
  (cffi:with-foreign-object (ptr type)
    (setf (cffi:mem-ref ptr type) value)
    (zmq-check (%zmq-option socket option ptr (cffi:foreign-type-size type)))))
(defun option-bytes (socket option bytes)
  (cffi:with-foreign-object (ptr :unsigned-char (max 1 (length bytes)))
    (dotimes (i (length bytes)) (setf (cffi:mem-aref ptr :unsigned-char i) (aref bytes i)))
    (unwind-protect (zmq-check (%zmq-option socket option ptr (length bytes)))
      (dotimes (i (length bytes)) (setf (cffi:mem-aref ptr :unsigned-char i) 0)))))
(defun new-socket (kind)
  (let ((socket (%zmq-socket *zmq-context* kind)))
    (when (cffi:null-pointer-p socket) (error "ZeroMQ socket unavailable")) socket))
(defun bounded-socket (socket config)
  (option-int socket 17 0) ; LINGER
  (option-int socket 23 (config-hwm config)) ; SNDHWM
  (option-int socket 24 (config-hwm config)) ; RCVHWM
  (option-int socket 22 (config-max-message-bytes config) :int64) ; MAXMSGSIZE
  (option-int socket 27 0) ; RCVTIMEO
  (option-int socket 28 0) ; SNDTIMEO
  (option-int socket 18 100) ; RECONNECT_IVL
  (option-int socket 21 5000) ; RECONNECT_IVL_MAX
  (option-int socket 66 5000) ; HANDSHAKE_IVL
  socket)
(defun key-bytes (provider reference field)
  (let* ((resolved (funcall provider reference)) (key (getf resolved field)))
    (unless (and (octets-p key) (= 32 (length key)))
      (error "Credential provider returned invalid CURVE material"))
    (copy-seq key)))
(defun apply-client-keys (socket public secret)
  (option-bytes socket 48 public) ; CURVE_PUBLICKEY
  (option-bytes socket 49 secret)) ; CURVE_SECRETKEY

(defun acquire-zmq-context ()
  (bordeaux-threads:with-lock-held (*zmq-context-lock*)
    (when (and *zmq-context* (not (eq *zmq-owner* (bordeaux-threads:current-thread))))
      (error "A process context already belongs to another socket owner"))
    (unless *zmq-context*
      (cffi:use-foreign-library edge-libzmq)
      (unless (= 1 (%zmq-has "curve")) (error "libzmq has no CURVE support"))
      (setf *zmq-owner* (bordeaux-threads:current-thread) *zmq-context* (%zmq-context))
      (when (cffi:null-pointer-p *zmq-context*)
        (setf *zmq-context* nil *zmq-owner* nil) (error "ZeroMQ context unavailable"))
      (handler-case
          (progn
            (setf *zmq-zap* (new-socket 4)) ; REP, one ZAP owner per process
            (option-int *zmq-zap* 17 0)
            (option-int *zmq-zap* 23 64)
            (option-int *zmq-zap* 24 64)
            (option-int *zmq-zap* 22 4096 :int64)
            (zmq-check (%zmq-bind *zmq-zap* "inproc://zeromq.zap.01")))
        (error (e)
          (when *zmq-zap* (%zmq-close *zmq-zap*))
          (%zmq-terminate *zmq-context*)
          (setf *zmq-context* nil *zmq-owner* nil *zmq-zap* nil)
          (error e))))))

(defun pin-zmq-enrollment (transport public keys)
  "Keep peer/public-key identity stable for the life of a mesh, including resume.
Provider-reference reassignment is not key rotation and cannot reroute old work."
  (let ((snapshot (cons (copy-seq public)
                        (mapcar (lambda (pair) (cons (copy-seq (car pair)) (copy-seq (cdr pair)))) keys))))
    (when (and (zmq-enrollment transport) (not (equalp snapshot (zmq-enrollment transport))))
      (error "Enrollment changed; retained mesh state cannot be reused"))
    (unless (zmq-enrollment transport) (setf (zmq-enrollment transport) snapshot))))

(defun configure-router-auth (socket secret domain)
  (option-int socket 93 1) ; ZAP_ENFORCE_DOMAIN: no encryption-only fallback
  (option-int socket 47 1) ; CURVE_SERVER
  (option-bytes socket 49 secret)
  (option-bytes socket 55 (ascii-octets domain))) ; ZAP_DOMAIN

(defmethod transport-check-owner ((transport zmq-transport))
  (when (zmq-owner transport) (assert-zmq-owner transport)) t)

(defmethod transport-open ((transport zmq-transport) config provider)
  (when (zmq-open-p transport) (assert-zmq-owner transport) (return-from transport-open t))
  (unless (and (native-budget-check transport) (eq t (funcall (native-budget-check transport))))
    (error "Native transport requires verified hard resource containment"))
  (acquire-zmq-context)
  (setf (zmq-owner transport) (bordeaux-threads:current-thread) (zmq-config transport) config)
  (handler-case
      (let ((public nil) (secret nil))
        (unwind-protect
             (progn
               (when (gethash (config-node-id config) *zmq-domains*) (error "Duplicate ZAP domain"))
               (setf public (key-bytes provider (config-credential-reference config) :public-key)
                     secret (key-bytes provider (config-credential-reference config) :secret-key))
               (dolist (peer (config-peers config))
                 (let ((key (key-bytes provider (peer-key-reference peer) :public-key)))
                   (when (find key (zmq-keys transport) :key #'car :test #'equalp)
                     (error "One authenticated CURVE key cannot enroll as two peers"))
                   (push (cons key (peer-id peer)) (zmq-keys transport))))
               (pin-zmq-enrollment transport public (zmq-keys transport))
               (setf (gethash (config-node-id config) *zmq-domains*) transport)
               (setf (zmq-router transport) (new-socket 6)) ; ROUTER
               (bounded-socket (zmq-router transport) config)
               (option-int (zmq-router transport) 33 1) ; ROUTER_MANDATORY
               (configure-router-auth (zmq-router transport) secret (config-node-id config))
               (zmq-check (%zmq-bind (zmq-router transport) (config-bind-endpoint config)))
               (dolist (peer (config-peers config))
                 (let ((socket (new-socket 5))) ; DEALER
                   (push (cons (peer-id peer) socket) (zmq-dealers transport))
                   (bounded-socket socket config)
                   (option-int socket 39 1) ; IMMEDIATE: don't queue before completed handshake
                   (apply-client-keys socket public secret)
                   (option-bytes socket 50 (car (find (peer-id peer) (zmq-keys transport) :key #'cdr :test #'equal)))
                   (zmq-check (%zmq-connect socket (peer-endpoint peer)))))
               (setf (zmq-open-p transport) t))
          (when secret (fill secret 0))
          (when public (fill public 0))))
    (error (e) (transport-close transport) (error e)))
  t)

(defmethod transport-close ((transport zmq-transport))
  (when (zmq-owner transport)
    (assert-zmq-owner transport)
    (dolist (pair (zmq-dealers transport)) (%zmq-close (cdr pair)))
    (when (zmq-router transport) (%zmq-close (zmq-router transport)))
    (when (and (zmq-config transport)
               (eq transport (gethash (config-node-id (zmq-config transport)) *zmq-domains*)))
      (remhash (config-node-id (zmq-config transport)) *zmq-domains*))
    (setf (zmq-dealers transport) nil (zmq-router transport) nil (zmq-keys transport) nil
          (zmq-open-p transport) nil (zmq-owner transport) nil)
    (bordeaux-threads:with-lock-held (*zmq-context-lock*)
      (when (and *zmq-context* (zerop (hash-table-count *zmq-domains*)))
        (%zmq-close *zmq-zap*)
        (%zmq-terminate *zmq-context*)
        (setf *zmq-zap* nil *zmq-context* nil *zmq-owner* nil))))
  t)

(defun send-multipart (socket frames)
  (loop for rest on frames for index from 0
        for frame = (car rest)
        do (cffi:with-foreign-object (ptr :unsigned-char (max 1 (length frame)))
             (dotimes (i (length frame)) (setf (cffi:mem-aref ptr :unsigned-char i) (aref frame i)))
             (let ((result (%zmq-send socket ptr (length frame) (if (cdr rest) 3 1)))) ; DONTWAIT|SNDMORE
               (when (minusp result)
                 (if (and (zerop index) (member (%zmq-errno) '(11 113))) ; EAGAIN/EHOSTUNREACH, Linux
                     (return-from send-multipart :overloaded)
                     (error "ZeroMQ multipart send failed; owner must close to avoid partial framing"))))))
  :sent)

(defun receive-multipart (socket max-frames max-bytes)
  "At most MAX-FRAMES and MAX-BYTES copied. Overflow fails closed, never drains indefinitely."
  (let ((frames nil) (total 0) (authenticated-user nil))
    (loop for index from 0 do
      ;; zmq_msg_t is an opaque 64-byte ABI type in libzmq 4.x, aligned as uint64.
      (cffi:with-foreign-object (message :uint64 8)
        (zmq-check (%msg-init message))
        (unwind-protect
             (let ((received (%msg-recv message socket 1)))
               (when (minusp received)
                 (if (and (zerop index) (= 11 (%zmq-errno)))
                     (return-from receive-multipart (values nil nil))
                     (error "ZeroMQ multipart receive failed")))
               (let* ((size (%msg-size message)) (property (%msg-property message "User-Id")))
                 (incf total size)
                 (when (or (>= index max-frames) (> total max-bytes))
                   (error "ZeroMQ multipart bound exceeded"))
                 (unless (cffi:null-pointer-p property)
                   (let ((user (cffi:foreign-string-to-lisp property :max-chars 128)))
                     (when (and authenticated-user (not (equal user authenticated-user)))
                       (error "Inconsistent authenticated user metadata"))
                     (setf authenticated-user user)))
                 (let ((frame (make-array size :element-type '(unsigned-byte 8))) (data (%msg-data message)))
                   (dotimes (i size) (setf (aref frame i) (cffi:mem-aref data :unsigned-char i)))
                   (push frame frames))
                 (when (zerop (%msg-more message))
                   (return-from receive-multipart (values (nreverse frames) authenticated-user)))))
          (%msg-close message))))))

(defun authorized-zap-peer (frames)
  "ZAP 1.0 CURVE credentials -> enrolled peer. No routing-id or envelope substitution."
  (when (and (= (length frames) 7) (equalp (first frames) (ascii-octets "1.0"))
             (equalp (sixth frames) (ascii-octets "CURVE")) (= 32 (length (seventh frames))))
    (let* ((domain (ignore-errors (octets-ascii (third frames))))
           (transport (and domain (gethash domain *zmq-domains*))))
      (when transport
        (cdr (find (seventh frames) (zmq-keys transport) :key #'car :test #'equalp))))))
(defun poll-zap (limit)
  (dotimes (i limit)
    (let ((frames (receive-multipart *zmq-zap* 7 4096)))
      (unless frames (return))
      (let ((peer (authorized-zap-peer frames)))
        (unless peer
          (let* ((domain (and (third frames) (ignore-errors (octets-ascii (third frames)))))
                 (transport (and domain (gethash domain *zmq-domains*))))
            (when transport (incf (zmq-zap-denials transport)))))
        (unless (eq :sent (send-multipart *zmq-zap*
                          (list (ascii-octets "1.0") (or (second frames) (ascii-octets ""))
                                (ascii-octets (if peer "200" "400"))
                                (ascii-octets (if peer "OK" "DENIED"))
                                (ascii-octets (or peer "")) (ascii-octets ""))))
          (error "ZAP reply unavailable"))))))

(defmethod transport-send ((transport zmq-transport) peer frames &optional route)
  (declare (ignore route))
  (assert-zmq-owner transport)
  (unless (and (zmq-open-p transport) (mesh-peer-enrolled-p transport peer))
    (return-from transport-send :unavailable))
  (unless (and (= +wire-frame-count+ (length frames)) (every #'octets-p frames)
               (<= (message-size frames) (config-max-message-bytes (zmq-config transport))))
    (error "Invalid outbound multipart"))
  ;; Never reply on a cached ROUTER routing ID: after disconnect it can be
  ;; claimed by a different enrolled CURVE key. The symmetric private topology
  ;; routes every request/result through the intended peer's key-pinned DEALER.
  (let ((socket (cdr (assoc peer (zmq-dealers transport) :test #'equal))))
    (if socket (send-multipart socket frames) :unavailable)))

(defun mesh-peer-enrolled-p (transport id)
  (find id (config-peers (zmq-config transport)) :key #'peer-id :test #'equal))
(defmethod transport-poll ((transport zmq-transport))
  (assert-zmq-owner transport)
  (unless (zmq-open-p transport) (return-from transport-poll nil))
  (let* ((config (zmq-config transport)) (limit (config-hwm config)) (deliveries nil))
    (poll-zap limit)
    ;; One packet per socket per tick prevents an active peer from starving others.
    (multiple-value-bind (frames user)
        (receive-multipart (zmq-router transport) (1+ +wire-frame-count+)
                           (+ 255 (config-max-message-bytes config)))
      (when (and frames user (mesh-peer-enrolled-p transport user))
        (push (make-delivery :peer user :route (first frames) :frames (rest frames)) deliveries)))
    ;; All application messages arrive at this node's ROUTER; outbound DEALERs
    ;; are send-only in this symmetric profile. No caller-supplied route is reused.
    (nreverse deliveries)))
