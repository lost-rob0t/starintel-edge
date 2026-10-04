(uiop:define-package #:star.edge.system
  (:use #:cl)
  (:export
   #:make-system-api
   #:system-api-platform
   #:register-capability
   #:list-capabilities
   #:call-system-api
   #:install-standard-capabilities
   #:system-tool
   #:system-tool-id
   #:system-tool-program
   #:system-tool-category
   #:system-tool-access-class
   #:system-tool-platforms
   #:system-tool-description
   #:common-system-tools
   #:list-system-tools
   #:install-tool-capabilities
   #:find-executable
   #:make-uiop-tool-runner))
