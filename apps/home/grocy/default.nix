# nixapps.home.grocy — Grocy, a household inventory and meal planning application.
#
# What this recipe knows about Grocy:
#
#   - It is a self-contained PHP application served by Nginx. It runs on :80.
#   - All data lives in SQLite (embedded in the app directory). There is no
#     separate database to manage.
#   - It reads and writes a single directory: the application data, settings,
#     and database file. That directory is the whole persistence story.
#   - It migrates the database schema on startup. That is why readiness is
#     patient and why the image should be pinned by digest or version tag
#     rather than floating on latest.
#   - It is single-writer: only one pod should ever access the data directory.
#     The Recreate strategy enforces this.
#
# This recipe works with linuxserver/grocy, which manages user identity via
# PUID/PGID environment variables. The operator must ensure the data directory
# is owned by the configured PUID/PGID (the image will chown it if needed, but
# pre-creating with correct ownership is faster). The TZ environment variable
# can be set via env overrides if needed; this recipe does not expose timezone
# as an option since it is operational policy.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.home.grocy;
  name = "grocy";
in
{
  options.nixapps.home.grocy = {
    enable = lib.mkEnableOption "Grocy, a household inventory application";

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
      default = "lscr.io/linuxserver/grocy:v4.6.0-ls334@sha256:35b2c85b1238f8249c9b349fb03619d1915917e61b2e4bff580729ec87397b4c";
      description = ''
        Container image, pinned to v4.6.0-ls334 by digest.

        Grocy migrates its SQLite schema on startup. A floating tag can run a
        migration on a deploy nobody reviewed. The image is pinned by digest;
        to update it, edit this option and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Port the in-image Nginx serves HTTP on.";
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the Grocy application directory, database, and
        configuration. Grocy stores everything here: settings.ini, grocy.db
        (SQLite), and the data/ subtree.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "home";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. Grocy is single-writer on its SQLite database
          # in the shared data directory. Never run two pods on the same data.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/config";
                };
                # Grocy auto-migrates the SQLite schema on startup. Give it
                # time to finish: approximately 2 minutes of patience.
                readinessProbe = {
                  tcpSocket.port = cfg.port;
                  initialDelaySeconds = 15;
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
