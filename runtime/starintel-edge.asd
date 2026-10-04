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
  :depends-on (#:sento #:bordeaux-threads #:starintel-edge
               #:starintel-edge/system-api)
  :serial t
  :components ((:file "runtime-package")
               (:file "actors")
               (:file "lifecycle")
               (:file "outbox")
               (:file "power")
               (:file "linux")
               (:file "android")
               (:file "android-service")))

(asdf:defsystem "starintel-edge/system-api"
  :description "Typed Attax-OS system capabilities for Debian, NixOS, and Termux"
  :version "0.1.0"
  :license "GPL-3.0-or-later"
  :serial t
  :components ((:file "system-package")
               (:file "system-api")))

(asdf:defsystem "starintel-edge/mesh"
  :description "Private bounded actor transport semantics; host owns lifecycle"
  :depends-on ("starintel-edge")
  :serial t
  :components ((:file "mesh-package") (:file "mesh")))

(asdf:defsystem "starintel-edge/mesh-zmq"
  :description "Optional CURVE/ZAP libzmq private transport (not Android ART proof)"
  :depends-on ("starintel-edge/mesh" "cffi" "bordeaux-threads")
  :serial t
  :components ((:file "mesh-zmq")))

(asdf:defsystem "starintel-edge/mesh-sento"
  :description "Existing Sento actor registry/async ask integration"
  :depends-on ("starintel-edge/mesh" "sento")
  :serial t
  :components ((:file "mesh-sento")))

(asdf:defsystem "starintel-edge/mesh-runtime"
  :description "Private transport owner under the existing Edge component lifecycle"
  :depends-on ("starintel-edge/runtime" "starintel-edge/mesh-sento")
  :serial t
  :components ((:file "mesh-runtime")))
