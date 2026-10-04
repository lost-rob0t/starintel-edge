(require :asdf)
(push (uiop:ensure-directory-pathname (uiop:getenv "INTEROP_CL_SDK")) asdf:*central-registry*)
(let ((*standard-output* *error-output*)) (asdf:load-system :starintel-0101))
(let ((mode (first (uiop:command-line-arguments))))
  (loop for line = (read-line *standard-input* nil) while line do
    (let ((value (starintel.canonical:parse-json line)))
      (handler-case
          (let ((result (if (equal mode "emit") value
                            (starintel.canonical:encode-document (starintel.canonical:decode-document value)))))
            (write-line (starintel.canonical:stringify-json
              (if (equal mode "reject") (starintel::json-object "accepted" t) result))))
        (starintel::starintel-validation-error (condition)
          (unless (equal mode "reject") (error condition))
          (write-line (starintel.canonical:stringify-json (starintel::json-object "accepted" nil
                       "error" (starintel::validation-category condition)))))))))
