;;;; StarIntel Edge contract + runtime tests.
;;;; Runtime suites adapt semantics from starintel-server@f8e20c0b
;;;; t/runtime-lifecycle-test.lisp and t/target-routing-test.lisp.
;;;; Run: sbcl --script tests/runtime.lisp   (from repository root)

(require :asdf)
;; sbcl --script skips rc files, so quicklisp's registry may be inactive:
;; try ASDF first, then fall back to loading quicklisp explicitly.
(handler-case (asdf:load-system :sento)
  (error ()
    (cond ((probe-file (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
           (load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
           (funcall (find-symbol "QUICKLOAD" :ql) "sento"))
          ((find-package :ql)
           (funcall (find-symbol "QUICKLOAD" :ql) "sento"))
          (t (error "sento is required by starintel-edge/runtime; install it via quicklisp or nix")))))

(asdf:initialize-source-registry
 `(:source-registry (:directory ,(uiop:merge-pathnames* "runtime/" (uiop:getcwd)))
   :inherit-configuration))
(asdf:load-system :starintel-edge)
(asdf:load-system "starintel-edge/runtime")

(load "runtime/package.lisp")
(load "runtime/host.lisp")

(let ((checks 0))
  (flet ((check (value) (incf checks) (assert value)))
    ;; --- facade contract (existing) ---
    (let ((host (star.edge.host:make-host :platform "android")))
      (check (equal (star.edge.host:call-host host "start")
                    '(:status :unavailable :reason :runtime-not-attached)))
      (check (null (star.edge.host:host-capabilities host)))
      (check (equal (getf (star.edge.host:call-host host "eval") :reason)
                    :unknown-operation)))
    (let* ((seen nil) (allowed t) (advertised '("camera.photo"))
           (host (star.edge.host:make-host
                  :platform "meta-companion"
                  :backend (lambda (op payload cap)
                             (push (list op payload cap) seen) :forwarded)
                  :capabilities (lambda () advertised)
                  :authorize (lambda (cap payload) (declare (ignore cap payload)) allowed))))
      (check (eq :forwarded (star.edge.host:call-host host "status")))
      (check (eq :forwarded (star.edge.host:call-host host "dispatch" "opaque" "camera.photo")))
      (check (equal (first seen) '("dispatch" "opaque" "camera.photo")))
      (setf allowed nil)
      (check (eq :denied (getf (star.edge.host:call-host host "dispatch" nil "camera.photo") :status)))
      (check (= 2 (length seen)))
      (setf allowed :truthy)
      (check (eq :denied (getf (star.edge.host:call-host host "dispatch" nil "camera.photo") :status)))
      (setf allowed t advertised nil)
      (check (eq :denied (getf (star.edge.host:call-host host "dispatch" nil "camera.photo") :status)))
      (check (eq :denied (getf (star.edge.host:call-host host "dispatch") :status)))
      (check (= 2 (length seen))))
    (let ((host (star.edge.host:make-host :platform "wearos"
                 :backend (lambda (&rest args) (declare (ignore args)) :forwarded)
                 :capabilities (lambda () '("location.read")))))
      (check (eq :denied (getf (star.edge.host:call-host host "dispatch" nil "location.read") :status))))

    ;; --- license/provenance contract (adapted from server v09-runtime contract) ---
    (check (search "GPL-3.0-or-later"
                   (asdf:system-license (asdf:find-system "starintel-edge/runtime"))))
    (check (search "GPL-3.0-or-later"
                   (asdf:system-license (asdf:find-system :starintel-edge))))

    ;; --- lifecycle (from server t/runtime-lifecycle-test.lisp semantics) ---
    (let ((events nil))
      (labels ((comp (name fail)
                 (star.edge.runtime:make-component
                  name
                  :start (lambda ()
                           (push (list :start name) events)
                           (when fail (error "component ~a failed" name)))
                  :stop (lambda ()
                          (push (list :stop name) events)
                          t))))
        ;; happy path: start all, stop reverse, idempotent stop
        (let ((rt (star.edge.runtime:start-runtime
                   (list (comp "a" nil) (comp "b" nil)))))
          (check (eq :running (star.edge.runtime:runtime-state rt)))
          (check (star.edge.runtime:runtime-live-p rt))
          (check (star.edge.runtime:stop-runtime rt))
          (check (eq :stopped (star.edge.runtime:runtime-state rt)))
          (check (equal events '((:stop "a") (:stop "b") (:start "b") (:start "a")))))
        ;; idempotent stop
        (setf events nil)
        (let ((rt (star.edge.runtime:start-runtime (list (comp "a" nil)))))
          (check (star.edge.runtime:stop-runtime rt))
          (check (star.edge.runtime:stop-runtime rt))
          (check (equal events '((:stop "a") (:start "a")))))
        ;; rollback on partial failure: started components are stopped, none left live
        (setf events nil)
        (let ((rt (star.edge.runtime:start-runtime (list (comp "a" nil) (comp "b" t)))))
          (check (eq :stopped (star.edge.runtime:runtime-state rt)))
          (check (equal events '((:stop "a") (:start "b") (:start "a"))))
          (check (eq :startup-failure (star.edge.runtime:runtime-stop-reason rt))))
        ;; signal-requested stop: request-stop marks reason, stop is graceful
        (let ((rt (star.edge.runtime:start-runtime (list (comp "a" nil)))))
          (star.edge.runtime:request-stop :sigterm)
          (check (eq rt (star.edge.runtime:run-until-stopped rt)))
          (check (eq :stopped (star.edge.runtime:runtime-state rt)))
          (check (eq :sigterm (star.edge.runtime:runtime-stop-reason rt))))
        ;; double start refused
        (let ((rt (star.edge.runtime:start-runtime (list (comp "a" nil)))))
          (handler-case
              (progn (star.edge.runtime:start-runtime (list (comp "b" nil)))
                     (check nil))
            (error () (check t)))
          (star.edge.runtime:stop-runtime rt)
          (setf events nil))))

    ;; --- actors (from server t/target-routing-test.lisp semantics) ---
    (let ((sys (star.edge.actors:start-actor-system :workers 2)))
      (check (not (null sys)))
      (let* ((lock (bt:make-lock "test"))
             (mailbox nil)
             (receiver (star.edge.actors:actor-of
                        :name "test-receiver"
                        :receive (lambda (msg)
                                   (bt:with-lock-held (lock) (push msg mailbox))))))
        (star.edge.actors:register-actor "test-receiver" receiver)
        (check (eq receiver (star.edge.actors:get-dest-actor "test-receiver")))
        (check (null (star.edge.actors:get-dest-actor "no-such-actor")))
        (star.edge.actors:route-target "hello" "test-receiver")
        (star.edge.actors:route-target "hello" "no-such-actor")
        (let ((deadline (+ (get-internal-real-time) internal-time-units-per-second)))
          (loop until (bt:with-lock-held (lock) mailbox)
                do (when (> (get-internal-real-time) deadline)
                     (error "routed target never arrived"))
                   (sleep 0.01)))
        (check (equal (bt:with-lock-held (lock) (first mailbox)) "hello")))
      ;; publish: fail-fast bounded publish through pinned agent
      (let ((sink-seen nil))
        (star.edge.actors:start-publisher
         (lambda (message) (push message sink-seen) :published))
        (check (eq :published (star.edge.actors:publish "outbox-item")))
        (check (equal sink-seen '("outbox-item")))
        (star.edge.actors:stop-publisher)
        ;; publish without publisher fails fast (does not hang)
        (handler-case
            (progn (star.edge.actors:publish "no-sink") (check nil))
          (error () (check t))))
      (star.edge.actors:stop-actor-system)
      (check (null (star.edge.actors:current-actor-system))))

    ;; --- outbox: bounded durable queue with crash recovery ---
    (let ((dir (uiop:temporary-directory)))
      (uiop:with-temporary-file (:pathname p :direction :io :keep t)
        (declare (ignore p))
        ;; scoped test dir under temp
        (let* ((base (uiop:merge-pathnames* "star-edge-outbox-test/" dir))
               (outbox-dir (merge-pathnames "journal/" base)))
          (when (probe-file base) (uiop:delete-directory-tree base :validate t))
          (ensure-directories-exist outbox-dir)
          (unwind-protect
               (let ((ob (star.edge.outbox:open-outbox outbox-dir :capacity 2)))
                 (check (= 0 (star.edge.outbox:pending-count ob)))
                 (check (eq :queued (star.edge.outbox:enqueue ob "op-1" "payload-one")))
                 (check (eq :queued (star.edge.outbox:enqueue ob "op-2" "payload-two")))
                 (check (eq :outbox-full (star.edge.outbox:enqueue ob "op-3" "x")))
                 (check (eq :outbox-full (star.edge.outbox:enqueue ob "op-3" "x")))
                 ;; durability: reopen sees unacked entries (simulates reboot)
                 (star.edge.outbox:close-outbox ob)
                 (let ((recovered (star.edge.outbox:open-outbox outbox-dir :capacity 3)))
                   (check (= 2 (star.edge.outbox:pending-count recovered)))
                   (let ((entry (star.edge.outbox:pop-pending recovered)))
                     (check (equal (first entry) "op-1"))
                     (check (equal (second entry) "payload-one"))
                     ;; crash mid-write: reopen does not lose acked history
                     (star.edge.outbox:ack recovered "op-1")
                     (star.edge.outbox:close-outbox recovered)
                     (let ((after (star.edge.outbox:open-outbox outbox-dir :capacity 3)))
                       (check (= 1 (star.edge.outbox:pending-count after)))
                       (check (equal (first (star.edge.outbox:pop-pending after)) "op-2"))
                       ;; explicit purge clears bounded state
                       (star.edge.outbox:purge after)
                       (check (= 0 (star.edge.outbox:pending-count after)))
                       (check (eq :queued (star.edge.outbox:enqueue after "op-4" "four")))
                       (star.edge.outbox:close-outbox after)))))
            (uiop:delete-directory-tree base :validate t))))

      ;; crash mid-append: partial trailing line is discarded, intact entries survive
      (let* ((base (uiop:merge-pathnames*
                    "star-edge-outbox-crash/" (uiop:temporary-directory)))
             (outbox-dir (merge-pathnames "journal/" base)))
        (when (probe-file base) (uiop:delete-directory-tree base :validate t))
        (ensure-directories-exist outbox-dir)
        (unwind-protect
             (let ((ob (star.edge.outbox:open-outbox outbox-dir :capacity 5)))
               (star.edge.outbox:enqueue ob "keep-1" "intact")
               (star.edge.outbox:close-outbox ob)
               ;; simulate torn write: partial entry appended without fsync/commit
               (with-open-file (f (star.edge.outbox::outbox-journal-path outbox-dir)
                                  :direction :output :if-exists :append)
                 (write-line "(\"torn-2\" \"partial" f))
               (let ((recovered (star.edge.outbox:open-outbox outbox-dir :capacity 5)))
                 (check (= 1 (star.edge.outbox:pending-count recovered)))
                 (check (equal (first (star.edge.outbox:pop-pending recovered)) "keep-1"))
                 (star.edge.outbox:close-outbox recovered)))
          (uiop:delete-directory-tree base :validate t))))

    ;; --- power policy: capability-honest, fail-closed ---
    (let ((policy (star.edge.power:make-power-policy)))
      ;; explicit AC → allow
      (check (eq :allow (star.edge.power:power-decision
                         policy '(:source :ac :percent 55))))
      ;; healthy battery → allow
      (check (eq :allow (star.edge.power:power-decision
                         policy '(:source :battery :percent 80))))
      ;; low battery → defer
      (check (eq :defer (star.edge.power:power-decision
                         policy '(:source :battery :percent 10))))
      ;; unknown power state → defer (fail-closed, never fabricated)
      (check (eq :defer (star.edge.power:power-decision
                         policy '(:source :unavailable))))
      (check (eq :defer (star.edge.power:power-decision policy nil))))
    (let ((policy (star.edge.power:make-power-policy :battery-floor 25)))
      (check (eq :allow (star.edge.power:power-decision
                         policy '(:source :battery :percent 30))))
      (check (eq :defer (star.edge.power:power-decision
                         policy '(:source :battery :percent 24)))))

    ;; --- real Linux host backend ---
    (let ((host (star.edge.linux:make-linux-host)))
      (check (equal "linux-rpi" (star.edge.host:host-platform host)))
      ;; no capability source configured -> unavailable, not simulated
      (check (null (star.edge.host:host-capabilities host)))
      ;; runtime-backed status is real lifecycle state
      (let ((resp (star.edge.host:call-host host "status")))
        (check (eq (getf resp :status) :unavailable))
        (check (eq (getf resp :reason) :runtime-not-attached))))
    (let ((host (star.edge.linux:make-linux-host
                 :power-state-fn
                 (lambda () '(:source :battery :percent 42))
                 :capabilities (lambda () '("power.status"))
                 :backend-state :running)))
      ;; injected capability source is live discovery; dispatch power status returns real state
      (check (equal '("power.status") (star.edge.host:host-capabilities host)))
      (let ((resp (star.edge.host:call-host host "dispatch" nil "power.status")))
        (check (eq (getf resp :status) :ok))
        (check (equal (getf resp :power) '(:source :battery :percent 42))))
      ;; dispatch of an unadvertised capability is denied
      (check (eq :denied
                 (getf (star.edge.host:call-host host "dispatch" nil "camera.photo")
                       :status))))
    ;; /sys power reading: absent hardware -> unavailable (no fabrication)
    (check (equal '(:source :unavailable)
                  (star.edge.linux:read-sys-power-state
                   "/nonexistent/power_supply")))
    ;; fixture-backed sysfs read: real file parsing, real battery semantics
    (let* ((base (uiop:merge-pathnames*
                  "star-edge-sysfs-test/" (uiop:temporary-directory)))
           (bat (merge-pathnames "power_supply/BAT0/" base)))
      (when (probe-file base) (uiop:delete-directory-tree base :validate t))
      (ensure-directories-exist bat)
      (unwind-protect
           (progn
             (with-open-file (f (merge-pathnames "status" bat)
                                :direction :output :if-does-not-exist :create)
               (write-line "Discharging" f))
             (with-open-file (f (merge-pathnames "capacity" bat)
                                :direction :output :if-does-not-exist :create)
               (write-line "42" f))
             (check (equal '(:source :battery :percent 42)
                           (star.edge.linux:read-sys-power-state
                            (merge-pathnames "power_supply/" base)))))
        (uiop:delete-directory-tree base :validate t)))

    (format t "~D Common Lisp host contract and runtime checks passed.~%" checks)))
