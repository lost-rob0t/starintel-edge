;;;; Android ECL adapter backend: process-owned host and the one closed
;;;; request dispatcher the native adapter calls. New upstream code (Android
;;;; ECL runtime artifact). The dispatcher accepts only the closed host
;;;; operation set, treats payload as opaque data, and answers with bounded
;;;; JSON. It never evaluates request data and never fabricates capability.

(in-package #:star.edge.android)

(defvar *adapter-host* nil)
(defvar *adapter-lock* (make-lock "star-edge-android-adapter"))

(defun adapter-host () *adapter-host*)

(defun android-backend (power-state-fn)
  "Effect port for star.edge.host on an Android process. STATUS/STOP reflect
the attached managed runtime; DISPATCH answers advertised capability reads
like power.status. Payload data is never read or evaluated."
  (lambda (operation payload capability)
    (declare (ignore payload))
    (cond
      ((equal operation "status")
       (if (star.edge.runtime:runtime-live-p)
           (list :status :ok :state :running)
           (list :status :unavailable :reason :runtime-not-attached)))
      ((equal operation "start")
       (if (star.edge.runtime:runtime-live-p)
           (list :status :ok :state :running)
           (list :status :unavailable :reason :runtime-not-attached)))
      ((equal operation "stop")
       (list :status :ok :state :stopped))
      ((equal operation "dispatch")
       (cond
         ((equal capability "power.status")
          (list :status :ok :power (funcall power-state-fn)))
         (t (list :status :unavailable :reason :no-backend))))
      (t (list :status :unavailable :reason :no-backend)))))

(defun make-android-host (&key capabilities power-state-fn
                                power-gated-capabilities)
  "Bind the shared host facade to the Android process runtime.
CAPABILITIES is a live discovery function (nil -> nothing advertised).
POWER-STATE-FN defaults to (:source :unavailable): real Android power state
arrives through the platform boundary or not at all, never fabricated.
POWER-GATED-CAPABILITIES are dispatched only when the power policy allows."
  (let ((power-state-fn
          (or power-state-fn (lambda () '(:source :unavailable))))
        (policy (star.edge.power:make-power-policy)))
    (make-host
     :platform "android"
     :capabilities capabilities
     :authorize (lambda (capability payload)
                  (declare (ignore payload))
                  (or (not (member capability power-gated-capabilities
                                   :test #'equal))
                      (eq :allow (star.edge.power:power-decision
                                  policy (funcall power-state-fn)))))
     :backend (android-backend power-state-fn))))

(defun install-adapter-host (&rest args &key capabilities power-state-fn
                                          power-gated-capabilities)
  "Install the one process-owned adapter host. Returns the host."
  (declare (ignore capabilities power-state-fn power-gated-capabilities))
  (with-lock-held (*adapter-lock*)
    (setf *adapter-host* (apply #'make-android-host args))))

;;; Minimal JSON encoding for the closed response shapes: plists with keyword
;;; keys become objects, keyword values become strings, lists of non-plist
;;; values become arrays. No floats, no reading of arbitrary data.

(defun json-escape (string)
  (with-output-to-string (out)
    (loop for ch across string
          do (case ch
               ((#\") (write-string "\\\"" out))
               ((#\\) (write-string "\\\\" out))
               ((#\backspace) (write-string "\\b" out))
               ((#\page) (write-string "\\f" out))
               ((#\newline) (write-string "\\n" out))
               ((#\return) (write-string "\\r" out))
               ((#\tab) (write-string "\\t" out))
               (t (if (< (char-code ch) 32)
                      (format out "\\u~4,'0X" (char-code ch))
                      (write-char ch out)))))))

(defun json-atom (value)
  (etypecase value
    (string (format nil "\"~A\"" (json-escape value)))
    (integer (princ-to-string value))
    (symbol (format nil "\"~A\"" (json-escape (string-downcase
                                               (symbol-name value)))))))

(defun json-plist-p (value)
  (and (consp value)
       (evenp (length value))
       (loop for rest = value then (cddr rest)
             until (null rest)
             always (and (consp rest) (keywordp (first rest))))))

(defun encode-json (value)
  "Encode the closed response shapes to a JSON string."
  (cond
    ((null value) "[]")
    ((json-plist-p value)
     (with-output-to-string (out)
       (write-char #\{ out)
       (loop for rest on value by #'cddr
             for firstp = t then nil
             unless firstp do (write-char #\, out)
             do (format out "\"~A\":~A"
                        (json-escape (string-downcase
                                      (symbol-name (first rest))))
                        (encode-json (second rest))))
       (write-char #\} out)))
    ((consp value)
     (format nil "[~{~A~^,~}]" (mapcar #'encode-json value)))
    (t (json-atom value))))

(defun actor-roundtrip ()
  "Exercise one real local Sento actor without using a network transport."
  (let ((started-here (null (star.edge.actors:current-actor-system)))
        (lock (bordeaux-threads:make-lock "android-actor-roundtrip"))
        (seen nil))
    (unwind-protect
         (handler-case
             (progn
               (when started-here
                 (star.edge.actors:start-actor-system :workers 1))
               (let ((actor
                       (star.edge.actors:actor-of
                        :name "android-runtime-probe"
                        :receive
                        (lambda (message)
                          (bordeaux-threads:with-lock-held (lock)
                            (setf seen message))))))
                 (star.edge.actors:register-actor "android-runtime-probe" actor)
                 (star.edge.actors:route-target "android-local" "android-runtime-probe"))
               (let ((deadline (+ (get-internal-real-time)
                                  internal-time-units-per-second)))
                 (loop until (bordeaux-threads:with-lock-held (lock) seen)
                       do (when (> (get-internal-real-time) deadline)
                            (error "Local actor round-trip timed out"))
                          (sleep 0.01)))
               '(:status :ok :actor :roundtrip :message "android-local"))
           (error ()
             '(:status :error :reason :actor-roundtrip-failed)))
      (when started-here
        (star.edge.actors:stop-actor-system)))))

(defun handle-request (operation payload capability)
  "The one closed dispatcher the native adapter calls. OPERATION and
CAPABILITY are strings (nil/empty capability means none); PAYLOAD is opaque
data and is never read or evaluated. Returns a bounded JSON response string."
  (cond
    ((string= operation "service.status")
     (encode-json (service-status)))
    ((string= operation "service.stop")
     (if (stop-service-runtime)
         (encode-json '(:status :ok :state :stopped))
         (encode-json '(:status :error :reason :managed-shutdown-failed))))
    ((string= operation "runtime.ping")
     (encode-json '(:status :ok
                    :runtime :starintel-edge
                    :adapter-abi 1
                    :platform :android)))
    ((string= operation "actor.roundtrip")
     (encode-json (actor-roundtrip)))
    (t
     (let ((host *adapter-host*))
       (if (null host)
           "{\"status\":\"unavailable\",\"reason\":\"runtime-not-attached\"}"
           (let ((result (call-host host operation payload
                                    (and (stringp capability)
                                         (plusp (length capability))
                                         capability))))
             (encode-json result)))))))
