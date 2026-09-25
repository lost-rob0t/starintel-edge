;;;; Canonical StarIntel Edge systems.
;;;;
;;;; The starintel-edge-runtime system adapts reusable runtime code from
;;;; starintel-server@f8e20c0b5629a34580c937a5e9ec56834e324802 (GPL-3.0-or-later,
;;;; Copyright (C) 2024 nsaspy): source/actors.lisp and the star.runtime layer of
;;;; source/runtime-lifecycle.lisp. Server-only transport (RabbitMQ, CouchDB) and
;;;; frontends are deliberately not carried over. See docs/PROVENANCE.md.

(asdf:defsystem "starintel-edge"
  :description "Canonical StarIntel edge host contract; not an actor engine"
  :version "0.1.0"
  :license "GPL-3.0-or-later"
  :serial t
  :components ((:file "package") (:file "host")))

(asdf:defsystem "starintel-edge/runtime"
  :description "Canonical StarIntel edge runtime: Sento actor supervision, managed lifecycle, bounded durable outbox, power policy, Linux host backend"
  :version "0.1.0"
  :license "GPL-3.0-or-later"
  :depends-on (#:sento #:bordeaux-threads)
  :serial t
  :components ((:file "runtime-package")
               (:file "actors")
               (:file "lifecycle")
               (:file "outbox")
               (:file "power")
               (:file "linux")))
