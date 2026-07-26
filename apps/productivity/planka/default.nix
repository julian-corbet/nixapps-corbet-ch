# nixapps.productivity.planka — Planka, a self-hosted kanban board.
#
# What this recipe knows about Planka:
#
#   - It is a Node.js application that serves an API and SPA frontend (:1337).
#   - It stores all data in a PostgreSQL database. You point it at one; this recipe
#     does not run a database for you.
#   - File uploads (board attachments, background images, user avatars, favicons)
#     are stored on disk at five locations under /app.
#   - The image logs to a file mounted at /app/logs, so it needs a writable hostPath
#     directory to avoid permission errors.
#   - The readiness probe uses TCP: Planka does not expose an HTTP health endpoint.
#   - It has no built-in retry logic for database connections, so an initContainer
#     waits for PostgreSQL to be accepting TCP before the app starts.
#   - It runs with a specific uid/gid that owns the data directories, including fsGroup
#     (unlike SQLite-only apps, fsGroup is needed here so file writes succeed).
#
{ lib, config, ... }:
let
  cfg = config.nixapps.productivity.planka;
  name = "planka";
in
{
  options.nixapps.productivity.planka = {
    enable = lib.mkEnableOption "Planka, a self-hosted kanban board";

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
      default = "ghcr.io/plankanban/planka:2.0.0-rc.3";
      description = "Container image, pinned to a specific version.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1337;
      description = "Port the application serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Planka needs at least:

          DATABASE_URL       PostgreSQL connection string (e.g., postgres://...)
          BASE_URL           public URL where Planka is exposed (for redirects and links)
          SECRET_KEY         session encryption key
          OIDC_*              OIDC provider configuration (OIDC_ISSUER, OIDC_AUTH_URL,
                              OIDC_TOKEN_URL, OIDC_USERINFO_URL, OIDC_CLIENT_ID,
                              OIDC_CLIENT_SECRET, OIDC_SCOPES, OIDC_NAME_CLAIM)

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding all file uploads: attachments, background images,
        user avatars, favicons, and application logs. All five subdirectories
        (attachments/, background-images/, favicons/, user-avatars/, logs/)
        are mounted as subPaths of this one directory.
      '';
    };

    postgresService = lib.mkOption {
      type = lib.types.str;
      description = ''
        Hostname or FQDN of the PostgreSQL service the app will connect to.
        Used by the wait-for-db initContainer to verify connectivity before
        the app starts.
      '';
    };

    postgresPort = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = "Port the PostgreSQL service listens on.";
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "productivity";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. The app is single-instance and holds file handles.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              # Planka is a Node.js app that does not setuid/privilege-drop, so it runs
              # as its configured uid. fsGroup is set so file writes to the hostPath
              # succeed with the correct ownership.
              securityContext = {
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              initContainers.wait-for-db = {
                name = "wait-for-db";
                image = "busybox:1.36";
                command = [ "sh" "-c"
                  "until nc -z ${cfg.postgresService} ${toString cfg.postgresPort}; do echo waiting-for-postgres; sleep 2; done"
                ];
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                envFrom = [ { secretRef.name = cfg.secretName; } ];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.attachments = {
                  name = "data";
                  mountPath = "/app/private/attachments";
                  subPath = "attachments";
                };
                volumeMounts."background-images" = {
                  name = "data";
                  mountPath = "/app/public/background-images";
                  subPath = "background-images";
                };
                volumeMounts.favicons = {
                  name = "data";
                  mountPath = "/app/public/favicons";
                  subPath = "favicons";
                };
                volumeMounts."user-avatars" = {
                  name = "data";
                  mountPath = "/app/public/user-avatars";
                  subPath = "user-avatars";
                };
                volumeMounts.logs = {
                  name = "data";
                  mountPath = "/app/logs";
                  subPath = "logs";
                };
                # TCP readiness; Planka does not expose an HTTP health endpoint.
                readinessProbe = {
                  tcpSocket.port = cfg.port;
                  initialDelaySeconds = 15;
                  periodSeconds = 10;
                  failureThreshold = 12;
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
