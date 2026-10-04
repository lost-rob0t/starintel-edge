(in-package #:star.edge.mesh)

;; Private projection of the STAR-SERVER-040 operation/result contract.
;; This is not the legacy StarRouter SC01/SR01 broker or a document authority.
(defconstant +wire-frame-count+ 18)
(defparameter +protocol+ "STARROUTER/1.0/edge-private-1")
(defparameter +statuses+
  '(:ok :invalid :unauthorized :forbidden :not-found :no-route :conflict
    :stale-authority :overloaded :deadline-exceeded :cancelled
    :dependency-unavailable :outcome-unknown :protocol-error :internal-error))

(defun unix-milliseconds ()
  (* 1000 (- (get-universal-time) 2208988800)))

(defun token-p (value &optional (limit 128))
  (and (stringp value) (<= 1 (length value) limit)
       (every (lambda (c) (or (find c "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
                             nil)) value)))

(defun actor-name-p (value)
  ;; Matches star.actors:valid-target-actor-name-p; exact identity, no renaming.
  (and (token-p value) (alphanumericp (char value 0))
       (< (char-code (char value 0)) 128)))

(defun octets-p (value)
  (typep value '(simple-array (unsigned-byte 8) (*))))

(defun ascii-octets (value)
  (unless (and (stringp value) (every (lambda (c) (< (char-code c) 128)) value))
    (error "Non-ASCII envelope field"))
  (map '(simple-array (unsigned-byte 8) (*)) #'char-code value))

(defun octets-ascii (value)
  (unless (and (octets-p value) (every (lambda (n) (< n 128)) value))
    (error "Non-ASCII envelope field"))
  (map 'string #'code-char value))

(defun split-on (char string)
  (loop for start = 0 then (1+ end)
        for end = (position char string :start start)
        collect (subseq string start end) while end))

(defun private-endpoint-p (endpoint)
  "Explicit IPv4 TCP endpoint only: no wildcard, DNS, discovery or public route."
  (handler-case
      (and (stringp endpoint) (<= (length endpoint) 64)
           (equal "tcp://" (subseq endpoint 0 6))
           (let* ((parts (split-on #\: (subseq endpoint 6)))
                  (ip (split-on #\. (first parts)))
                  (nums (mapcar (lambda (x)
                                  (unless (and (plusp (length x))
                                               (every #'digit-char-p x)
                                               (or (= 1 (length x)) (char/= #\0 (char x 0))))
                                    (error "Invalid address"))
                                  (parse-integer x)) ip))
                  (port (and (= 2 (length parts)) (second parts))))
             (and (= 4 (length nums)) (every (lambda (n) (<= 0 n 255)) nums)
                  (or (= 127 (first nums)) (= 10 (first nums))
                      (and (= 172 (first nums)) (<= 16 (second nums) 31))
                      (and (= 192 (first nums)) (= 168 (second nums))))
                  port (every #'digit-char-p port) (<= 1 (parse-integer port) 65535))))
    (error () nil)))

(defstruct (peer (:constructor %make-peer)) id endpoint key-reference callers actors)
(defun make-peer (&key id endpoint key-reference callers actors)
  "Enrollment is local and explicit. KEY-REFERENCE is a provider locator, not a key.
CALLERS are identities this peer may assert. ACTORS are local destinations it may call."
  (unless (and (token-p id) (private-endpoint-p endpoint) (token-p key-reference)
               (listp callers) (every #'actor-name-p callers)
               (listp actors) (every #'actor-name-p actors))
    (error "Invalid private peer enrollment"))
  (%make-peer :id (copy-seq id) :endpoint (copy-seq endpoint)
              :key-reference (copy-seq key-reference)
              :callers (mapcar #'copy-seq callers) :actors (mapcar #'copy-seq actors)))

(defstruct (operation (:constructor %make-operation)) name schema retry-safe)
(defun make-operation (&key name (schema "application/octet-stream") retry-safe)
  (unless (and (token-p name) (stringp schema) (<= 1 (length schema) 256)
               (every (lambda (c) (<= 33 (char-code c) 126)) schema)
               (member retry-safe '(t nil)))
    (error "Invalid operation"))
  (%make-operation :name (copy-seq name) :schema (copy-seq schema) :retry-safe retry-safe))

(defstruct (config (:constructor %make-config))
  node-id bind-endpoint credential-reference peers operations
  max-message-bytes max-pending max-inbound max-replay max-deadline-ms
  retry-ms max-attempts hwm)
(defun make-config (&key node-id bind-endpoint credential-reference peers operations
                         (mode :private) (max-message-bytes 65536) (max-pending 32)
                         (max-inbound 32) (max-replay 128) (max-deadline-ms 30000)
                         (retry-ms 1000) (max-attempts 3) (hwm 32))
  (unless (eq mode :private) (error "Only explicit private mesh is implemented"))
  (unless (and (token-p node-id) (private-endpoint-p bind-endpoint)
               (token-p credential-reference) (listp peers) (<= (length peers) 64)
               (every #'peer-p peers) (not (find node-id peers :key #'peer-id :test #'equal))
               (= (length peers) (length (remove-duplicates peers :key #'peer-id :test #'equal)))
               (listp operations) (<= (length operations) 64) (every #'operation-p operations)
               (= (length operations) (length (remove-duplicates operations :key #'operation-name :test #'equal))))
    (error "Invalid private mesh configuration"))
  (loop for n in (list max-message-bytes max-pending max-inbound max-replay
                      max-deadline-ms retry-ms max-attempts hwm)
        for ceiling in '(1048576 1024 1024 4096 300000 60000 10 1024)
        unless (and (integerp n) (<= 1 n ceiling)) do (error "Invalid mesh bound"))
  (unless (and (>= max-message-bytes 1024) (>= max-replay max-inbound)
               (<= retry-ms max-deadline-ms)) (error "Inconsistent mesh bounds"))
  (%make-config :node-id (copy-seq node-id) :bind-endpoint (copy-seq bind-endpoint)
                :credential-reference (copy-seq credential-reference)
                :peers (mapcar #'copy-peer peers) :operations (mapcar #'copy-operation operations)
                :max-message-bytes max-message-bytes :max-pending max-pending
                :max-inbound max-inbound :max-replay max-replay
                :max-deadline-ms max-deadline-ms :retry-ms retry-ms :max-attempts max-attempts :hwm hwm))

(defstruct (request (:constructor %make-request))
  id caller destination operation payload deadline schema correlation causation trace
  authorization-context idempotency-key)
(defun make-request (&key id caller destination operation payload deadline
                          (schema "application/octet-stream") (correlation "")
                          (causation "") (trace "") (authorization-context "") (idempotency-key ""))
  (unless (and (token-p id) (actor-name-p caller) (actor-name-p destination)
               (token-p operation) (octets-p payload) (integerp deadline) (plusp deadline)
               (stringp schema) (<= 1 (length schema) 256)
               (every (lambda (c) (<= 33 (char-code c) 126)) schema)
               (every (lambda (x) (or (equal x "") (token-p x)))
                      (list correlation causation trace authorization-context idempotency-key)))
    (error "Invalid actor request"))
  (%make-request :id (copy-seq id) :caller (copy-seq caller) :destination (copy-seq destination)
                 :operation (copy-seq operation) :payload (copy-seq payload) :deadline deadline
                 :schema (copy-seq schema) :correlation (copy-seq correlation)
                 :causation (copy-seq causation) :trace (copy-seq trace)
                 :authorization-context (copy-seq authorization-context)
                 :idempotency-key (copy-seq idempotency-key)))

(defstruct (result (:constructor %make-result)) status payload)
(defun make-result (status &optional (payload (make-array 0 :element-type '(unsigned-byte 8))))
  (unless (and (member status +statuses+) (octets-p payload)) (error "Invalid mesh result"))
  (%make-result :status status :payload (copy-seq payload)))

(defun encode-message (request &optional result)
  (append (mapcar #'ascii-octets
                 (list "" +protocol+ (if result "result" "request")
                       (request-id request) (request-correlation request) (request-causation request)
                       (request-trace request) (request-caller request) (request-destination request)
                       (write-to-string (request-deadline request) :base 10 :radix nil)
                       (request-schema request) (request-operation request)
                       (request-authorization-context request) (request-idempotency-key request)
                       "" "" ; reserved cancellation and provenance: unsupported, not silently dropped
                       (if result (string-downcase (symbol-name (result-status result))) "")))
          (list (copy-seq (if result (result-payload result) (request-payload request))))))

(defun decode-message (frames max-bytes)
  "No Lisp reader/eval, JSON interpretation, symbol interning or document rewriting."
  (unless (and (listp frames) (= +wire-frame-count+ (length frames))
               (every #'octets-p frames) (<= (reduce #'+ frames :key #'length) max-bytes)
               (every (lambda (f) (<= (length f) 256)) (butlast frames)))
    (error "Invalid or oversized multipart message"))
  (let* ((f (mapcar #'octets-ascii (butlast frames)))
         (deadline (nth 9 f)) (kind (nth 2 f)) (status (nth 16 f)))
    (unless (and (equal "" (first f)) (equal +protocol+ (second f))
                 (member kind '("request" "result") :test #'equal)
                 (equal "" (nth 14 f)) (equal "" (nth 15 f))
                 (<= 1 (length deadline) 16) (every #'digit-char-p deadline))
      (error "Unsupported protocol or required field"))
    (let ((request (make-request :id (nth 3 f) :correlation (nth 4 f) :causation (nth 5 f)
                                 :trace (nth 6 f) :caller (nth 7 f) :destination (nth 8 f)
                                 :deadline (parse-integer deadline) :schema (nth 10 f)
                                 :operation (nth 11 f) :authorization-context (nth 12 f)
                                 :idempotency-key (nth 13 f) :payload (car (last frames)))))
      (if (equal kind "request")
          (progn (unless (equal status "") (error "Request has result status")) (values request nil))
          (let ((value (find status +statuses+ :key (lambda (x) (string-downcase (symbol-name x))) :test #'equal)))
            (unless value (error "Unknown result status"))
            (values request (make-result value (request-payload request))))))))

(defclass transport () ())
(defgeneric transport-check-owner (transport))
(defmethod transport-check-owner ((transport transport)) t)
(defgeneric transport-open (transport config credential-provider))
(defgeneric transport-close (transport))
(defgeneric transport-send (transport peer frames &optional route))
(defgeneric transport-poll (transport))
(defstruct delivery peer route frames)
(defmethod transport-open ((transport transport) config credential-provider)
  (declare (ignore config credential-provider)) nil)
(defmethod transport-close ((transport transport)) t)
(defmethod transport-send ((transport transport) peer frames &optional route)
  (declare (ignore peer frames route)) :unavailable)
(defmethod transport-poll ((transport transport)) nil)

(defstruct pending peer request frames sent attempts next-retry result)
(defstruct inbound peer route request frames poll result (reply-pending nil) (reply-attempts 0) (next-reply 0))
(defstruct (mesh (:constructor %make-mesh))
  config transport credentials authorize dispatch (clock #'unix-milliseconds)
  (state :stopped) (last-now 0) (pending (make-hash-table :test #'equal))
  (inbound (make-hash-table :test #'equal)))

(defun make-mesh (&key config (transport (make-instance 'transport)) credential-provider
                       authorize dispatch (clock #'unix-milliseconds))
  "All methods are owner-serialized. DISPATCH takes (authenticated-peer-id request) and returns a nonblocking poll function
whose result is NIL while pending or a RESULT. It must never block the socket owner.
AUTHORIZE rechecks (peer-id request) and must return T; default denies. No supervisor
or actor registry is created here. Trusted init.lisp binds the existing runtime."
  (unless (and (config-p config) (typep transport 'transport) (functionp clock)
               (every (lambda (p) (or (null p) (functionp p)))
                      (list credential-provider authorize dispatch)))
    (error "Invalid runtime ports"))
  (%make-mesh :config config :transport transport :credentials credential-provider
              :authorize authorize :dispatch dispatch :clock clock))

(defun mesh-now (mesh)
  ;; A backwards wall-clock adjustment must not resurrect evicted expired IDs.
  ;; The watermark is volatile, just like replay state; no restart guarantee.
  (let ((now (funcall (mesh-clock mesh))))
    (unless (and (integerp now) (not (minusp now))) (error "Invalid clock"))
    (setf (mesh-last-now mesh) (max now (mesh-last-now mesh)))))

(defun mesh-status (mesh)
  (list :state (mesh-state mesh) :mode :private :public-swarm nil
        :pending (hash-table-count (mesh-pending mesh))
        :replay-entries (hash-table-count (mesh-inbound mesh))))
(defun start-mesh (mesh)
  (transport-check-owner (mesh-transport mesh))
  (unless (eq (mesh-state mesh) :running)
    (setf (mesh-state mesh)
          (handler-case
              (if (and (mesh-credentials mesh)
                       (eq t (transport-open (mesh-transport mesh) (mesh-config mesh) (mesh-credentials mesh))))
                  :running :unavailable)
            (error () (ignore-errors (transport-close (mesh-transport mesh))) :unavailable))))
  (mesh-status mesh))
(defun request-operation-spec (mesh request)
  (find (request-operation request) (config-operations (mesh-config mesh)) :key #'operation-name :test #'equal))
(defun finish-outstanding (mesh)
  (maphash (lambda (id p)
             (declare (ignore id))
             (unless (pending-result p)
               (setf (pending-result p)
                     (make-result (if (and (pending-sent p)
                                           (not (operation-retry-safe (request-operation-spec mesh (pending-request p)))))
                                      :outcome-unknown :dependency-unavailable)))))
           (mesh-pending mesh)))
(defun stop-mesh (mesh)
  (transport-check-owner (mesh-transport mesh))
  (finish-outstanding mesh)
  (transport-close (mesh-transport mesh))
  (setf (mesh-state mesh) :stopped)
  (mesh-status mesh))
(defun suspend-mesh (mesh)
  (stop-mesh mesh) (setf (mesh-state mesh) :suspended) (mesh-status mesh))
(defun resume-mesh (mesh) (start-mesh mesh))
(defun mesh-peer (mesh id)
  (find id (config-peers (mesh-config mesh)) :key #'peer-id :test #'equal))
(defun authorized-p (mesh peer request)
  (and (mesh-authorize mesh)
       (handler-case (eq t (funcall (mesh-authorize mesh) peer request)) (error () nil))))
(defun valid-window-p (mesh request now)
  (< now (request-deadline request) (+ now (1+ (config-max-deadline-ms (mesh-config mesh))))))
(defun message-size (frames) (reduce #'+ frames :key #'length))
(defun safe-send (mesh peer frames &optional route)
  (unless (eq (mesh-state mesh) :running) (return-from safe-send :unavailable))
  (handler-case (transport-send (mesh-transport mesh) peer frames route)
    (error ()
      ;; A failed partial multipart must never poison the next request.
      (finish-outstanding mesh)
      (ignore-errors (transport-close (mesh-transport mesh)))
      (setf (mesh-state mesh) :unavailable)
      :outcome-unknown)))

(defun submit-request (mesh peer-id request)
  "Returns :PENDING or a terminal RESULT. IDs are caller-generated unique attempt IDs.
Only locally declared read-only/retry-safe operations auto-retry; mutations never do."
  (transport-check-owner (mesh-transport mesh))
  (let* ((config (mesh-config mesh)) (now (mesh-now mesh))
         (spec (request-operation-spec mesh request)) (frames (encode-message request)))
    (cond
      ((not (eq (mesh-state mesh) :running)) (make-result :dependency-unavailable))
      ((null (mesh-peer mesh peer-id)) (make-result :no-route))
      ((or (null spec) (not (equal (operation-schema spec) (request-schema request)))
           (> (message-size frames) (config-max-message-bytes config))) (make-result :invalid))
      ((not (valid-window-p mesh request now)) (make-result :deadline-exceeded))
      ((not (authorized-p mesh peer-id request)) (make-result :forbidden))
      ((gethash (request-id request) (mesh-pending mesh)) (make-result :conflict))
      ((>= (hash-table-count (mesh-pending mesh)) (config-max-pending config)) (make-result :overloaded))
      (t
       ;; Decode our snapshot so caller mutation cannot alter retry or correlation.
       (let ((frozen (decode-message frames (config-max-message-bytes config))))
         (let ((outcome (safe-send mesh peer-id frames)))
           (if (eq outcome :sent)
               (progn
                 (setf (gethash (request-id frozen) (mesh-pending mesh))
                       (make-pending :peer (copy-seq peer-id) :request frozen :frames frames :sent t
                                     :attempts 1 :next-retry (+ now (config-retry-ms config))))
                 :pending)
               (make-result (case outcome
                              (:overloaded :overloaded)
                              (:outcome-unknown :outcome-unknown)
                              (otherwise :dependency-unavailable))))))))))

(defun take-result (mesh request-id)
  (transport-check-owner (mesh-transport mesh))
  (let ((p (gethash request-id (mesh-pending mesh))))
    (when (and p (pending-result p))
      (remhash request-id (mesh-pending mesh)) (pending-result p))))
(defun reply (mesh delivery request result)
  (safe-send mesh (delivery-peer delivery) (encode-message request result) (delivery-route delivery)))
(defun send-cached-result (mesh entry now)
  (when (and (eq (mesh-state mesh) :running) (inbound-result entry) (inbound-reply-pending entry)
             (< now (request-deadline (inbound-request entry)))
             (<= (inbound-next-reply entry) now)
             (< (inbound-reply-attempts entry) (config-max-attempts (mesh-config mesh))))
    ;; Recheck at the actual retry/send boundary, not merely when actor work completed.
    (unless (authorized-p mesh (inbound-peer entry) (inbound-request entry))
      (setf (inbound-result entry)
            (make-result (if (operation-retry-safe (request-operation-spec mesh (inbound-request entry)))
                             :forbidden :outcome-unknown))))
    (incf (inbound-reply-attempts entry))
    (setf (inbound-next-reply entry) (+ now (config-retry-ms (mesh-config mesh))))
    (when (eq :sent (safe-send mesh (inbound-peer entry)
                              (encode-message (inbound-request entry) (inbound-result entry))
                              (inbound-route entry)))
      (setf (inbound-reply-pending entry) nil))))

(defun matching-result-p (pending peer request)
  (and (equal peer (pending-peer pending))
       ;; Every correlation/authority field must match; only payload and status differ.
       (equalp (butlast (encode-message request)) (butlast (pending-frames pending)))))

(defun accept-delivery (mesh delivery now)
  (let ((peer (mesh-peer mesh (delivery-peer delivery))) (config (mesh-config mesh)))
    ;; A DELIVERY peer is established only by transport authentication, never envelope text.
    (when peer
      (handler-case
          (multiple-value-bind (request result)
              (decode-message (delivery-frames delivery) (config-max-message-bytes config))
            (if result
                (let ((p (gethash (request-id request) (mesh-pending mesh))))
                  (when (and p (not (pending-result p))
                             (matching-result-p p (delivery-peer delivery) request)
                             (< now (request-deadline (pending-request p)))
                             (authorized-p mesh (delivery-peer delivery) (pending-request p)))
                    (setf (pending-result p) result)))
                (let* ((spec (request-operation-spec mesh request))
                       (key (list (peer-id peer) (request-id request)))
                       (old (gethash key (mesh-inbound mesh)))
                       (rejection
                         (cond
                           ((not (valid-window-p mesh request now)) :deadline-exceeded)
                           ((or (null spec) (not (equal (operation-schema spec) (request-schema request)))) :invalid)
                           ((or (not (member (request-caller request) (peer-callers peer) :test #'equal))
                                (not (member (request-destination request) (peer-actors peer) :test #'equal))
                                (not (authorized-p mesh (peer-id peer) request))) :forbidden)
                           ((and old (not (equalp (inbound-frames old) (delivery-frames delivery)))) :conflict))))
                  (cond
                    (rejection
                     (reply mesh delivery request
                            (make-result (if (and old spec (not (operation-retry-safe spec))
                                                  (member rejection '(:forbidden :deadline-exceeded)))
                                             :outcome-unknown rejection))))
                    (old
                     ;; Do not dispatch duplicates. Remember newest authenticated return route.
                     (setf (inbound-route old) (delivery-route delivery))
                     (when (inbound-result old)
                       (setf (inbound-reply-pending old) t (inbound-reply-attempts old) 0 (inbound-next-reply old) now)
                       (send-cached-result mesh old now)))
                    ((or (>= (hash-table-count (mesh-inbound mesh)) (config-max-replay config))
                         (>= (loop for v being the hash-values of (mesh-inbound mesh)
                                   count (not (null (inbound-poll v)))) (config-max-inbound config)))
                     (reply mesh delivery request (make-result :overloaded)))
                    (t
                     ;; Reserve replay slot before handing a request to the authoritative actor.
                     (let ((entry (make-inbound :peer (peer-id peer) :route (delivery-route delivery)
                                                :request request :frames (mapcar #'copy-seq (delivery-frames delivery)))))
                       (setf (gethash key (mesh-inbound mesh)) entry)
                       (setf (inbound-poll entry)
                             (handler-case
                                 (and (mesh-dispatch mesh)
                                      (funcall (mesh-dispatch mesh) (peer-id peer)
                                               (decode-message (inbound-frames entry)
                                                               (config-max-message-bytes config))))
                               (error () nil)))
                       (unless (functionp (inbound-poll entry))
                         (setf (inbound-result entry)
                               (make-result (if (mesh-dispatch mesh) :outcome-unknown :dependency-unavailable)))
                         (when (mesh-dispatch mesh)
                           ;; An exception/bad return does not prove that dispatch did not enqueue.
                           ;; Keep this admission charged until runtime teardown/reconciliation.
                           (let ((unknown (inbound-result entry)))
                             (setf (inbound-poll entry) (lambda () (values unknown :unsettled)))))
                         (setf (inbound-reply-pending entry) t)
                         (send-cached-result mesh entry now))))))))
        (error () nil))))) ; Malformed packets are dropped, without reflecting attacker bytes.

(defun step-mesh (mesh)
  "One bounded nonblocking tick. The host/Sento managed owner schedules this; no hidden threads."
  (transport-check-owner (mesh-transport mesh))
  (when (eq (mesh-state mesh) :running)
    (let* ((now (mesh-now mesh)) (config (mesh-config mesh)))
      (handler-case
          (let ((deliveries (transport-poll (mesh-transport mesh))))
            (unless (and (listp deliveries) (<= (length deliveries) (config-hwm config))
                         (every #'delivery-p deliveries)) (error "Invalid transport batch"))
            (dolist (d deliveries)
              (unless (eq (mesh-state mesh) :running) (return))
              (accept-delivery mesh d now)))
        (error () (finish-outstanding mesh) (ignore-errors (transport-close (mesh-transport mesh)))
                  (setf (mesh-state mesh) :unavailable)))
      (maphash
       (lambda (key entry)
         (let ((request (inbound-request entry)))
           (cond
             ((and (<= (request-deadline request) now) (null (inbound-poll entry)))
              ;; Expired completed entries can go; unfinished actor work still consumes capacity.
              (remhash key (mesh-inbound mesh)))
             ((inbound-poll entry)
              (multiple-value-bind (result disposition)
                  (handler-case (funcall (inbound-poll entry))
                    (error () (values (make-result :outcome-unknown) :unsettled)))
                (when result
                  (unless (and (result-p result)
                               (<= (message-size (encode-message request result)) (config-max-message-bytes config)))
                    (setf result (make-result :protocol-error)))
                  (unless (authorized-p mesh (inbound-peer entry) request)
                    (setf result (make-result (if (operation-retry-safe (request-operation-spec mesh request))
                                                 :forbidden :outcome-unknown))))
                  (let ((first-result-p (null (inbound-result entry))))
                    (setf (inbound-result entry) result)
                    (unless (eq disposition :unsettled) (setf (inbound-poll entry) nil))
                    (when first-result-p (setf (inbound-reply-pending entry) t)))))))))
       (mesh-inbound mesh))
      (maphash (lambda (key entry) (declare (ignore key)) (send-cached-result mesh entry now))
               (mesh-inbound mesh))
      (maphash
       (lambda (id p)
         (declare (ignore id))
         (unless (pending-result p)
           (let ((spec (request-operation-spec mesh (pending-request p))))
             (cond
               ((<= (request-deadline (pending-request p)) now)
                (setf (pending-result p)
                      (make-result (if (operation-retry-safe spec) :deadline-exceeded :outcome-unknown))))
               ((not (authorized-p mesh (pending-peer p) (pending-request p)))
                (setf (pending-result p) (make-result (if (operation-retry-safe spec) :forbidden :outcome-unknown))))
               ((and (eq (mesh-state mesh) :running) (operation-retry-safe spec)
                     (< (pending-attempts p) (config-max-attempts config)) (<= (pending-next-retry p) now))
                (incf (pending-attempts p))
                (setf (pending-next-retry p) (+ now (config-retry-ms config)))
                (safe-send mesh (pending-peer p) (pending-frames p)))))))
       (mesh-pending mesh))))
  (mesh-status mesh))

(defmethod print-object ((request request) stream)
  (print-unreadable-object (request stream :type t) (write-string "payload redacted" stream)))
(defmethod print-object ((result result) stream)
  (print-unreadable-object (result stream :type t) (princ (result-status result) stream)))
