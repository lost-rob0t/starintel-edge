(in-package #:star.edge.outbox)

(define-condition outbox-error (error)
  ((reason :initarg :reason :reader outbox-error-reason))
  (:report (lambda (condition stream)
             (format stream "Edge outbox error: ~A" (outbox-error-reason condition)))))

(define-condition outbox-corrupt-state (outbox-error) ())
(define-condition outbox-capacity-exceeded (outbox-error) ())

(defstruct (outbox-entry (:constructor %make-outbox-entry))
  (id "" :type string)
  (route "" :type string)
  (payload "" :type string)
  (enqueued-at 0 :type integer)
  (attempts 0 :type integer)
  (available-at 0 :type integer)
  (last-error nil :type (or null string)))

(defstruct (outbox (:constructor %make-outbox))
  path
  (max-items 1024 :type integer)
  (max-bytes (* 8 1024 1024) :type integer)
  (clock #'get-universal-time :type function)
  (entries nil :type list))

(defun %positive-integer-p (value)
  (and (integerp value) (> value 0)))

(defun %path-string (path)
  (etypecase path
    (string path)
    (pathname (namestring path))))

(defun %backup-path (path)
  (concatenate 'string (%path-string path) ".bak"))

(defun %temporary-path (path)
  (concatenate 'string (%path-string path) ".tmp"))

(defun %utf8-octet-length (string)
  (loop for character across string
        for code = (char-code character)
        sum (cond
              ((<= code #x7f) 1)
              ((<= code #x7ff) 2)
              ((<= code #xffff) 3)
              (t 4))))

(defun %entry-bytes (entry)
  (+ (%utf8-octet-length (outbox-entry-id entry))
     (%utf8-octet-length (outbox-entry-route entry))
     (%utf8-octet-length (outbox-entry-payload entry))
     (if (outbox-entry-last-error entry)
         (%utf8-octet-length (outbox-entry-last-error entry))
         0)))

(defun %queue-bytes (entries)
  (reduce #'+ entries :key #'%entry-bytes :initial-value 0))

(defun %entry->state (entry)
  (list :id (outbox-entry-id entry)
        :route (outbox-entry-route entry)
        :payload (outbox-entry-payload entry)
        :enqueued-at (outbox-entry-enqueued-at entry)
        :attempts (outbox-entry-attempts entry)
        :available-at (outbox-entry-available-at entry)
        :last-error (outbox-entry-last-error entry)))

(defun %state->entry (state)
  (unless (and (listp state)
               (stringp (getf state :id))
               (plusp (length (getf state :id)))
               (stringp (getf state :route))
               (plusp (length (getf state :route)))
               (stringp (getf state :payload))
               (integerp (getf state :enqueued-at))
               (not (minusp (getf state :enqueued-at)))
               (integerp (getf state :attempts))
               (not (minusp (getf state :attempts)))
               (integerp (getf state :available-at))
               (not (minusp (getf state :available-at)))
               (or (null (getf state :last-error))
                   (stringp (getf state :last-error))))
    (error 'outbox-corrupt-state :reason :invalid-entry))
  (%make-outbox-entry
   :id (copy-seq (getf state :id))
   :route (copy-seq (getf state :route))
   :payload (copy-seq (getf state :payload))
   :enqueued-at (getf state :enqueued-at)
   :attempts (getf state :attempts)
   :available-at (getf state :available-at)
   :last-error (and (getf state :last-error)
                    (copy-seq (getf state :last-error)))))

(defun %state-form (outbox)
  (list :version 1
        :entries (mapcar #'%entry->state (outbox-entries outbox))))

(defun %read-state-file (path)
  (with-open-file (stream path :direction :input)
    (let ((*read-eval* nil))
      (let ((state (read stream nil :eof)))
        (when (eq state :eof)
          (error 'outbox-corrupt-state :reason :empty-state))
        (unless (eq (read stream nil :eof) :eof)
          (error 'outbox-corrupt-state :reason :trailing-data))
        state))))

(defun %decode-state (state)
  (unless (and (listp state)
               (eql (getf state :version) 1)
               (listp (getf state :entries)))
    (error 'outbox-corrupt-state :reason :invalid-state))
  (let ((entries (mapcar #'%state->entry (getf state :entries))))
    (unless (= (length entries)
               (length (remove-duplicates entries
                                          :key #'outbox-entry-id
                                          :test #'equal)))
      (error 'outbox-corrupt-state :reason :duplicate-id))
    entries))

(defun %load-entries (path)
  (let ((primary (%path-string path))
        (backup (%backup-path path)))
    (cond
      ((probe-file primary)
       (handler-case
           (%decode-state (%read-state-file primary))
         (error (primary-error)
           (if (probe-file backup)
               (handler-case
                   (%decode-state (%read-state-file backup))
                 (error ()
                   (error 'outbox-corrupt-state :reason primary-error)))
               (error 'outbox-corrupt-state :reason primary-error)))))
      ((probe-file backup)
       (%decode-state (%read-state-file backup)))
      (t nil))))

(defun %persist (outbox)
  (let* ((path (%path-string (outbox-path outbox)))
         (temporary (%temporary-path path))
         (backup (%backup-path path)))
    (ensure-directories-exist path)
    (when (probe-file temporary)
      (delete-file temporary))
    (with-open-file (stream temporary
                            :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
      (let ((*print-readably* t)
            (*print-pretty* nil))
        (write (%state-form outbox) :stream stream)
        (terpri stream)
        (finish-output stream)))
    (when (probe-file backup)
      (delete-file backup))
    (when (probe-file path)
      (rename-file path backup))
    (handler-case
        (rename-file temporary path)
      (error (condition)
        (when (and (not (probe-file path)) (probe-file backup))
          (rename-file backup path))
        (error condition)))
    (when (probe-file backup)
      (delete-file backup))
    t))

(defun %validate-capacity (outbox entries)
  (when (> (length entries) (outbox-max-items outbox))
    (error 'outbox-capacity-exceeded :reason :max-items))
  (when (> (%queue-bytes entries) (outbox-max-bytes outbox))
    (error 'outbox-capacity-exceeded :reason :max-bytes))
  t)

(defun make-outbox (&key path (max-items 1024) (max-bytes (* 8 1024 1024))
                         (clock #'get-universal-time))
  "Open a bounded single-process durable outbox.

Entries are opaque strings: ID is the idempotency key, ROUTE is a typed logical
route, and PAYLOAD is serialized StarIntel data. The queue never evaluates
payloads. PLATFORM HOSTS remain responsible for app-private permissions and for
serializing calls into this object."
  (unless path
    (error 'outbox-error :reason :path-required))
  (unless (%positive-integer-p max-items)
    (error 'outbox-error :reason :invalid-max-items))
  (unless (%positive-integer-p max-bytes)
    (error 'outbox-error :reason :invalid-max-bytes))
  (unless (functionp clock)
    (error 'outbox-error :reason :invalid-clock))
  (let ((outbox (%make-outbox :path path
                              :max-items max-items
                              :max-bytes max-bytes
                              :clock clock
                              :entries (%load-entries path))))
    (%validate-capacity outbox (outbox-entries outbox))
    outbox))

(defun %find-entry (outbox id)
  (find id (outbox-entries outbox) :key #'outbox-entry-id :test #'equal))

(defun outbox-enqueue (outbox id route payload)
  "Persist one idempotent outbound item. Returns :ENQUEUED or :DUPLICATE."
  (unless (and (stringp id) (plusp (length id)))
    (error 'outbox-error :reason :invalid-id))
  (unless (and (stringp route) (plusp (length route)))
    (error 'outbox-error :reason :invalid-route))
  (unless (stringp payload)
    (error 'outbox-error :reason :invalid-payload))
  (when (%find-entry outbox id)
    (return-from outbox-enqueue :duplicate))
  (let* ((now (funcall (outbox-clock outbox)))
         (entry (%make-outbox-entry :id (copy-seq id)
                                    :route (copy-seq route)
                                    :payload (copy-seq payload)
                                    :enqueued-at now
                                    :available-at now))
         (new-entries (append (outbox-entries outbox) (list entry))))
    (%validate-capacity outbox new-entries)
    (setf (outbox-entries outbox) new-entries)
    (handler-case
        (%persist outbox)
      (error (condition)
        (setf (outbox-entries outbox) (butlast new-entries))
        (error condition)))
    :enqueued))

(defun %entry-snapshot (entry)
  (list :id (copy-seq (outbox-entry-id entry))
        :route (copy-seq (outbox-entry-route entry))
        :payload (copy-seq (outbox-entry-payload entry))
        :enqueued-at (outbox-entry-enqueued-at entry)
        :attempts (outbox-entry-attempts entry)
        :available-at (outbox-entry-available-at entry)
        :last-error (and (outbox-entry-last-error entry)
                         (copy-seq (outbox-entry-last-error entry)))))

(defun outbox-next-ready (outbox)
  "Return the oldest retry-eligible entry as a copied plist, or NIL."
  (let ((now (funcall (outbox-clock outbox))))
    (loop for entry in (outbox-entries outbox)
          when (<= (outbox-entry-available-at entry) now)
            do (return (%entry-snapshot entry)))))

(defun outbox-ack (outbox id)
  "Atomically remove ID after remote acknowledgement. Missing IDs are harmless."
  (let ((entry (%find-entry outbox id)))
    (unless entry
      (return-from outbox-ack :missing))
    (let ((old-entries (outbox-entries outbox)))
      (setf (outbox-entries outbox)
            (remove entry old-entries :test #'eq :count 1))
      (handler-case
          (%persist outbox)
        (error (condition)
          (setf (outbox-entries outbox) old-entries)
          (error condition))))
    :acked))

(defun outbox-retry (outbox id delay-seconds &optional reason)
  "Record a failed attempt and defer it by DELAY-SECONDS."
  (unless (and (integerp delay-seconds) (not (minusp delay-seconds)))
    (error 'outbox-error :reason :invalid-delay))
  (unless (or (null reason) (stringp reason))
    (error 'outbox-error :reason :invalid-reason))
  (let ((entry (%find-entry outbox id)))
    (unless entry
      (return-from outbox-retry :missing))
    (let ((old-attempts (outbox-entry-attempts entry))
          (old-available-at (outbox-entry-available-at entry))
          (old-last-error (outbox-entry-last-error entry)))
      (setf (outbox-entry-attempts entry) (1+ old-attempts)
            (outbox-entry-available-at entry)
            (+ (funcall (outbox-clock outbox)) delay-seconds)
            (outbox-entry-last-error entry) (and reason (copy-seq reason)))
      (%validate-capacity outbox (outbox-entries outbox))
      (handler-case
          (%persist outbox)
        (error (condition)
          (setf (outbox-entry-attempts entry) old-attempts
                (outbox-entry-available-at entry) old-available-at
                (outbox-entry-last-error entry) old-last-error)
          (error condition))))
    :deferred))

(defun outbox-stats (outbox)
  "Return non-sensitive queue observability; payloads and routes are omitted."
  (let* ((entries (outbox-entries outbox))
         (now (funcall (outbox-clock outbox)))
         (ready (count-if (lambda (entry)
                            (<= (outbox-entry-available-at entry) now))
                          entries)))
    (list :items (length entries)
          :ready ready
          :deferred (- (length entries) ready)
          :bytes (%queue-bytes entries)
          :max-items (outbox-max-items outbox)
          :max-bytes (outbox-max-bytes outbox))))
