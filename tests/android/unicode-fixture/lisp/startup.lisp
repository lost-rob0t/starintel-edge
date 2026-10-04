;;;; Trusted host-ECL test fixture ONLY, never packaged in the Android app.
;;;; EDGE_UNICODE_TEST_ROOT is set by build_host_tests.sh, not by JSON requests.
(require :asdf)
(load (merge-pathnames "tests/android/fixture/lisp/startup.lisp"
                       (uiop:ensure-directory-pathname
                        (or (uiop:getenv "EDGE_UNICODE_TEST_ROOT")
                            (error "EDGE_UNICODE_TEST_ROOT is required")))))
(in-package #:star.edge.android)
(install-adapter-host :capabilities (lambda () '("power.status")))
(let ((production-dispatch (symbol-function 'handle-request)))
  (setf (symbol-function 'handle-request)
        (lambda (operation payload capability)
          (cond
            ((string= operation "test.unicode")
             (encode-json (list :payload payload :length (length payload)
                                :codes (map 'list #'char-code payload))))
            ((string= operation "test.error") (error "synthetic-test-error"))
            ((string= operation "test.non-string") 42)
            ((string= operation "test.base-response")
             (coerce (concatenate 'string "\"" (string (code-char 233)) "\"") 'base-string))
            ((string= operation "test.surrogate-response")
             ;; Implementations may reject this character at creation already.
             (string (or (code-char #xd800) (error "surrogate-not-a-character"))))
            ((string= operation "test.invalid-response")
             (concatenate 'string "prefix" (string (code-char 0)) "suffix"))
            ((string= operation "test.response-limit")
             ;; 4 MiB exact/over standard UTF-8 bytes. Kept outside production.
             (let* ((limit (* 4 1024 1024))
                    (over (string= payload "over"))
                    (prefix "{\"payload\":\"") (suffix "\"}")
                    (available (- limit (length prefix) (length suffix))))
               (concatenate 'string prefix
                (make-string (floor available 4) :initial-element (code-char #x1f642))
                (make-string (+ (mod available 4) (if over 1 0)) :initial-element #\x)
                suffix)))
            (t (funcall production-dispatch operation payload capability))))))
