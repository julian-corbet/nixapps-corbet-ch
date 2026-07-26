# nixapps.productivity.leantime — Leantime, a self-hosted project management suite.
#
# What this recipe knows about Leantime:
#
#   - It is a PHP/nginx stack that serves both API and web interface (:8080).
#   - It uses an external MariaDB or MySQL database. You point it at one; this recipe
#     does not run a database for you. The image carries the app code and does not
#     own the schema: you must point it at a database that already exists with the
#     schema at the version this image expects.
#   - The image runs supervisord as www-data (uid 1000), and any runAsUser other than
#     1000 will cause supervisord's setuid to fail with EPERM. Therefore, securityContext
#     is pinned to uid 1000, the same as the image's built-in www-data user.
#   - Four mutable directories live on disk: userfiles, plugins, logs, and public/userfiles.
#     All are mounted as subPaths under one hostPath volume.
#   - The readiness probe targets /auth/login, which returns a direct 200. The root path
#     redirects and would cause ProbeWarnings.
#   - It has a startup probe that owns the PHP boot window (up to five minutes of cold start).
#     The readiness probe kicks in only after startup succeeds.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.productivity.leantime;
  name = "leantime";
in
{
  options.nixapps.productivity.leantime = {
    enable = lib.mkEnableOption "Leantime, a self-hosted project management suite";

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
      default = "leantime/leantime:3.4.9";
      description = ''
        Container image, pinned to a specific version.

        The image is pinned to the version that owns your database schema.
        The database has a version (e.g., 3.4.9), and the image must match it
        or match a version the image's migrations can upgrade from. Do not use
        :latest.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the application serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Leantime needs at least:

          LEAN_DB_HOST         MariaDB/MySQL hostname or IP
          LEAN_DB_USER         database username
          LEAN_DB_PASSWORD     database password
          LEAN_DB_NAME         database name (e.g., leantime)
          LEAN_APP_URL         public URL where Leantime is exposed (for links and redirects)
          LEAN_SESSION_*       session configuration (LEAN_SESSION_NAME, LEAN_SESSION_PASS)
          LEAN_OIDC_*          OIDC provider configuration (LEAN_OIDC_PROVIDER, LEAN_OIDC_CLIENT_ID,
                               LEAN_OIDC_CLIENT_SECRET, LEAN_OIDC_DISCOVERY_URL, etc.)

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding all mutable application data: userfiles, plugins,
        logs, and public/userfiles. All four subdirectories
        (userfiles/, plugins/, logs/, public_userfiles/)
        are mounted as subPaths of this one directory.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "productivity";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. The app holds file handles and uses supervisord
          # for process management.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              # The image runs supervisord as uid 1000 (www-data). Any other uid causes
              # setuid to fail with EPERM. securityContext and data ownership must be
              # pinned to 1000. fsGroup is set to document intent, though it is a no-op
              # for hostPath volumes.
              securityContext = {
                runAsUser = 1000;
                runAsGroup = 1000;
                fsGroup = 1000;
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                envFrom = [ { secretRef.name = cfg.secretName; } ];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.userfiles = {
                  name = "data";
                  mountPath = "/var/www/html/userfiles";
                  subPath = "userfiles";
                };
                volumeMounts.plugins = {
                  name = "data";
                  mountPath = "/var/www/html/app/Plugins";
                  subPath = "plugins";
                };
                volumeMounts.logs = {
                  name = "data";
                  mountPath = "/var/www/html/storage/logs";
                  subPath = "logs";
                };
                volumeMounts."public-userfiles" = {
                  name = "data";
                  mountPath = "/var/www/html/public/userfiles";
                  subPath = "public_userfiles";
                };
                # Startup probe owns the PHP boot window (up to ~5 minutes for cold start).
                startupProbe = {
                  httpGet = {
                    path = "/auth/login";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  failureThreshold = 30;
                  timeoutSeconds = 3;
                };
                # Readiness probe targets /auth/login (direct 200), not "/" (302 -> spam).
                readinessProbe = {
                  httpGet = {
                    path = "/auth/login";
                    port = cfg.port;
                  };
                  periodSeconds = 10;
                  failureThreshold = 18;
                  timeoutSeconds = 3;
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
