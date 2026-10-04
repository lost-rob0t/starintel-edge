;;;; Example TRUSTED LOCAL init.lisp. Never load this from an actor/JSON request.
;;;; Off by default: no credentials are present, and no public swarm is enabled.
;;;; Bind *edge-credential-provider* to an OS keyring/auth-source/environment
;;;; resolver before loading this example. It returns fresh 32-byte CURVE key
;;;; vectors as (:public-key ... :secret-key ...) for this node and public-key
;;;; only for peers. These values must never be written into this file.
(require :asdf)
(asdf:load-system "starintel-edge/mesh-runtime")
(asdf:load-system "starintel-edge/mesh-zmq")

(defvar *edge-credential-provider* nil)
(defvar *private-mesh* nil)
(defvar *private-mesh-handle* nil)
(unless (functionp *edge-credential-provider*)
  (error "Private mesh credential provider is not configured"))

(defun private-echo-authorized-p (peer request)
  ;; Replace with the local policy authority. Recheck inside the real actor
  ;; at every privileged effect, including revocation and the absolute deadline.
  (and (equal peer "node-b")
       (equal (star.edge.mesh:request-caller request) "star:v1:projector:client")
       (equal (star.edge.mesh:request-destination request) "star:v1:resolver:echo")
       (equal (star.edge.mesh:request-operation request) "star.edge.echo")))

(defun start-private-echo-actor ()
   (star.edge.actors:register-actor
    "star:v1:resolver:echo"
    (star.edge.actors:actor-of
     :name "star:v1:resolver:echo"
     :receive
     (star.edge.mesh:make-mesh-receiver
      (lambda (peer request)
        (declare (ignore peer))
        (star.edge.mesh:make-result :ok (star.edge.mesh:request-payload request)))
      #'private-echo-authorized-p))))

;; A stable symbol designator avoids accumulating duplicate hooks on init reload.
(star.edge.actors:add-actors-start-hook 'start-private-echo-actor)

(setf *private-mesh*
      (star.edge.mesh:make-mesh
       :config
       (star.edge.mesh:make-config
        :node-id "node-a" :mode :private
        :bind-endpoint "tcp://127.0.0.1:49101"
        :credential-reference "device.curve"
        :peers (list (star.edge.mesh:make-peer
                      :id "node-b" :endpoint "tcp://127.0.0.1:49102"
                      :key-reference "peer.node-b.curve"
                      :callers '("star:v1:projector:client")
                      :actors '("star:v1:resolver:echo")))
        :operations (list (star.edge.mesh:make-operation :name "star.edge.echo" :retry-safe t))
        :max-message-bytes 65536 :max-pending 32 :max-inbound 32 :max-replay 128)
       ;; Read-only native SBCL/Linux RLIMIT_AS verifier is the default. It
       ;; rejects unlimited/privileged/unsupported hosts and does not set limits.
       ;; ECL/Android transport packaging and containment are NOT implemented.
       :transport (star.edge.mesh:make-zmq-transport)
       :credential-provider *edge-credential-provider*
       :authorize #'private-echo-authorized-p
       :dispatch (star.edge.mesh:make-sento-dispatcher #'star.edge.actors:get-dest-actor)))

;; Android already starts local actors before *service-components* and binds
;; strict confirmed-shutdown policy for start and every stop/retry. Explicitly
;; adding this unavailable optional mesh makes startup FAIL, never fake readiness.
;; A Linux host must keep *require-confirmed-shutdown* true for its entire lifecycle.
(multiple-value-bind (component handle) (star.edge.mesh:make-mesh-component *private-mesh*)
  (setf *private-mesh-handle* handle)
  (push component star.edge.android:*service-components*))
