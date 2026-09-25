;;;; Real Linux host backend binding star.edge.host to the edge runtime.
;;;; New upstream code (issue #2). Missing backends return unavailable;
;;;; power state comes from /sys/class/power_supply and is unavailable when
;;;; the hardware does not expose it. Startup is local/offline: nothing here
;;;; requires a network.

(in-package #:star.edge.linux)

(defun read-sys-power-state (sysfs-dir)
  "Read the first battery under SYSDIR. Returns (:source :battery :percent N),
(:source :ac) for mains-only supplies, or (:source :unavailable) when the
kernel exposes nothing this host can read."
  (let ((dir (and sysfs-dir (probe-file sysfs-dir))))
    (if (and dir (uiop:directory-exists-p dir))
        (let ((supplies (remove-if-not #'uiop:directory-exists-p
                                       (uiop:subdirectories dir))))
          (or (loop for supply in supplies
                    for capacity-path = (merge-pathnames "capacity" supply)
                    when (probe-file capacity-path)
                      return (let ((percent (ignore-errors
                                              (parse-integer
                                               (string-trim " \n\r\t"
                                                            (uiop:read-file-string capacity-path))
                                               :junk-allowed t))))
                          (and percent
                               (list :source :battery :percent percent))))
              (if supplies '(:source :ac) '(:source :unavailable))))
        '(:source :unavailable))))

(defun backend-live-p (backend-state)
  (etypecase backend-state
    (null nil)
    (function (and (funcall backend-state) t))
    (symbol (eq backend-state :running))))

(defun linux-backend (power-state-fn backend-state)
  "Effect port for star.edge.host on a Linux host. STATUS/START/STOP reflect
the attached runtime; DISPATCH answers capability reads like power.status.
Payload data is never read or evaluated."
  (lambda (operation payload capability)
    (declare (ignore payload))
    (cond
      ((equal operation "status")
       (if (backend-live-p backend-state)
           (list :status :ok :state :running)
           (list :status :unavailable :reason :runtime-not-attached)))
      ((equal operation "start")
       (if (backend-live-p backend-state)
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

(defun make-linux-host (&key capabilities power-state-fn power-gated-capabilities
                             backend-state)
  "Bind the shared host facade to the real Linux runtime host.
CAPABILITIES is a live discovery function (nil -> no capabilities advertised).
POWER-STATE-FN defaults to the real /sys/class/power_supply reader.
POWER-GATED-CAPABILITIES are dispatched only when the power policy allows;
everything else is not power-gated in this iteration."
  (let ((power-state-fn
          (or power-state-fn
              (lambda () (read-sys-power-state "/sys/class/power_supply/"))))
        (policy (star.edge.power:make-power-policy)))
    (make-host
     :platform "linux-rpi"
     :capabilities capabilities
     :authorize (lambda (capability payload)
                  (declare (ignore payload))
                  (or (not (member capability power-gated-capabilities
                                   :test #'equal))
                      (eq :allow (star.edge.power:power-decision
                                  policy (funcall power-state-fn)))))
     :backend (linux-backend power-state-fn backend-state))))
