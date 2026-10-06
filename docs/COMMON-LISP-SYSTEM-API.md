# Attax-OS Common Lisp system API

`starintel-edge/system-api` is the Common Lisp capability boundary for Attax-OS.
It gives Lish, trusted local services, and actor packages one small interface for
position providers, radio observation, authorized recon, StarIntel document
writes, managed actor services, and Hackmode.

The API is a dispatcher, not a hardware abstraction that pretends every backend
exists. A capability appears only after the host installs a provider. Every call
then passes a live authorization check immediately before the provider effect.
Missing providers return `:unavailable`; denied calls never reach the provider.

## What is implemented

It is important to distinguish the API from its adapters and from device proof:

| Layer | Current state |
| --- | --- |
| Capability registry, discovery, authorization, response envelope | Implemented in `runtime/system-api.lisp` |
| Debian, NixOS, and Termux platform identifiers | Accepted by the Lisp API and installer plans |
| Linux and Termux executable catalog | Implemented; only programs found on `PATH` are registered |
| NixOS recon-tool package selection | Implemented in `services.starintelDistro.reconTools` |
| Loopback ZeroMQ/Tek9 document sink | Implemented in `starintel-edge-ingest/client` |
| Named Sento actor services | Implemented in `starintel-edge/runtime` |
| Debian and Termux service integration | Planned; the installer currently writes a deterministic plan |
| Lish | Configured as the distribution shell identity; immutable package pin pending |
| Hackmode | Typed capability port present; immutable package pin and concrete adapter pending |
| GPS/USB/phone relay and physical radio backends | Provider extension points; availability depends on installed adapters, permissions, policy, and hardware |

An SDK type, an installed command, or an advertised distribution component is
not physical-device acceptance. Hosts must probe the current device and
permissions, then install only the providers that really work.

## Loading the systems

The base dispatcher has no Sento, ZeroMQ, or Tek9 dependency:

```lisp
(require :asdf)
(asdf:load-system "starintel-edge/system-api")
```

Load the runtime only when actor services are needed:

```lisp
(asdf:load-system "starintel-edge/runtime")
```

The embedded ingest client is a separate system:

```lisp
(asdf:load-system "starintel-edge-ingest/client")
```

Source checkouts must make `runtime/` and, for ingest, `distro/embedded-ingest/`
visible to ASDF. Packaged environments should use their installed ASDF registry
instead of modifying the source registry at runtime.

## Creating and calling an API

`make-system-api` accepts exactly one of `"debian"`, `"nixos"`, or `"termux"`.
The authorizer receives the capability name, access class, and request for every
call. It must return the literal value `T`; any other value is denial.

```lisp
(defun authorize-read-only (name access-class request)
  (declare (ignore name request))
  ;; MEMBER returns a list, so normalize it to T or NIL.
  (not (null (member access-class
                     '(:sensor :passive-recon :service-read)
                     :test #'eq))))

(defparameter *system-api*
  (star.edge.system:make-system-api
   :platform "nixos"
   :authorize #'authorize-read-only))

(star.edge.system:install-standard-capabilities
 *system-api*
 :geo-position
 (lambda (request)
   (list :provider :example-gps
         :requested-accuracy (getf request :accuracy)
         :latitude 40.7128d0
         :longitude -74.0060d0)))

(star.edge.system:list-capabilities *system-api*)
;; => ((:NAME "geo.position.read" :ACCESS-CLASS :SENSOR ...))

(star.edge.system:call-system-api
 *system-api* "geo.position.read" '(:accuracy :fine))
;; => (:STATUS :OK :VALUE
;;     (:PROVIDER :EXAMPLE-GPS :REQUESTED-ACCURACY :FINE
;;      :LATITUDE 40.7128d0 :LONGITUDE -74.0060d0))
```

`list-capabilities` returns stable, name-sorted metadata for installed ports. It
does not claim that the provider will remain usable. Authorization is checked by
the dispatcher when the capability is called; the authorizer and provider must
also check current permission, device, and backend state where applicable.

