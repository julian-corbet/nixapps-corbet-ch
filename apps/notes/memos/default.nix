# nixapps.notes.memos — memos, a self-hosted note app.
#
# What this recipe knows about memos:
#
#   - It is a lightweight SQLite-backed note app; no database container needed.
#   - The only thing it writes to disk is the note database. Everything else is
#     in-memory or derived from the DB, so one directory is the whole
#     persistence story.
#   - It runs its schema migrations on startup, making the readiness probe
#     deliberately patient. The image is pinned to the version deployed.
#   - Single-writer SQLite: only one pod should ever access the data directory.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.notes.memos;
  name = "memos";
in
{
  options.nixapps.notes.memos = {
    enable = lib.mkEnableOption "memos, a self-hosted note app";

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
      default = "neosmemo/memos:0.24";
      description = "Container image.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5230;
      description = "Port the app serves HTTP on.";
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = "Host directory for the SQLite database.";
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "notes";

      resources = {
        deployments.${name}.spec = {
          # Single-writer SQLite: never run two pods on the same database.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env.MEMOS_MODE = { name = "MEMOS_MODE"; value = "prod"; };
                env.MEMOS_PORT = { name = "MEMOS_PORT"; value = toString cfg.port; };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/var/opt/memos";
                };
                # Migrations on startup. Patient probe: ~120s before giving up.
                readinessProbe = {
                  httpGet = {
                    path = "/healthz";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 24;
                };
              };
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
