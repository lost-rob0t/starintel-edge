(require :asdf)
(asdf:initialize-source-registry
 `(:source-registry (:directory ,(uiop:merge-pathnames* "runtime/" (uiop:getcwd)))
   :inherit-configuration))
(asdf:load-system "starintel-edge/system-api")

(let ((checks 0))
  (flet ((check (value message)
           (incf checks)
           (unless value (error "system API test failed: ~A" message))))
    (handler-case
        (progn (star.edge.system:make-system-api :platform "unknown")
               (check nil "unknown platforms fail closed"))
      (error () (check t "unknown platforms fail closed")))
    (let* ((authorized nil)
           (calls nil)
           (api (star.edge.system:make-system-api
                 :platform "termux"
                 :authorize
                 (lambda (name access request)
                   (push (list name access request) calls)
                   authorized))))
      (star.edge.system:install-standard-capabilities
       api
       :geo-position (lambda (request) (list :provider :gps :request request))
       :document-sink (lambda (operation request) (list operation request))
       :hackmode-dispatch (lambda (request) (list :hackmode request)))
      (check (equal (getf (star.edge.system:call-system-api
                           api "wifi.observe") :status)
                    :unavailable)
             "missing providers are unavailable")
      (check (equal (getf (star.edge.system:call-system-api
                           api "geo.position.read" '(:accuracy :fine)) :status)
                    :denied)
             "provider effects default deny")
      (setf authorized t)
      (let ((response (star.edge.system:call-system-api
                       api "geo.position.read" '(:accuracy :fine))))
        (check (eq (getf response :status) :ok) "authorized geo succeeds")
        (check (equal (getf response :value)
                      '(:provider :gps :request (:accuracy :fine)))
               "geo provider receives typed request"))
      (let ((response (star.edge.system:call-system-api
                       api "starintel.document.edit" '(:id "doc-1" :rev 2))))
        (check (equal (getf response :value)
                      '(:edit (:id "doc-1" :rev 2)))
               "document edit delegates without inventing patch semantics"))
      (check (find "hackmode.invoke" (star.edge.system:list-capabilities api)
                   :key (lambda (entry) (getf entry :name)) :test #'equal)
             "Hackmode adapter is discoverable")
      (check (equal (second (first calls)) :document-write)
             "authorization sees the document-write access class"))
    (let* ((authorized t)
           (run nil)
           (api (star.edge.system:make-system-api
                 :platform "nixos"
                 :authorize (lambda (&rest ignored)
                              (declare (ignore ignored)) authorized))))
      (star.edge.system:install-tool-capabilities
       api
       :probe (lambda (program) (member program '("iw" "aircrack-ng") :test #'equal))
       :runner (lambda (program arguments)
                 (setf run (cons program arguments))
                 :ran))
      (check (find "tool.iw.run" (star.edge.system:list-capabilities api)
                   :key (lambda (entry) (getf entry :name)) :test #'equal)
             "installed tools become capabilities")
      (check (null (find "tool.kismet.run" (star.edge.system:list-capabilities api)
                         :key (lambda (entry) (getf entry :name)) :test #'equal))
             "missing tools are not advertised")
      (let ((response (star.edge.system:call-system-api
                       api "tool.iw.run" '(:arguments ("dev" "wlan0" "scan")))))
        (check (eq (getf response :status) :ok) "authorized tool succeeds")
        (check (equal run '("iw" "dev" "wlan0" "scan"))
               "tool runner receives exact argv"))
      (let ((response (star.edge.system:call-system-api
                       api "tool.iw.run" '(:arguments "dev wlan0 scan"))))
        (check (eq (getf response :status) :error)
               "string shell command is rejected"))
      (setf authorized nil run nil)
      (check (eq (getf (star.edge.system:call-system-api
                        api "tool.aircrack-ng.run" '(:arguments ("capture.pcap")))
                       :status)
                 :denied)
             "intrusive tools recheck authorization")
      (check (null run) "denied tool never runs"))
    (let ((catalog (star.edge.system:list-system-tools
                    :platform "termux" :probe (constantly nil))))
      (check (find "termux-location" catalog
                   :key (lambda (entry) (getf entry :id)) :test #'equal)
             "Termux geo provider is catalogued")
      (check (find "termux-wifi-scaninfo" catalog
                   :key (lambda (entry) (getf entry :id)) :test #'equal)
             "Termux Wi-Fi provider is catalogued"))
    (format t "~D Common Lisp system API checks passed~%" checks)))
