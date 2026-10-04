{ config, lib, pkgs, starintelPackages, ... }:
let
  cfg = config.services.starintelDistro;
  catalog = builtins.fromJSON (builtins.readFile ../profiles.json);
  profileNames = builtins.attrNames catalog.profiles;
  profile = catalog.profiles.${cfg.profile};
  edgeEnabled = builtins.elem cfg.profile [ "edge" "full" ];
  reconToolPackages = {
    iw = pkgs.iw;
    nmcli = pkgs.networkmanager;
    kismet = pkgs.kismet;
    aircrack-ng = pkgs.aircrack-ng;
    hcxdumptool = pkgs.hcxdumptool;
    hcxtools = pkgs.hcxtools;
    bettercap = pkgs.bettercap;
    bluetoothctl = pkgs.bluez;
    btmgmt = pkgs.bluez;
    gpspipe = pkgs.gpsd;
  };
  loopbackEndpoint =
    lib.hasPrefix "tcp://127.0.0.1:" cfg.edge.endpoint
    || lib.hasPrefix "tcp://[::1]:" cfg.edge.endpoint;
  plan = {
    format = "STARINTEL-DISTRO-PLAN/1";
    distribution = catalog.distribution.name;
    platform = "nixos";
    defaultShell = catalog.distribution.defaultShell;
    profile = cfg.profile;
    inherit (profile) components transport storage;
    heavy = lib.sort builtins.lessThan (lib.unique cfg.heavy);
    actors = [ ];
    actorServices = [ ];
    systemApis = catalog.systemApis;
    starintel = {
      releaseVersion = starintelPackages.spec.release_version;
      schemaVersion = starintelPackages.spec.schema_version;
      canonicalRepository = starintelPackages.spec.canonical_repository;
      canonicalCommit = starintelPackages.spec.canonical_commit;
    };
  };
in
{
  options.services.starintelDistro = {
    enable = lib.mkEnableOption "the StarIntel custom edge distribution";
    profile = lib.mkOption {
      type = lib.types.enum profileNames;
      default = "edge";
      description = "Distribution profile selected by the headless installer.";
    };
    heavy = lib.mkOption {
      type = lib.types.listOf (lib.types.enum catalog.heavyOptions);
      default = [ ];
      description = "Optional heavyweight full-stack components.";
    };
    edge.endpoint = lib.mkOption {
      type = lib.types.str;
      default = "tcp://127.0.0.1:42220";
      description = "Loopback ZeroMQ REP endpoint for embedded ingest.";
    };
    reconTools = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (builtins.attrNames reconToolPackages));
      default = [ ];
      description = "Authorized radio/recon tools exposed through the Common Lisp system API.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.profile == "full" || cfg.heavy == [ ];
          message = "StarIntel heavy options are valid only with the full profile.";
        }
        {
          assertion = !edgeEnabled || loopbackEndpoint;
          message = "StarIntel embedded ingest must bind to an explicit loopback endpoint.";
        }
      ];

      environment.systemPackages = [ starintelPackages.installer ]
        ++ lib.optionals edgeEnabled [ starintelPackages.edgeIngest ]
        ++ map (name: reconToolPackages.${name}) (lib.unique cfg.reconTools);

      environment.etc."starintel/distro.json".text = builtins.toJSON plan;

      systemd.services.starintel-edge-ingest = lib.mkIf edgeEnabled {
        description = "StarIntel Edge ZeroMQ to Tek9 embedded ingest";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        environment = {
          STARINTEL_EDGE_INGEST_ENDPOINT = cfg.edge.endpoint;
          STARINTEL_EDGE_DATABASE_PATH = "/var/lib/starintel-edge/tek9/";
          STARINTEL_SCHEMA_RELEASE = starintelPackages.spec.release_version;
        };
        serviceConfig = {
          ExecStart = "${starintelPackages.edgeIngest}/bin/starintel-edge-ingest";
          Restart = "on-failure";
          RestartSec = 2;
          DynamicUser = true;
          StateDirectory = "starintel-edge";
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        };
      };
    }

    (lib.mkIf (builtins.elem "rabbitmq" cfg.heavy) {
      services.rabbitmq = {
        enable = true;
        listenAddress = "127.0.0.1";
      };
    })

    (lib.mkIf (builtins.elem "couchdb" cfg.heavy) {
      services.couchdb = {
        enable = true;
        bindAddress = "127.0.0.1";
      };
    })

    (lib.mkIf (builtins.elem "search" cfg.heavy) {
      services.opensearch = {
        enable = true;
        settings = {
          "network.host" = "127.0.0.1";
          "discovery.type" = "single-node";
          "plugins.security.disabled" = true;
        };
      };
    })

    (lib.mkIf (builtins.elem "observability" cfg.heavy) {
      services.prometheus = {
        enable = true;
        listenAddress = "127.0.0.1";
      };
      services.grafana = {
        enable = true;
        settings.server.http_addr = "127.0.0.1";
      };
    })

    (lib.mkIf (builtins.elem "gpu-workers" cfg.heavy) {
      services.ollama = {
        enable = true;
        listenAddress = "127.0.0.1";
        openFirewall = false;
      };
    })
  ]);
}
