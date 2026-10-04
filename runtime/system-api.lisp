;;;; Typed Attax-OS/Edge system API. Provider implementations stay with their
;;;; owning projects; this file owns capability discovery, authorization, and
;;;; exact-argv dispatch only.

(in-package #:star.edge.system)

(defparameter +supported-platforms+ '("debian" "nixos" "termux"))

(defstruct (system-capability (:constructor %make-system-capability))
  name handler access-class description)

(defstruct (system-api (:constructor %make-system-api))
  platform authorizer capabilities)

(defstruct (system-tool (:constructor make-system-tool
                            (id program category access-class platforms description)))
  id program category access-class platforms description)

(defun make-system-api (&key platform authorize)
  "Create a default-deny API for PLATFORM.

AUTHORIZE receives capability name, access class, and the request. It must
return exactly T. This hook is called immediately before every provider effect."
  (unless (member platform +supported-platforms+ :test #'equal)
    (error "Unsupported system API platform: ~S" platform))
  (unless (or (null authorize) (functionp authorize))
    (error "System API authorizer must be a function or NIL"))
  (%make-system-api :platform platform
                    :authorizer authorize
                    :capabilities (make-hash-table :test #'equal)))

(defun valid-capability-name-p (name)
  (and (stringp name)
       (plusp (length name))
       (every (lambda (character)
                (or (lower-case-p character)
                    (digit-char-p character)
                    (member character '(#\. #\-))))
              name)))

(defun register-capability (api name handler access-class description)
  "Register one typed effect port. Re-registration replaces the prior port."
  (unless (valid-capability-name-p name)
    (error "Invalid capability name: ~S" name))
  (unless (functionp handler)
    (error "Capability handler must be a function"))
  (unless (keywordp access-class)
    (error "Capability access class must be a keyword"))
  (unless (stringp description)
    (error "Capability description must be a string"))
  (setf (gethash name (system-api-capabilities api))
        (%make-system-capability :name name
                                 :handler handler
                                 :access-class access-class
                                 :description description))
  name)

(defun capability-record (capability)
  (list :name (system-capability-name capability)
        :access-class (system-capability-access-class capability)
        :description (system-capability-description capability)))

(defun list-capabilities (api)
  "Return stable metadata for currently installed provider ports."
  (sort (loop for capability being the hash-values
                of (system-api-capabilities api)
              collect (capability-record capability))
        #'string< :key (lambda (record) (getf record :name))))

(defun call-system-api (api name &optional request)
  "Invoke NAME with opaque data REQUEST after a live authorization check."
  (let ((capability (gethash name (system-api-capabilities api))))
    (cond
      ((null capability)
       (list :status :unavailable :reason :capability-not-installed))
      ((or (null (system-api-authorizer api))
           (not (eq t (funcall (system-api-authorizer api)
                               name
                               (system-capability-access-class capability)
                               request))))
       (list :status :denied :reason :capability-not-authorized))
      (t
       (handler-case
           (list :status :ok
                 :value (funcall (system-capability-handler capability) request))
         (error (condition)
           (list :status :error
                 :reason :backend-failed
                 :condition (string-downcase
                             (symbol-name (type-of condition))))))))))

(defun install-port (api name port access-class description &optional operation)
  (when port
    (register-capability
     api name
     (if operation
         (lambda (request) (funcall port operation request))
         port)
     access-class description)))

(defun install-standard-capabilities
    (api &key geo-position wifi-observe wifi-recon bluetooth-observe
              bluetooth-recon document-sink actor-service-dispatch
              hackmode-dispatch)
  "Install only supplied provider ports; missing backends remain unavailable.

DOCUMENT-SINK receives (:CREATE|:EDIT|:INGEST request). Edits are complete
canonical-document upserts, not an Edge-owned patch language. Actor services
and Hackmode remain owned by their canonical runtimes and enter through ports."
  (install-port api "geo.position.read" geo-position :sensor
                "Read a position from the selected GPS, USB, or phone provider.")
  (install-port api "wifi.observe" wifi-observe :passive-recon
                "Observe locally visible Wi-Fi networks without association.")
  (install-port api "wifi.recon" wifi-recon :active-recon
                "Run an operator-authorized Wi-Fi recon operation.")
  (install-port api "bluetooth.observe" bluetooth-observe :passive-recon
                "Observe locally visible Bluetooth devices.")
  (install-port api "bluetooth.recon" bluetooth-recon :active-recon
                "Run an operator-authorized Bluetooth recon operation.")
  (install-port api "starintel.document.create" document-sink :document-write
                "Create a complete canonical StarIntel document." :create)
  (install-port api "starintel.document.edit" document-sink :document-write
                "Replace a canonical document by stable ID/revision." :edit)
  (install-port api "starintel.document.ingest" document-sink :document-write
                "Pipe a canonical document to the configured ingest server." :ingest)
  (install-port api "actor.service.start" actor-service-dispatch :service-control
                "Start one installed actor package as a managed service." :start)
  (install-port api "actor.service.stop" actor-service-dispatch :service-control
                "Stop one installed actor service." :stop)
  (install-port api "actor.service.status" actor-service-dispatch :service-read
                "Read one installed actor service status." :status)
  (install-port api "hackmode.invoke" hackmode-dispatch :operator
                "Invoke the canonical Hackmode capability API.")
  api)

(defparameter *common-system-tools*
  (list
   (make-system-tool "gpspipe" "gpspipe" :geo :sensor
                     '("debian" "nixos") "Read GPSD reports.")
   (make-system-tool "termux-location" "termux-location" :geo :sensor
                     '("termux") "Read Android location through Termux:API.")
   (make-system-tool "iw" "iw" :wifi :passive-recon
                     '("debian" "nixos") "Inspect Linux wireless interfaces and scans.")
   (make-system-tool "nmcli" "nmcli" :wifi :passive-recon
                     '("debian" "nixos") "Inspect NetworkManager Wi-Fi state.")
   (make-system-tool "termux-wifi-scaninfo" "termux-wifi-scaninfo" :wifi
                     :passive-recon '("termux")
                     "Read Android Wi-Fi scan results through Termux:API.")
   (make-system-tool "kismet" "kismet" :wifi :active-recon
                     '("debian" "nixos") "Run Kismet wireless recon.")
   (make-system-tool "aircrack-ng" "aircrack-ng" :wifi :intrusive-recon
                     '("debian" "nixos") "Analyze authorized 802.11 captures.")
   (make-system-tool "hcxdumptool" "hcxdumptool" :wifi :intrusive-recon
                     '("debian" "nixos") "Capture authorized 802.11 authentication traffic.")
   (make-system-tool "hcxpcapngtool" "hcxpcapngtool" :wifi :active-recon
                     '("debian" "nixos") "Convert authorized packet captures.")
   (make-system-tool "bettercap" "bettercap" :network :intrusive-recon
                     '("debian" "nixos") "Run authorized network and radio assessments.")
   (make-system-tool "bluetoothctl" "bluetoothctl" :bluetooth :passive-recon
                     '("debian" "nixos") "Inspect BlueZ controllers and devices.")
   (make-system-tool "btmgmt" "btmgmt" :bluetooth :active-recon
                     '("debian" "nixos") "Control an authorized BlueZ management socket.")))

(defun common-system-tools ()
  (copy-list *common-system-tools*))

(defun path-directories ()
  (remove-if #'uiop:emptyp
             (uiop:split-string (or (uiop:getenv "PATH") "")
                                :separator '(#\:))))

(defun find-executable (program)
  "Return an existing executable pathname for PROGRAM, or NIL."
  (when (and (stringp program)
             (plusp (length program))
             (not (find #\/ program)))
    (loop for directory in (path-directories)
          for path = (merge-pathnames program
                                      (uiop:ensure-directory-pathname directory))
          when (and (probe-file path)
                    (not (uiop:directory-exists-p path)))
            return path)))

(defun tool-record (tool probe)
  (list :id (system-tool-id tool)
        :program (system-tool-program tool)
        :category (system-tool-category tool)
        :access-class (system-tool-access-class tool)
        :platforms (copy-list (system-tool-platforms tool))
        :description (system-tool-description tool)
        :available (and (funcall probe (system-tool-program tool)) t)))

(defun list-system-tools (&key platform (probe #'find-executable))
  "List the fixed tool catalog and live executable availability."
  (unless (functionp probe) (error "Tool probe must be a function"))
  (loop for tool in *common-system-tools*
        when (or (null platform)
                 (member platform (system-tool-platforms tool) :test #'equal))
          collect (tool-record tool probe)))

(defun valid-tool-arguments-p (arguments)
  (and (listp arguments)
       (<= (length arguments) 128)
       (every (lambda (argument)
                (and (stringp argument)
                     (<= (length argument) 4096)
                     (null (find #\Null argument))))
              arguments)))

(defun make-uiop-tool-runner ()
  "Return a runner that executes PROGRAM + ARGS directly, never through a shell."
  (lambda (program arguments)
    (uiop:run-program (cons program arguments)
                      :output :string
                      :error-output :output
                      :ignore-error-status nil)))

(defun install-tool-capabilities
    (api &key (tools *common-system-tools*) (probe #'find-executable)
              (runner (make-uiop-tool-runner)))
  "Register one exact-argv capability per installed catalog tool."
  (dolist (tool tools api)
    (when (and (member (system-api-platform api)
                       (system-tool-platforms tool) :test #'equal)
               (funcall probe (system-tool-program tool)))
      (let ((tool tool))
        (register-capability
         api
         (format nil "tool.~A.run" (system-tool-id tool))
         (lambda (request)
           (let ((arguments (getf request :arguments)))
             (unless (valid-tool-arguments-p arguments)
               (error "Tool arguments must be a bounded list of strings"))
             (funcall runner (system-tool-program tool) arguments)))
         (system-tool-access-class tool)
         (system-tool-description tool))))))