### Response envelope

For a normally returning authorizer, `call-system-api` returns one of these
property-list shapes:

| Status | Shape | Meaning |
| --- | --- | --- |
| `:ok` | `(:status :ok :value VALUE)` | Authorization passed and the provider returned normally |
| `:unavailable` | `(:status :unavailable :reason :capability-not-installed)` | No provider is registered under that name |
| `:denied` | `(:status :denied :reason :capability-not-authorized)` | The authorizer was absent or did not return exactly `T` |
| `:error` | `(:status :error :reason :backend-failed :condition TYPE)` | The provider signaled an error |

The error envelope exposes only the lower-case condition type, not the condition
message. Providers should send detailed diagnostics to a protected local log and
must not put credentials, raw device identifiers, or sensitive observations in
the public response. An error raised by the authorizer itself propagates to the
caller instead of being converted into a provider error; authorization policy
should therefore fail closed and return `NIL` for ordinary denial.

## Standard capability ports

`install-standard-capabilities` registers only the non-`NIL` provider arguments
supplied by the host.

| Capability | Access class | Provider call |
| --- | --- | --- |
| `geo.position.read` | `:sensor` | `(geo-position request)` |
| `wifi.observe` | `:passive-recon` | `(wifi-observe request)` |
| `wifi.recon` | `:active-recon` | `(wifi-recon request)` |
| `bluetooth.observe` | `:passive-recon` | `(bluetooth-observe request)` |
| `bluetooth.recon` | `:active-recon` | `(bluetooth-recon request)` |
| `starintel.document.create` | `:document-write` | `(document-sink :create request)` |
| `starintel.document.edit` | `:document-write` | `(document-sink :edit request)` |
| `starintel.document.ingest` | `:document-write` | `(document-sink :ingest request)` |
| `actor.service.start` | `:service-control` | `(actor-service-dispatch :start request)` |
| `actor.service.stop` | `:service-control` | `(actor-service-dispatch :stop request)` |
| `actor.service.status` | `:service-read` | `(actor-service-dispatch :status request)` |
| `hackmode.invoke` | `:operator` | `(hackmode-dispatch request)` |

Requests and provider return values are inert Lisp data. The dispatcher assigns
stable names and access classes but does not invent a second schema for an
owning subsystem. Provider packages should document their request/result shape,
validate it before effects, and preserve provenance in produced observations.

Custom ports can be added with `register-capability`. Names must contain only
lower-case letters, digits, `.`, and `-`. Re-registering a name replaces the
previous provider.

## Canonical StarIntel document writes

The three document operations intentionally share one complete-document sink.
`edit` means a complete canonical document upsert by stable ID; there is no
Edge-specific patch language. Generated Star-Lang bindings remain responsible
for dtype validation and serialization. See the
[pinned StarIntel consumer boundary](STARINTEL-0101.md) for the exact release
authority used by this checkout.

The local ingest adapter connects only to an explicit loopback endpoint:

```lisp
(defparameter *ingest-api*
  (star.edge.system:make-system-api
   :platform "nixos"
   :authorize
   (lambda (name access-class request)
     (declare (ignore request))
     (and (string= name "starintel.document.ingest")
          (eq access-class :document-write)
          t))))

(let ((client
        (star.edge.ingest:make-ingest-client
         :endpoint "tcp://127.0.0.1:42220"
         :timeout-milliseconds 5000)))
  (unwind-protect
       (progn
         (star.edge.system:install-standard-capabilities
          *ingest-api*
          :document-sink
          (star.edge.ingest:make-ingest-document-sink
           client
           :serializer #'my-generated-starintel-serializer))
         (star.edge.system:call-system-api
          *ingest-api*
          "starintel.document.ingest"
          my-complete-document))
    (star.edge.ingest:close-ingest-client client)))
```

