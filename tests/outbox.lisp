(load "runtime/package.lisp")
(load "runtime/outbox.lisp")

(let ((checks 0))
  (flet ((check (value) (incf checks) (assert value)))
    (let ((now 1000)
          (path #P"/tmp/starintel-edge-outbox-persist.queue"))
      (let ((queue (star.edge.outbox:make-outbox :path path :clock (lambda () now))))
        (check (eq :enqueued
                   (star.edge.outbox:outbox-enqueue queue "obs-1" "star://local/sync" "payload")))
        (check (eq :duplicate
                   (star.edge.outbox:outbox-enqueue queue "obs-1" "other" "other")))
        (check (= 1 (getf (star.edge.outbox:outbox-stats queue) :items)))
        (check (eq :deferred
                   (star.edge.outbox:outbox-retry queue "obs-1" 30 "offline")))
        (check (null (star.edge.outbox:outbox-next-ready queue))))
      (incf now 29)
      (let ((queue (star.edge.outbox:make-outbox :path path :clock (lambda () now))))
        (check (null (star.edge.outbox:outbox-next-ready queue)))
        (check (= 1 (getf (star.edge.outbox:outbox-stats queue) :deferred))))
      (incf now 1)
      (let* ((queue (star.edge.outbox:make-outbox :path path :clock (lambda () now)))
             (entry (star.edge.outbox:outbox-next-ready queue)))
        (check (equal "obs-1" (getf entry :id)))
        (check (equal "star://local/sync" (getf entry :route)))
        (check (equal "payload" (getf entry :payload)))
        (check (= 1 (getf entry :attempts)))
        (check (equal "offline" (getf entry :last-error)))
        (check (eq :acked (star.edge.outbox:outbox-ack queue "obs-1")))
        (check (null (star.edge.outbox:outbox-next-ready queue))))
      (let ((queue (star.edge.outbox:make-outbox :path path :clock (lambda () now))))
        (check (= 0 (getf (star.edge.outbox:outbox-stats queue) :items)))
        (check (eq :missing (star.edge.outbox:outbox-ack queue "obs-1")))))

    (let* ((path #P"/tmp/starintel-edge-outbox-bounds.queue")
           (queue (star.edge.outbox:make-outbox
                   :path path :max-items 1 :max-bytes 32 :clock (lambda () 2000))))
      (check (eq :enqueued (star.edge.outbox:outbox-enqueue queue "a" "r" "ok")))
      (check (handler-case
                 (progn
                   (star.edge.outbox:outbox-enqueue queue "b" "r" "ok")
                   nil)
               (star.edge.outbox:outbox-capacity-exceeded () t)))
      (check (= 1 (getf (star.edge.outbox:outbox-stats queue) :items)))
      (check (eq :acked (star.edge.outbox:outbox-ack queue "a"))))

    (let* ((path #P"/tmp/starintel-edge-outbox-bytes.queue")
           (queue (star.edge.outbox:make-outbox
                   :path path :max-items 8 :max-bytes 4 :clock (lambda () 3000))))
      (check (handler-case
                 (progn
                   (star.edge.outbox:outbox-enqueue queue "i" "r" "euro")
                   nil)
               (star.edge.outbox:outbox-capacity-exceeded () t)))
      (check (= 0 (getf (star.edge.outbox:outbox-stats queue) :items))))

    (format t "~D durable outbox checks passed.~%" checks)))
