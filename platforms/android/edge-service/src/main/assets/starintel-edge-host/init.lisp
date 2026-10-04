;;;; Trusted app-private Common Lisp initialization, preserved across starts.
;;;; This file remains Lisp, not a generated JSON settings replacement.
;;;; Load only after the packaged STAR.EDGE runtime has initialized.
;;;; No peer, listener or data collection is enabled by default.
;;;; Resolve secrets through a platform keystore port, never values in this file.
(in-package :cl-user)

;;;; Add trusted local configuration here. Network payloads must never reach LOAD.
;;;; The Android host defaults to loopback; private mesh requires explicit pairing.
