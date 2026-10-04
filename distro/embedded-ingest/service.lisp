(in-package :star.edge.ingest)

(defparameter +default-release+ "0.10.1")
(defconstant +default-maximum-message-bytes+ (* 16 1024 1024))

(defstruct (ingest-server (:constructor %make-ingest-server))
  context socket database endpoint release maximum-message-bytes)

(defun json-object-p (value)
  (and (consp value) (eq (first value) :obj)))

(defun required-string (document field)
  (let ((value (and (json-object-p document)
                    (jsown:val-safe document field))))
    (unless (and (stringp value) (plusp (length value)))
      (fail-ingest "invalidDocument" "~A must be a non-empty string" field))
    value))

(defun receipt (status &key id code)
  (jsown:to-json
   (jsown:new-js
     ("protocol" +receipt-protocol+)
     ("status" status)
     ("id" (or id :null))
     ("code" (or code :null)))))

(defun validate-document (document release)
  "Validate the canonical base envelope owned by the pinned StarIntel release.

This local persistence boundary deliberately does not maintain a second dtype
registry. Dtype-specific validation belongs to Star-Lang before dispatch."
  (unless (json-object-p document)
    (fail-ingest "invalidDocument" "top-level JSON value must be an object"))
  (let ((id (required-string document "id"))
        (schema-version (required-string document "schemaVersion")))
    (required-string document "dataset")
    (required-string document "dtype")
    (unless (string= schema-version release)
      (fail-ingest "unsupportedSchemaVersion"
                   "schemaVersion ~A does not match release ~A"
                   schema-version release))
    id))

(defun handle-document (database json release)
  "Validate and durably upsert one canonical document. Return a receipt JSON string."
  (handler-case
      (let* ((document
               (handler-case (jsown:parse json)
                 (error ()
                   (fail-ingest "decodeFailed" "request is not valid JSON"))))
             (id (validate-document document release)))
        (handler-case
            (tek9:put database (tek9:new-document :id id :value document))
          (error ()
            (fail-ingest "storageFailed" "Tek9 rejected the transaction")))
        (receipt "stored" :id id))
    (ingest-error (condition)
      (receipt "rejected" :code (ingest-error-code condition)))))

(defun make-ingest-server (&key
                             endpoint
                             database-path
                             (release +default-release+)
                             (maximum-message-bytes
                               +default-maximum-message-bytes+))
  (unless (and endpoint
               (or (uiop:string-prefix-p "tcp://127.0.0.1:" endpoint)
                   (uiop:string-prefix-p "tcp://[::1]:" endpoint)))
    (fail-ingest "unsafeEndpoint" "embedded ingest must bind a loopback TCP endpoint"))
  (let* ((database
           (tek9:open-database
            (tek9:new-database
             "starintel"
             :path (uiop:ensure-directory-pathname database-path)
             :durability :full)))
         (context (pzmq:ctx-new))
         (socket (pzmq:socket context :rep)))
    (handler-case
        (progn
          (pzmq:setsockopt socket :linger 0)
          (pzmq:setsockopt socket :maxmsgsize maximum-message-bytes)
          (pzmq:bind socket endpoint)
          (%make-ingest-server
           :context context
           :socket socket
           :database database
           :endpoint (pzmq:getsockopt socket :last-endpoint)
           :release release
           :maximum-message-bytes maximum-message-bytes))
      (error (condition)
        (ignore-errors (pzmq:close socket))
        (ignore-errors (pzmq:ctx-destroy context))
        (ignore-errors (tek9:close-database database))
        (error condition)))))

(defun serve-one (server)
  (let ((message (pzmq:recv-octets (ingest-server-socket server))))
    (pzmq:send
     (ingest-server-socket server)
     (if (> (length message) (ingest-server-maximum-message-bytes server))
         (receipt "rejected" :code "messageTooLarge")
         (handler-case
             (handle-document
              (ingest-server-database server)
              (babel:octets-to-string message :encoding :utf-8)
              (ingest-server-release server))
           (error ()
             (receipt "rejected" :code "decodeFailed")))))))

(defun close-ingest-server (server)
  (when (ingest-server-socket server)
    (pzmq:close (ingest-server-socket server))
    (setf (ingest-server-socket server) nil))
  (when (ingest-server-context server)
    (pzmq:ctx-destroy (ingest-server-context server))
    (setf (ingest-server-context server) nil))
  (when (ingest-server-database server)
    (tek9:close-database (ingest-server-database server))
    (setf (ingest-server-database server) nil))
  (values))

(defun run-server (&key endpoint database-path release maximum-requests)
  (let ((server (make-ingest-server
                 :endpoint endpoint
                 :database-path database-path
                 :release release)))
    (unwind-protect
         (progn
           (format t "STARINTEL_EDGE_INGEST_READY ~A~%"
                   (ingest-server-endpoint server))
           (force-output)
           (loop :for count :from 1
                 :do (serve-one server)
                 :until (and maximum-requests
                             (>= count maximum-requests))))
      (close-ingest-server server))))

(defun environment-integer (name default)
  (let ((value (uiop:getenv name)))
    (if value
        (handler-case
            (let ((parsed (parse-integer value)))
              (if (minusp parsed)
                  (fail-ingest "invalidConfiguration"
                               "~A must be a non-negative integer"
                               name)
                  parsed))
          (parse-error ()
            (fail-ingest "invalidConfiguration"
                         "~A must be a non-negative integer"
                         name)))
        default)))

(defun main ()
  (run-server
   :endpoint (or (uiop:getenv "STARINTEL_EDGE_INGEST_ENDPOINT")
                 "tcp://127.0.0.1:42220")
   :database-path (or (uiop:getenv "STARINTEL_EDGE_DATABASE_PATH")
                      "/var/lib/starintel-edge/tek9/")
   :release (or (uiop:getenv "STARINTEL_SCHEMA_RELEASE")
                +default-release+)
   :maximum-requests
   (let ((limit (environment-integer "STARINTEL_EDGE_MAX_REQUESTS" 0)))
     (and (plusp limit) limit))))
