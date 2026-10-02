(defpackage #:star.edge.host
  (:use #:cl)
  (:export #:make-host #:call-host #:host-capabilities))

(defpackage #:star.edge.outbox
  (:use #:cl)
  (:export #:make-outbox
           #:outbox-enqueue
           #:outbox-next-ready
           #:outbox-ack
           #:outbox-retry
           #:outbox-stats
           #:outbox-error
           #:outbox-error-reason
           #:outbox-corrupt-state
           #:outbox-capacity-exceeded))