Use `unwind-protect` around a client so it is always closed. The sink serializes
one object, sends one UTF-8 canonical document, and waits for a
`STARINTEL-EDGE-INGEST/1` receipt. The server durably commits to Tek9/LMDB before
replying. It accepts the canonical base envelope for the release pinned by
`schema/starintel-schema.lock.json`; dtype-specific validation must happen
before dispatch.

The embedded service is deliberately loopback-only and single-process. Remote
phone relays or multi-host ingest require a separately authenticated transport
adapter; changing the endpoint check is not a supported shortcut.

## Managed actor services

Actor services reuse the one process-owned Edge Sento actor system. They do not
start a second supervisor. Register definitions before use, start the actor
system through the normal runtime lifecycle, and expose the dispatcher through
the system API. The direct start below is suitable for a standalone REPL
demonstration; a service host should let its managed runtime own startup and
shutdown:

```lisp
(defparameter *service-api*
  (star.edge.system:make-system-api
   :platform "nixos"
   :authorize
   (lambda (name access-class request)
     (and (member name
                  '("actor.service.start"
                    "actor.service.stop"
                    "actor.service.status")
                  :test #'string=)
          (member access-class '(:service-control :service-read) :test #'eq)
          (equal (getf request :name) "field-observer")
          t))))

(star.edge.actors:register-sento-actor-service
 "field-observer"
 (lambda (message)
   (format t "received inert message data: ~S~%" message)))

(star.edge.actors:start-actor-system :workers 2)

(star.edge.system:install-standard-capabilities
 *service-api*
 :actor-service-dispatch
 (star.edge.actors:make-actor-service-dispatcher))

(star.edge.system:call-system-api
 *service-api* "actor.service.start" '(:name "field-observer"))
;; => (:STATUS :OK :VALUE (:NAME "field-observer" :STATE :RUNNING))

(star.edge.actors:route-target '(:event :poll) "field-observer")

(star.edge.system:call-system-api
 *service-api* "actor.service.stop" '(:name "field-observer"))

(star.edge.actors:list-actor-services)
;; => ((:NAME "field-observer" :STATE :STOPPED))

(star.edge.actors:stop-actor-system)
(star.edge.actors:unregister-actor-service "field-observer")
```

For a package with custom setup and cleanup, use `register-actor-service`. Its
start function receives the full start request and must return one running root
actor. The optional stop function receives that root actor and the stop request
for package-specific cleanup; Edge then stops the root through Sento.

Service names follow the same lower-case name rules as capabilities. Definitions
remain registered across a confirmed actor-system restart, while their live
state returns to `:stopped`. Status reconciles an actor stopped outside the
service API and removes its stale route. A running definition cannot be replaced
or unregistered; stop it first.

## Executable tool capabilities

`install-tool-capabilities` probes a fixed catalog and registers one capability
per executable found on `PATH`. The default runner calls `uiop:run-program` with
a list: it never invokes a shell and never evaluates command text.

```lisp
(star.edge.system:list-system-tools :platform "nixos")
;; => ((:ID "gpspipe" ... :AVAILABLE NIL) ...)

(star.edge.system:install-tool-capabilities *system-api*)

(star.edge.system:call-system-api
 *system-api*
 "tool.iw.run"
 '(:arguments ("dev" "wlan0" "scan")))
```

The argument payload must be `(:arguments (STRING ...))`, with at most 128
arguments, at most 4096 characters per argument, and no NUL characters. A single
string such as `"dev wlan0 scan"` is rejected. Authorization is checked again on
every call, including after capability discovery.

