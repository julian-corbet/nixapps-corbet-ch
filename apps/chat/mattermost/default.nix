# nixapps.chat.mattermost — Mattermost, a self-hosted team chat platform.
#
# What this recipe knows about Mattermost:
#
#   - It is a Go application bundled with a React webapp. The image holds both
#     the binary and the web assets. It serves the API and web UI on :8065.
#   - The database is external PostgreSQL (or MySQL if you override the config).
#     This recipe does not run a database for you. Mattermost exits with an
#     error if the database is not reachable at startup.
#   - The mutable state lives in six directories inside the container
#     (/mattermost/config, /data, /logs, /plugins, /client/plugins,
#     /bleve-indexes). All six are mounted from subdirectories of a single host
#     path, each as a subPath.
#   - It runs as uid:gid 2000. The host directories come back owned root:root
#     after restore from backup, and fsGroup does not apply to hostPath volumes,
#     so an initContainer must chown them before startup.
#   - It waits for the database to be accepting TCP before starting (via an init
#     container). Mattermost crashes with unhelpful errors if the DB is down at
#     boot, so this wait is critical to avoid a crash loop.
#   - Strategy is Recreate (single writer on the data directories).
#   - The image is pinned by digest to the exact version that wrote the schema,
#     so schema migrations do not happen on boot.
#
# The operator supplies:
#   - A host directory that will contain config, data, logs, plugins,
#     client/plugins, and bleve-indexes subdirectories
#   - A Secret holding at least MM_SQLSETTINGS_DATASOURCE (the database
#     connection string) and MM_SITEURL (the public URL)
#   - The address and port of the external database (usually injected via the
#     Secret environment variables)
#
{ lib, config, ... }:
let
  cfg = config.nixapps.chat.mattermost;
  name = "mattermost";
in
{
  options.nixapps.chat.mattermost = {
    enable = lib.mkEnableOption "Mattermost, a self-hosted team chat platform";

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
      default = "mattermost/mattermost-team-edition@sha256:ea589dabb1fce993381ae8fc2c74e06ae21e24575d843ec4c5903dd28ae3b909";
      description = ''
        Container image, pinned by digest.

        Mattermost runs schema migrations when the image version changes. A
        floating tag can therefore migrate the database on deploy, and you have
        no way to review the diff beforehand. Pin it, and move the pin
        deliberately when you want to migrate.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8065;
      description = "Port the Mattermost API and web UI listen on.";
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the six mutable Mattermost directories.

        The directory tree should contain these subdirectories (or they will be
        created):
          config           — server configuration (config.json)
          data             — uploaded files, avatars, etc.
          logs             — application logs
          plugins          — server plugins
          client/plugins   — webapp plugins
          bleve-indexes    — search indexes

        After restore from backup, these directories may be owned root:root.
        An initContainer will chown them to uid:gid 2000:2000 before Mattermost
        starts, so you do not need to do this yourself. However, if you are
        bringing over data from another instance, ensure the parent directory
        already exists and is accessible.
      '';
    };

    dbHost = lib.mkOption {
      type = lib.types.str;
      description = ''
        Hostname or IP address of the PostgreSQL or MySQL database server.

        The initContainer waits for this host:port to be accepting TCP before
        Mattermost starts. This prevents a crash loop if the database is
        temporarily unavailable.
      '';
    };

    dbPort = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = ''
        Port the database server listens on (5432 for PostgreSQL, 3306 for MySQL).
      '';
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Mattermost needs at least:

          MM_SQLSETTINGS_DATASOURCE   the database connection string (e.g.,
                                      "postgres://user:pass@host:5432/dbname")
          MM_SITEURL                  the public https:// URL of your Mattermost
                                      instance (e.g., "https://chat.example.com");
                                      if wrong, links in notifications and the
                                      web UI will be broken

        Any other MM_* environment variables you need (timezone, SMTP config,
        etc.) can be added to this Secret and they will be passed through.

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "chat";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. Mattermost holds the six data directories open
          # and expects to be the single writer (especially to config.json and the
          # database). A rolling update briefly runs two pods, both trying to write,
          # leading to corruption.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              securityContext = {
                runAsUser = 2000;
                runAsGroup = 2000;
                fsGroup = 2000;
              };
              initContainers.fix-perms = {
                name = "fix-perms";
                image = "busybox:1.36";
                securityContext.runAsUser = 0;
                command = [ "sh" "-c" "chown -R 2000:2000 /data" ];
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/data";
                };
              };
              initContainers.wait-for-db = {
                name = "wait-for-db";
                image = "busybox:1.36";
                command = [
                  "sh"
                  "-c"
                  "until nc -z ${cfg.dbHost} ${toString cfg.dbPort}; do echo waiting-for-database; sleep 2; done"
                ];
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                envFrom = [{ secretRef.name = cfg.secretName; }];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.config = {
                  name = "data";
                  mountPath = "/mattermost/config";
                  subPath = "config";
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/mattermost/data";
                  subPath = "data";
                };
                volumeMounts.logs = {
                  name = "data";
                  mountPath = "/mattermost/logs";
                  subPath = "logs";
                };
                volumeMounts.plugins = {
                  name = "data";
                  mountPath = "/mattermost/plugins";
                  subPath = "plugins";
                };
                volumeMounts.client-plugins = {
                  name = "data";
                  mountPath = "/mattermost/client/plugins";
                  subPath = "client/plugins";
                };
                volumeMounts.bleve-indexes = {
                  name = "data";
                  mountPath = "/mattermost/bleve-indexes";
                  subPath = "bleve-indexes";
                };
                readinessProbe = {
                  httpGet = {
                    path = "/api/v4/system/ping";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 20;
                  periodSeconds = 10;
                  failureThreshold = 18;
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
