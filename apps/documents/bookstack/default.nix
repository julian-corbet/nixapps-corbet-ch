# nixapps.documents.bookstack — BookStack wiki and knowledge base.
#
# What this recipe knows about BookStack:
#
#   - It is a PHP application served via the linuxserver image. The image
#     bundles the app code; only configuration and uploads live on disk at
#     /config.
#   - It requires an external MySQL or MariaDB database. The linuxserver
#     entrypoint runs php artisan at startup, which fails with SQLSTATE 2002
#     (connection error) if the database is not reachable. An initContainer
#     waits for TCP port 3306 on the database host before allowing the app
#     to start.
#   - The linuxserver init system runs as root, chowns /config, then drops the
#     app to PUID/PGID. These env vars must match the owner of the host
#     /config directory, or new files will be owned by a mismatched uid.
#   - Configuration (database connection, OIDC provider, app key) lives in
#     the secret. The app key should be a random 32-character base64 string.
#   - OIDC is supported; set OIDC_* env vars in the secret. The first user
#     to authenticate becomes an admin.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.documents.bookstack;
  name = "bookstack";
in
{
  options.nixapps.documents.bookstack = {
    enable = lib.mkEnableOption "BookStack, a wiki and knowledge base";

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
      default = "lscr.io/linuxserver/bookstack:version-v26.05.2";
      description = ''
        Container image, pinned by version. The linuxserver.io variant
        includes all init infrastructure.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Port the web application serves HTTP on.";
    };

    puid = lib.mkOption {
      type = lib.types.int;
      description = ''
        Numeric UID to run the application as. Must match the owner of the
        host /config directory, or new files will have mismatched permissions.
      '';
    };

    pgid = lib.mkOption {
      type = lib.types.int;
      description = ''
        Numeric GID to run the application as. Should match pgid if the
        host directory is owned by a single group.
      '';
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. BookStack needs at least:

          DB_HOST                MySQL/MariaDB hostname
          DB_PORT                Database port (usually 3306)
          DB_USER                Database username
          DB_PASSWORD            Database password
          DB_DATABASE            Database name
          APP_KEY                32-character base64 encryption key
          APP_URL                Public URL (e.g., https://bookstack.example.com)

        And if using OIDC:
          OIDC_CLIENT_ID         OIDC provider client ID
          OIDC_CLIENT_SECRET     OIDC provider client secret
          (and other OIDC_* configuration as needed)

        This recipe never renders the Secret. Rendering one would put
        credentials into a manifest tree.
      '';
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding application configuration, uploads, and
        database backups. Must persist across restarts. Maps to /config
        in the container.
      '';
    };

    dbHost = lib.mkOption {
      type = lib.types.str;
      description = ''
        Hostname or IP of the MySQL/MariaDB server. The initContainer waits
        for TCP port 3306 on this host before the app starts.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "documents";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. A single pod holds the mutable state.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              # Wait for the database to accept TCP connections before starting
              # the app. The linuxserver entrypoint runs php artisan at boot,
              # which exits 255 if MariaDB is unreachable.
              initContainers.wait-for-db = {
                name = "wait-for-db";
                image = "busybox:1.36";
                command = [
                  "sh"
                  "-c"
                  "until nc -z ${cfg.dbHost} 3306; do echo waiting-for-mariadb; sleep 2; done"
                ];
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env = {
                  PUID = { name = "PUID"; value = builtins.toString cfg.puid; };
                  PGID = { name = "PGID"; value = builtins.toString cfg.pgid; };
                };
                envFrom = [{ secretRef.name = cfg.secretName; }];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.config = {
                  name = "config";
                  mountPath = "/config";
                };
                readinessProbe = {
                  tcpSocket.port = cfg.port;
                  initialDelaySeconds = 20;
                  periodSeconds = 10;
                  failureThreshold = 18;
                };
              };
              volumes.config = {
                name = "config";
                hostPath = {
                  path = cfg.configPath;
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
