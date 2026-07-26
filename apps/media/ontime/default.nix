# nixapps.media.ontime — ontime, an event timer and rundown app.
#
# What this recipe knows about ontime:
#
#   - It is a self-contained Node web app serving HTTP on :4001. There is no
#     separate database; state is a tree of readable JSON files and assets.
#   - The app writes data to a single directory that you must provide. Persistence
#     is entirely there: app-state.json, rundown projects, styles, translations.
#   - It is single-writer: Recreate strategy enforces that only one pod ever
#     touches the data tree at a time.
#   - The readiness probe is quick (checks every 5 seconds). The app starts fast
#     and holds no long-running migrations.
#   - fsGroup must never be set. It would recursively chown the hostPath and
#     break existing dataset permissions. The pod must have direct read/write
#     access to the data path as-is.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.media.ontime;
  name = "ontime";
in
{
  options.nixapps.media.ontime = {
    enable = lib.mkEnableOption "ontime, an event timer and rundown app";

    namespace = lib.mkOption {
      type = lib.types.str;
      description = "Namespace to deploy into.";
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this application creates its own namespace. Set false if
        something else in your cluster owns it already.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "getontime/ontime:v4.11.0@sha256:3fd6b7265c3430131de0b6258798a316133b5fcd30f4ba5a4fb5330c9454516f";
      description = ''
        Container image for ontime.

        The app writes JSON state to disk. A floating tag can therefore upgrade
        and reformat data without review. Pin this to a specific version before
        using in production, and test upgrades first.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4001;
      description = "Port the Node app serves HTTP on.";
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the application state and assets.

        The pod writes: app-state.json, rundown projects, user styles and
        translations, and any external integrations. Everything is readable
        JSON; it is safe to back up and inspect directly.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "media";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. ontime is single-writer over the data
          # directory. A rolling update would briefly run two instances against
          # the same state, corrupting it. Only one pod touches the data at a time.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env.TZ = {
                  name = "TZ";
                  value = "UTC";
                };
                env.NODE_ENV = {
                  name = "NODE_ENV";
                  value = "docker";
                };
                env.ONTIME_DATA = {
                  name = "ONTIME_DATA";
                  value = "/data/";
                };
                env.CA_TS_FALLBACK_DIR = {
                  name = "CA_TS_FALLBACK_DIR";
                  value = "/data/";
                };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/data";
                };
                # Quick probe. ontime starts fast and has no long-running
                # migrations. Check every 5 seconds with 2 minutes of patience.
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 24;
                };
                # Liveness is gentler: every 15 seconds with 90 seconds patience.
                # Detects hangs but doesn't thrash.
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 15;
                  failureThreshold = 6;
                };
              };
              # DO NOT set fsGroup. It would recursively chown the hostPath,
              # breaking bind-mounted dataset permissions. The pod must read/write
              # the data directory as-is, using the identity that owns it on the host.
              volumes.data = {
                name = "data";
                hostPath = {
                  path = cfg.dataPath;
                  type = "Directory";
                };
              };
            };
          };
        };

        services.${name}.spec = {
          type = "ClusterIP";
          selector.app = name;
          ports.http = {
            name = "http";
            port = cfg.port;
            targetPort = cfg.port;
          };
        };
      };
    };
  };
}
