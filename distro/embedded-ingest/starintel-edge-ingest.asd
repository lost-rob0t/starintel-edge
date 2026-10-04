(asdf:defsystem "starintel-edge-ingest/client"
  :description "Common Lisp client for the StarIntel Edge ingest service"
  :version "0.1.0"
  :license "GPL-3.0-or-later"
  :depends-on ("jsown" "pzmq")
  :serial t
  :components ((:file "package")
               (:file "protocol")
               (:file "client")))

(asdf:defsystem "starintel-edge-ingest"
  :description "Loopback ZeroMQ to Tek9 ingest service for the StarIntel Edge distro"
  :version "0.1.0"
  :license "GPL-3.0-or-later"
  :depends-on ("babel" "starintel-edge-ingest/client" "tek9")
  :serial t
  :components ((:file "service")))
