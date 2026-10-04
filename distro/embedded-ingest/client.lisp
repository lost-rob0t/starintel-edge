(in-package :star.edge.ingest)

(defstruct (ingest-client (:constructor %make-ingest-client))
  context socket endpoint)

(defun safe-client-endpoint-p (endpoint)
  (and (stringp endpoint)
       (or (uiop:string-prefix-p "tcp://127.0.0.1:" endpoint)
           (uiop:string-prefix-p "tcp://[::1]:" endpoint))))

(defun make-ingest-client (&key (endpoint "tcp://127.0.0.1:42220")
                                (timeout-milliseconds 5000))
  "Connect a Common Lisp client to the loopback Edge ingest service."
  (unless (safe-client-endpoint-p endpoint)
    (fail-ingest "unsafeEndpoint" "embedded ingest clients connect only to loopback"))
  (unless (and (integerp timeout-milliseconds) (plusp timeout-milliseconds))
    (fail-ingest "invalidConfiguration" "timeout must be a positive integer"))
  (let* ((context (pzmq:ctx-new))
         (socket (pzmq:socket context :req)))
    (handler-case
        (progn
          (pzmq:setsockopt socket :linger 0)
          (pzmq:setsockopt socket :sndtimeo timeout-milliseconds)
          (pzmq:setsockopt socket :rcvtimeo timeout-milliseconds)
          (pzmq:connect socket endpoint)
          (%make-ingest-client :context context :socket socket :endpoint endpoint))
      (error (condition)
        (ignore-errors (pzmq:close socket))
        (ignore-errors (pzmq:ctx-destroy context))
        (error condition)))))

(defun close-ingest-client (client)
  (when (ingest-client-socket client)
    (pzmq:close (ingest-client-socket client))
    (setf (ingest-client-socket client) nil))
  (when (ingest-client-context client)
    (pzmq:ctx-destroy (ingest-client-context client))
    (setf (ingest-client-context client) nil))
  (values))

(defun ingest-document (client document)
  "Send one complete canonical document and return the parsed receipt object."
  (unless (ingest-client-socket client)
    (fail-ingest "clientClosed" "ingest client is closed"))
  (let ((json (etypecase document
                (string document)
                (cons (jsown:to-json document)))))
    (pzmq:send (ingest-client-socket client) json)
    (jsown:parse (pzmq:recv-string (ingest-client-socket client)))))

(defun pipe-object (client object serializer)
  "Serialize OBJECT to canonical JSON/JSOWN data and pipe it to ingest.

SERIALIZER is explicit so generated Star-Lang bindings remain the authority for
their object types; Edge does not maintain a second dtype registry."
  (unless (functionp serializer)
    (error "Serializer must be a function"))
  (ingest-document client (funcall serializer object)))

(defun make-ingest-document-sink (client &key (serializer #'identity))
  "Adapt CLIENT to STAR.EDGE.SYSTEM's create/edit/ingest document port.

All three operations submit a complete canonical document. Stable-ID edit
semantics are therefore the ingest server's durable upsert, never an Edge-local
partial-patch dialect."
  (unless (functionp serializer)
    (error "Serializer must be a function"))
  (lambda (operation document)
    (unless (member operation '(:create :edit :ingest))
      (error "Unsupported document sink operation: ~S" operation))
    (pipe-object client document serializer)))