| Capability ID | Platforms | Access class | Program |
| --- | --- | --- | --- |
| `tool.gpspipe.run` | Debian, NixOS | `:sensor` | `gpspipe` |
| `tool.termux-location.run` | Termux | `:sensor` | `termux-location` |
| `tool.iw.run` | Debian, NixOS | `:passive-recon` | `iw` |
| `tool.nmcli.run` | Debian, NixOS | `:passive-recon` | `nmcli` |
| `tool.termux-wifi-scaninfo.run` | Termux | `:passive-recon` | `termux-wifi-scaninfo` |
| `tool.kismet.run` | Debian, NixOS | `:active-recon` | `kismet` |
| `tool.aircrack-ng.run` | Debian, NixOS | `:intrusive-recon` | `aircrack-ng` |
| `tool.hcxdumptool.run` | Debian, NixOS | `:intrusive-recon` | `hcxdumptool` |
| `tool.hcxpcapngtool.run` | Debian, NixOS | `:active-recon` | `hcxpcapngtool` |
| `tool.bettercap.run` | Debian, NixOS | `:intrusive-recon` | `bettercap` |
| `tool.bluetoothctl.run` | Debian, NixOS | `:passive-recon` | `bluetoothctl` |
| `tool.btmgmt.run` | Debian, NixOS | `:active-recon` | `btmgmt` |

These are administration and assessment primitives, not blanket permission to
use them. Operators must restrict active and intrusive access classes to owned
or explicitly authorized targets. The API supplies process isolation from shell
parsing, not OS sandboxing, radio isolation, or legal authorization.

On NixOS, package selection is explicit:

```nix
services.starintelDistro.reconTools = [
  "iw"
  "kismet"
  "aircrack-ng"
  "hcxdumptool"
  "hcxtools"       # supplies hcxpcapngtool
  "bluetoothctl"
  "btmgmt"
  "gpspipe"
];
```

Package selection makes commands available to a host process. The host must
still call `install-tool-capabilities`, enforce authorization, and satisfy OS
permissions. Termux location and Wi-Fi commands additionally require Termux:API
and current Android permissions. No Termux Bluetooth executable provider is in
the current catalog; a host may inject `bluetooth.observe` or
`bluetooth.recon` only when it has a real authorized provider.

## Platform deployment status

### NixOS

The NixOS module can install the embedded ingest service and selected recon
packages, and writes `/etc/starintel/distro.json`. It does not automatically
grant radio permissions or expose every installed program. See
[the distribution guide](DISTRIBUTION.md) for profile and module configuration.

### Debian

`starintel-install plan --platform debian` and `install` produce the same
versioned distribution plan. Native package/service adapters are not complete,
so the plan is not a claim that systemd units, Lish, Hackmode, or providers have
been installed.

### Termux

`starintel-install plan --platform termux` records the Termux target and API
surface. The Lisp library catalogs `termux-location` and
`termux-wifi-scaninfo`. Termux service lifecycle, phone-relay transport, and
Bluetooth providers remain pending.

## Security invariants

- Omitted authorizer means deny, not allow.
- Authorization is per call and must return exactly `T`.
- Capability discovery advertises installed ports, not permanent readiness.
- Tool dispatch uses bounded argument vectors and never a shell command string.
- The embedded ingest client and server accept loopback TCP endpoints only.
- StarIntel dtype/schema authority stays with the exact pinned Star-Lang release.
- Actor packages share the existing Sento system; they do not create a hidden
  supervisor.
- Secrets belong in environment, OS wallet/keyring, or Emacs auth-source—not
  requests, command arguments, source, Nix store paths, or actor archives.
- Device permission, consent, foreground, recording-indicator, revocation,
  battery, and thermal policy remain mandatory even when a provider is installed.

## Verification

Run the focused API checks from the repository root:

```console
sbcl --script tests/system_api.lisp
sbcl --script tests/runtime.lisp
python3 tools/check_contracts.py
nix build .#checks.x86_64-linux.system-api-test
```

The runtime suite needs the pinned Sento dependency closure described in
[the roadmap](ROADMAP.md). These host checks prove dispatcher and lifecycle
semantics; they do not replace Debian/NixOS deployment tests, Android ART, radio
hardware, GPS, USB, or physical-device acceptance.
