(require :asdf)
(asdf:load-system :starintel-edge-ingest)
(asdf:load-system :bordeaux-threads)

(defun check (value message)
  (unless value (error "embedded ingest test failed: ~A" message)))

(let* ((root (uiop:ensure-directory-pathname
              (or (uiop:getenv "STARINTEL_EDGE_TEST_TMPDIR")
                  (uiop:temporary-directory))))
       (database-path (merge-pathnames "tek9/" root))
       (server (star.edge.ingest:make-ingest-server
                :endpoint "tcp://127.0.0.1:*"
                :database-path database-path
                :release "0.10.1"))
       (document
         "{\"id\":\"starintel:test:edge-ingest\",\"dataset\":\"test\",\"dtype\":\"relation\",\"schemaVersion\":\"0.10.1\"}"))
  (unwind-protect
       (progn
         (let* ((server-thread
                  (bordeaux-threads:make-thread
                   (lambda () (star.edge.ingest:serve-one server))))
                (client (star.edge.ingest:make-ingest-client
                         :endpoint (star.edge.ingest:ingest-server-endpoint server))))
           (unwind-protect
                (let ((reply (star.edge.ingest:ingest-document client document)))
                  (check (string= "STARINTEL-EDGE-INGEST/1"
                                  (jsown:val reply "protocol"))
                         "receipt protocol")
                  (check (string= "stored" (jsown:val reply "status"))
                         "stored receipt"))
             (star.edge.ingest:close-ingest-client client))
           (bordeaux-threads:join-thread server-thread))
         (star.edge.ingest:close-ingest-server server)
         (let ((database
                 (tek9:open-database
                  (tek9:new-database "starintel" :path database-path))))
           (unwind-protect
                (check (tek9:fetch* database "starintel:test:edge-ingest")
                       "document survives close and reopen")
             (tek9:close-database database)))
         (let ((database
                 (tek9:open-database
                  (tek9:new-database "starintel" :path database-path))))
           (unwind-protect
                (progn
                  (check
                   (search "unsupportedSchemaVersion"
                           (star.edge.ingest:handle-document
                            database
                            "{\"id\":\"old\",\"dataset\":\"test\",\"dtype\":\"relation\",\"schemaVersion\":\"0.9.0\"}"
                            "0.10.1"))
                   "legacy input fails closed")
                  (check
                   (search "decodeFailed"
                           (star.edge.ingest:handle-document
                            database "{" "0.10.1"))
                   "malformed JSON gets a typed rejection"))
             (tek9:close-database database))))
    (ignore-errors (star.edge.ingest:close-ingest-server server))))

(format t "embedded ingest ZeroMQ/Tek9 persistence test passed~%")
