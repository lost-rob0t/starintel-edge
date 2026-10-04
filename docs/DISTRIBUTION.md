# StarIntel Edge distribution

The distribution identity is **Attax-OS**. Its configured interactive Common
Lisp shell is Lish, and the same typed system API is intended for Debian, NixOS,
and Termux. The current NixOS module is the first fully declarative host
integration; Debian and Termux plans are emitted by the headless installer
while their service-package adapters are completed. The Lish source/package pin
must be resolved before an image can claim the shell is installed.

The distribution has one installer and three declarative profiles. Every command
can run without a TTY; the menu is only a convenience when `--profile` is omitted.

| Profile | Runtime | Transport | Storage | Intended use |
| --- | --- | --- | --- | --- |
| `edge` | Edge Common Lisp/Sento | loopback ZeroMQ REQ/REP | Tek9 on LMDB, full durability | one self-contained field node |
| `actors` | package-defined: Sento, Pykka, or StarLang | package-defined | package-defined | selected actor systems only |
| `full` | Edge plus actor/server integration | ZeroMQ locally; optional RabbitMQ | Tek9 locally; optional CouchDB/search | a larger all-in-one deployment |

The `edge` profile does not install or use RabbitMQ. The stable ingest service
binds a ZeroMQ REP socket on loopback; local dynamic clients connect with REQ.
Each successful request durably upserts one canonical StarIntel document into a
single long-lived Tek9 database. The service accepts only the release pinned in
`schema/starintel-schema.lock.json`. Dtype-specific validation remains owned by
Star-Lang; the local persistence boundary checks the canonical base envelope and
does not keep a second dtype registry.

The local wire/storage contract is intentionally small:

- one ZeroMQ frame carries one UTF-8 canonical document; the reply uses
  `STARINTEL-EDGE-INGEST/1` and is sent only after the LMDB transaction commits;
- REP processes requests sequentially, preserving service arrival order, with a
  16 MiB maximum message size and no unbounded in-process queue;
- there is no broker ACK or server-side redelivery. A client may retry the same
  stable document `id`; Tek9 performs an idempotent upsert at that key;
- full Tek9 durability is mandatory for canonical data;
- the unauthenticated endpoint is loopback-only. Remote or multi-host transport
  requires an authenticated adapter and is not exposed by this profile;
- this is one local process and one LMDB environment, with no HA claim. Latency
  and throughput are intentionally unclaimed until measured on target hardware.

## Common Lisp system API

`star.edge.system` is the capability boundary used by Lish and services. It
discovers only installed providers, rechecks authorization immediately before
every effect, and returns unavailable for missing hardware or adapters. The
initial capability families are:

- Geo position from a selected GPS/GPSD, USB/NMEA, Termux/Android, or phone
  relay provider;
- Wi-Fi and Bluetooth observation/recon;
- canonical StarIntel create/edit/ingest (edit is a complete document upsert,
  not a second patch language);
- actor service start/stop/status; and
- the canonical Hackmode capability API.

Hackmode remains the owner of recon providers, operation state, and its actor
runtime. Edge exposes a typed adapter rather than copying those implementations;
the exact Hackmode package pin is still required before an image can claim it
is bundled. Generated Star-Lang bindings remain schema authority.

Common radio and assessment tools are a fixed Lisp catalog. Each installed
program becomes its own capability (for example `tool.iw.run`) and receives an
exact argument vector. Input is never evaluated as shell text. Passive, active,
and intrusive tools have distinct access classes for the authorization policy.
On NixOS, select tools explicitly:

```nix
services.starintelDistro.reconTools = [
  "iw" "kismet" "aircrack-ng" "hcxdumptool" "hcxtools"
  "bluetoothctl" "btmgmt" "gpspipe"
];
```

Termux uses Termux:API providers such as `termux-location` and
`termux-wifi-scaninfo`; their Android permissions remain live prerequisites.
No SDK interface or package selection is physical-device acceptance.

## Installer

List profiles:

```console
nix run .#starintel-installer -- profiles
```

Render a deterministic plan without writing system state:

```console
nix run .#starintel-installer -- plan \
  --profile edge \
  --platform nixos \
  --non-interactive
```

For Debian or Termux, change `--platform` to `debian` or `termux`.

Write the configuration headlessly:

```console
sudo nix run .#starintel-installer -- install \
  --profile edge \
  --non-interactive \
  --yes
```

Use the NixOS module directly:

```nix
{
  inputs.starintel-edge.url = "github:lost-rob0t/starintel-edge";

  outputs = { nixpkgs, starintel-edge, ... }: {
    nixosConfigurations.edge = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        starintel-edge.nixosModules.default
        {
          services.starintelDistro = {
            enable = true;
            profile = "edge";
          };
        }
      ];
    };
  };
}
```

The full profile accepts repeatable heavyweight options:

```console
starintel-install plan --profile full \
  --heavy rabbitmq \
  --heavy couchdb \
  --heavy search \
  --heavy observability \
  --non-interactive
```

The NixOS module turns those selections into loopback-only RabbitMQ, CouchDB,
OpenSearch, Prometheus/Grafana, and Ollama services respectively. They do not
silently change the Edge transport: local ingest stays ZeroMQ/Tek9.

## Actor package format

An actor release asset is a `.tar.gz` or `.tar.xz` containing this file at its
root:

```json
{
  "format": "STARINTEL-ACTOR-PACKAGE/1",
  "name": "example-actors",
  "version": "1.2.3",
  "actorSystem": "sento",
  "entrypoint": "example-actors:start",
  "starintel": {
    "releaseVersion": "0.10.1",
    "schemaVersion": "0.10.1"
  },
  "capabilities": ["collect-example"]
}
```

The archive may contain `actors/`, runtime files, licenses, and provenance. It
must not contain absolute paths, parent traversal, symlinks, hardlinks, or device
nodes. The installer caps both member count and unpacked size.

Selection and acquisition are separate from the archive to avoid a circular
digest. An operator supplies a lock:

```json
{
  "format": "STARINTEL-ACTOR-LOCK/1",
  "packages": [
    {
      "name": "example-actors",
      "version": "1.2.3",
      "actorSystem": "sento",
      "entrypoint": "example-actors:start",
      "starintel": {
        "releaseVersion": "0.10.1",
        "schemaVersion": "0.10.1"
      },
      "github": {
        "repository": "lost-rob0t/example-actors",
        "tag": "v1.2.3",
        "asset": "example-actors-1.2.3.tar.gz",
        "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      }
    }
  ]
}
```

The URL is derived as
`https://github.com/OWNER/REPO/releases/download/TAG/ASSET`; arbitrary download
hosts and mutable branch archives are rejected. The SHA-256 is mandatory, the
embedded identity must match the lock, and incompatible StarIntel releases fail
closed.

Validate and selectively install packages:

```console
starintel-install validate-actor-lock actors.lock.json
sudo starintel-install install \
  --profile actors \
  --actor-lock actors.lock.json \
  --actor-system sento \
  --fetch-actors \
  --non-interactive \
  --yes
```

Packages install versioned under `/var/lib/starintel/actors/NAME/VERSION`; only
the `current` symlink changes, so the prior version remains available for
rollback. Credentials and tenant configuration are never part of the package or
lock.

The normative JSON Schemas are `distro/actor-package.schema.json` and
`distro/actor-lock.schema.json`.
