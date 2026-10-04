(in-package :cl-user)

(defpackage :star.edge.ingest
  (:use :cl)
  (:export
   #:ingest-error
   #:make-ingest-server
   #:ingest-server-endpoint
   #:serve-one
   #:close-ingest-server
   #:handle-document
   #:make-ingest-client
   #:close-ingest-client
   #:ingest-document
   #:pipe-object
   #:make-ingest-document-sink
   #:run-server
   #:main))
