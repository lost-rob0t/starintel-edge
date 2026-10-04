;;;; Bounded durable outbox: append-only journal with fsync, refuse-when-full
;;;; capacity, and crash recovery of intact entries.
;;;; New upstream code (issue #2): the server-side outbox in
;;;; starintel-server@f8e20c0b is CouchDB-coupled and stays downstream.

(in-package #:star.edge.outbox)

#+sbcl (require :sb-posix)

(defstruct (outbox
             (:constructor %make-outbox (path journal capacity pending)))
  path
  journal
  capacity
  pending)

(defun outbox-journal-path (directory)
  (merge-pathnames "journal.log" (pathname directory)))

(defun entry-line-p (line)
  "Parse one journal line; NIL when the entry is torn (crash mid-append)."
  (let ((start (position-if (lambda (c) (not (char= c #\space))) line)))
    (when start
      (ignore-errors
        (multiple-value-bind (form end)
            (read-from-string line t nil :start start)
          (and (consp form)
               (= end (length line))
               form))))))

(defun read-journal (path)
  "Return the intact entries of PATH, discarding a torn trailing write."
  (when (probe-file path)
    (with-open-file (stream path :direction :input :if-does-not-exist nil)
      (when stream
        (loop for line = (read-line stream nil nil)
              while line
              for entry = (entry-line-p line)
              when entry collect entry)))))

(defun rewrite-journal (path entries)
  "Atomically rewrite the journal to ENTRIES and fsync (ack/purge compaction)."
  (let ((tmp (merge-pathnames (make-pathname :type "log.tmp") path)))
    (with-open-file (stream tmp
                            :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
      (dolist (entry entries)
        (prin1 entry stream)
        (terpri stream))
      (finish-output stream)
      #+sbcl (sb-posix:fsync (sb-sys:fd-stream-fd stream)))
    (rename-file tmp path))
  t)

(defun open-outbox (directory &key (capacity 256))
  "Open (or recover) the outbox rooted at DIRECTORY/journal.log."
  (ensure-directories-exist directory)
  (let* ((path (outbox-journal-path directory))
         (entries (read-journal path)))
    (when (probe-file path)
      (rewrite-journal path entries))
    (%make-outbox (pathname directory) path capacity entries)))

(defun close-outbox (outbox)
  (setf (outbox-journal outbox) nil
        (outbox-pending outbox) nil)
  t)

(defun pending-count (outbox)
  (length (outbox-pending outbox)))

(defun enqueue (outbox id payload)
  "Durably append (ID PAYLOAD); refuse with :OUTBOX-FULL when at capacity."
  (when (>= (pending-count outbox) (outbox-capacity outbox))
    (return-from enqueue :outbox-full))
  (unless (outbox-journal outbox)
    (error "Outbox is closed"))
  (let ((entry (list id payload)))
    (with-open-file (stream (outbox-journal outbox)
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (prin1 entry stream)
      (terpri stream)
      (finish-output stream)
      #+sbcl (sb-posix:fsync (sb-sys:fd-stream-fd stream)))
    (setf (outbox-pending outbox)
          (append (outbox-pending outbox) (list entry)))
    :queued))

(defun pop-pending (outbox)
  "Remove and return the oldest pending entry, (ID PAYLOAD), or NIL."
  (let ((entry (first (outbox-pending outbox))))
    (when entry
      (setf (outbox-pending outbox) (rest (outbox-pending outbox)))
      entry)))

(defun ack (outbox id)
  "Durably remove the entry with ID from the journal."
  (setf (outbox-pending outbox)
        (remove id (outbox-pending outbox) :key #'first :test #'equal))
  (rewrite-journal (outbox-journal outbox) (outbox-pending outbox)))

(defun purge (outbox)
  "Explicitly clear all pending entries."
  (setf (outbox-pending outbox) nil)
  (rewrite-journal (outbox-journal outbox) nil))
