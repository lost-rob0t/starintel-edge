(in-package :star.edge.ingest)

(defparameter +receipt-protocol+ "STARINTEL-EDGE-INGEST/1")

(define-condition ingest-error (error)
  ((code :initarg :code :reader ingest-error-code)
   (message :initarg :message :reader ingest-error-message))
  (:report (lambda (condition stream)
             (format stream "~A: ~A"
                     (ingest-error-code condition)
                     (ingest-error-message condition)))))

(defun fail-ingest (code control &rest arguments)
  (error 'ingest-error
         :code code
         :message (apply #'format nil control arguments)))
