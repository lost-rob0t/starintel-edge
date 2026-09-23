(in-package #:star.edge.host)

;; No actor implementation, reader/eval endpoint or platform emulation here.
;; Runtime lifecycle is delegated to the one authoritative Lisp backend.
(defstruct (host (:constructor %make-host))
  (platform nil :read-only t)
  (backend nil :read-only t)
  (capability-source nil :read-only t)
  (authorize nil :read-only t))

(defun make-host (&key platform backend capabilities authorize)
  "Bind trusted effect ports. BACKEND takes (operation payload capability).
CAPABILITIES is a zero-argument live discovery function. AUTHORIZE takes
(capability payload), rechecks OS permission and policy, and must return T.
NIL ports are unavailable/deny, never a simulated working runtime. Calls must
be serialized by the platform host; ports enforce their own atomic effects."
  (unless (member platform '("linux-rpi" "android" "wearos" "android-glasses"
                             "glasses-companion" "meta-companion") :test #'equal)
    (error "Unknown edge platform: ~S" platform))
  (dolist (port (list backend capabilities authorize))
    (unless (or (null port) (functionp port)) (error "Invalid host port")))
  (%make-host :platform platform :backend backend
              :capability-source capabilities :authorize authorize))

(defun host-capabilities (host)
  "Return a copied, live adapter capability list. This does not grant access."
  (if (and (host-backend host) (host-capability-source host))
      (let ((result (funcall (host-capability-source host))))
        (unless (and (listp result) (every #'stringp result))
          (error "Capability port returned invalid data"))
        (mapcar #'copy-seq (remove-duplicates result :test #'equal)))
      nil))

(defun call-host (host operation &optional payload capability)
  "Forward typed operations; PAYLOAD is data and is never read or evaluated.
This is an in-process trusted host boundary, not an authenticated network API.
Backends must recheck permission at the actual effect to close revocation races."
  (cond
    ((not (member operation '("status" "start" "suspend" "resume" "stop" "dispatch")
                  :test #'equal))
     (list :status :error :reason :unknown-operation))
    ((null (host-backend host))
     (list :status :unavailable :reason :runtime-not-attached))
    ((and (equal operation "dispatch")
          (not (and (stringp capability)
                    (member capability (host-capabilities host) :test #'equal)
                    (host-authorize host)
                    (eq t (funcall (host-authorize host) capability payload)))))
     (list :status :denied :reason :capability-not-authorized))
    (t (funcall (host-backend host) operation payload capability))))
