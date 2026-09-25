;;;; Packages for the canonical StarIntel edge runtime.
;;;; Adapted from starintel-server@f8e20c0b source/package.lisp
;;;; (GPL-3.0-or-later, Copyright (C) 2024 nsaspy).

(uiop:define-package #:star.edge.actors
  (:use #:cl)
  (:export
   #:*actor-system*
   #:*actors-start-hook*
   #:add-actors-start-hook
   #:run-actors-start-hook
   #:start-actor-system
   #:stop-actor-system
   #:current-actor-system
   #:actor-of
   #:start-actor-index
   #:register-actor
   #:get-dest-actor
   #:route-target
   #:define-actor
   #:start-publisher
   #:stop-publisher
   #:publish
   #:*publish-timeout-seconds*))

(uiop:define-package #:star.edge.runtime
  (:use #:cl)
  (:import-from #:bordeaux-threads #:make-lock #:with-lock-held #:with-timeout)
  (:export
   #:make-component
   #:component-name
   #:start-runtime
   #:stop-runtime
   #:current-runtime
   #:runtime-state
   #:runtime-live-p
   #:runtime-stop-reason
   #:request-stop
   #:run-until-stopped
   #:install-signal-handlers))

(uiop:define-package #:star.edge.outbox
  (:use #:cl)
  (:export
   #:open-outbox
   #:close-outbox
   #:pending-count
   #:enqueue
   #:pop-pending
   #:ack
   #:purge))

(uiop:define-package #:star.edge.power
  (:use #:cl)
  (:export
   #:make-power-policy
   #:power-decision))

(uiop:define-package #:star.edge.linux
  (:use #:cl)
  (:import-from #:star.edge.host #:make-host #:host-platform)
  (:export
   #:make-linux-host
   #:read-sys-power-state))
