(asdf:defsystem "starintel-edge"
  :description "Canonical StarIntel edge host contract and offline runtime primitives"
  :version "0.2.0"
  :serial t
  :components ((:file "package") (:file "host") (:file "outbox")))
