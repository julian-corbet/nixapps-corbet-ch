# nixapps.dev.whodb — WhoDB, a database browser and SQL IDE for multiple databases.
#
# What this recipe knows about WhoDB:
#
#   - It is a web-based database browser that can connect to multiple database
#     engines simultaneously: PostgreSQL, MySQL/MariaDB, MongoDB, SQLite, Redis,
#     and others. Connections are configured via environment variables that
#     hold JSON credential objects.
#   - It serves HTTP on port 8080 and stores session state in SQLite, persisted
#     to disk. The one directory it writes to is the entire persistence story.
#   - It requires an encryption key for session storage (WHODB_ENCRYPTION_KEY).
#     This must be created and stored out-of-band in a k8s Secret before the
#     first deployment.
#   - Database connections are pre-configured by setting environment variables
#     named WHODB_<TYPE>_<N>, where <TYPE> is the database engine (POSTGRES,
#     MARIADB, MONGODB, etc.) and <N> is a numeric index. Each must contain a
#     JSON credential object with the connection details. WhoDB does not support
#     interactive connection setup in this recipe; all connections must exist
#     before startup.
#   - Deployment uses Recreate strategy. WhoDB holds session state in a local
#     SQLite database; running two pods would corrupt it. The container runs as
#     a non-root user whose UID/GID must match the owner of the session store
#     directory.
#   - The allowedOrigins setting prevents CORS warnings. It should match the
#     hostname through which the pod is accessed.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.dev.whodb;
  name = "whodb";
in
{
  options.nixapps.dev.whodb = {
    enable = lib.mkEnableOption "WhoDB, a database browser and SQL IDE";

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
      default = "clidey/whodb@sha256:61159d9089222b3c725037cf543a462a3c859eb50fd14dfceab7a30dbac45229";
      description = "Container image.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the HTTP server listens on.";
    };

    allowedOrigins = lib.mkOption {
      type = lib.types.str;
      description = ''
        The hostname(s) through which users access WhoDB. Used to prevent
        CORS warnings and to set cookie security attributes correctly.
        Should be a comma-separated list of HTTPS URLs (e.g.,
        "https://whodb.example.com").
      '';
    };

    secure = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set to true for HTTPS-only cookies and Secure flag. This should match
        whether the application is fronted by a reverse proxy that enforces
        HTTPS.
      '';
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. WhoDB requires at least:

          WHODB_ENCRYPTION_KEY   arbitrary secret string for encrypting session
                                 storage; preserve across deployments

        Database connections are configured by adding environment variables to
        this Secret. Each connection uses a key named WHODB_<TYPE>_<N>, where
        <TYPE> is a database engine (POSTGRES, MARIADB, MONGODB, etc.) and <N>
        is a numeric index starting at 1. The value must be a JSON object with
        connection details. Examples:

          WHODB_POSTGRES_1   '{"database": "mydb", "user": "reader", ...}'
          WHODB_MARIADB_1    '{"database": "shop", "user": "root", ...}'
          WHODB_MONGODB_1    '{"connectionString": "mongodb://..."}'

        Refer to the WhoDB documentation for the exact schema required for each
        database type. This recipe never renders the Secret. Rendering one
        would mean putting credentials into a manifest tree.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the WhoDB session store (SQLite database).

        WhoDB writes session state to this directory. It must be an existing
        directory owned by a non-root UID/GID that the pod is configured to
        run as.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "dev";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. WhoDB maintains session state in SQLite;
          # running two pods on the same database will corrupt it. The old pod
          # must be torn down before the new one starts.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env.WHODB_SECURE = {
                  name = "WHODB_SECURE";
                  value = if cfg.secure then "true" else "false";
                };
                env.WHODB_ALLOWED_ORIGINS = {
                  name = "WHODB_ALLOWED_ORIGINS";
                  value = cfg.allowedOrigins;
                };
                envFrom = [{ secretRef.name = cfg.secretName; }];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/data";
                };
                readinessProbe = {
                  tcpSocket.port = cfg.port;
                  periodSeconds = 5;
                  failureThreshold = 30;
                };
                livenessProbe = {
                  tcpSocket.port = cfg.port;
                  periodSeconds = 20;
                  failureThreshold = 6;
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
