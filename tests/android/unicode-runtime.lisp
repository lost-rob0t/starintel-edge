;;;; Production Lisp JSON/closed-dispatch regressions. SBCL is not ECL/JNI/ART.
(require :asdf)
(asdf:initialize-source-registry
 `(:source-registry (:directory ,(uiop:merge-pathnames* "runtime/" (uiop:getcwd)))
                    :inherit-configuration))
(asdf:load-system :starintel-edge/runtime)
(let ((checks 0))
  (labels ((check (value) (incf checks) (unless value (error "Unicode check ~D failed" checks))))
    (loop for code below 32
          for char = (code-char code)
          for expected = (case code
                           (8 "\\b") (9 "\\t") (10 "\\n") (12 "\\f") (13 "\\r")
                           (otherwise (format nil "\\u~4,'0X" code)))
          do (check (string= (star.edge.android::json-escape (string char)) expected))
             (check (not (find char (star.edge.android::encode-json (list :payload (string char)))))))
    (let ((payload (concatenate 'string "before" (string (code-char 0)) "after")))
      (check (= (length payload) 12))
      (check (string= (star.edge.android::encode-json (list :payload payload))
                      "{\"payload\":\"before\\u0000after\"}")))
    (dolist (payload '("" "ASCII" "café" "中文" "🙂𝄞" "é" "é"))
      (check (string= (star.edge.android::json-escape payload) payload)))
    (check (not (string= (star.edge.android::json-escape "é")
                         (star.edge.android::json-escape "é"))))
    (star.edge.android:install-adapter-host :capabilities (lambda () '("power.status")))
    (let ((nul (string (code-char 0))))
      (check (search "\"status\":\"ok\""
                     (star.edge.android:handle-request "runtime.ping" nil nil)))
      (dolist (operation '("status" "runtime.ping" "service.stop" "dispatch"))
        (check (search "unknown-operation"
                       (star.edge.android:handle-request (concatenate 'string operation nul "suffix") nil nil)))))
    (check (search "\"status\":\"ok\""
                   (star.edge.android:handle-request "dispatch" nil "power.status")))
    (check (search "capability-not-authorized"
                   (star.edge.android:handle-request "dispatch" nil
                    (concatenate 'string "power.status" (string (code-char 0)) "suffix"))))
    (format t "~D production Lisp Unicode/JSON/closed-dispatch checks passed; not ECL/JNI/ART evidence.~%" checks)))
