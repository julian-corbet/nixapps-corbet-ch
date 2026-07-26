# nixapps.documents.overleaf — Overleaf (sharelatex) collaborative LaTeX editor.
#
# What this recipe knows about Overleaf:
#
#   - It is a Node.js web application serving HTTP on :80. The image bundles
#     all application code; only mutable state (projects, compile artifacts,
#     history) lives on disk.
#   - It requires MongoDB (external; you point it at a replica set via connection
#     string in the environment). Transactions require a replica set, not a
#     standalone instance. The connection string typically uses in-cluster DNS.
#   - It needs Redis in-cluster as a session/cache store. Redis is ephemeral;
#     session state is lost on restart but users re-login.
#   - Startup is slow: the application performs initialization tasks on boot.
#     The readiness probe is very patient.
#   - You must provide a database connection string and configuration via the
#     secret. Typical required keys include MONGO_URL, REDIS_HOST, REDIS_PORT,
#     and any OIDC or JWT configuration.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.documents.overleaf;
  name = "overleaf";
  redisName = "overleaf-redis";
in
{
  options.nixapps.documents.overleaf = {
    enable = lib.mkEnableOption "Overleaf, a collaborative LaTeX editor";

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
      default = "sharelatex/sharelatex:5.5.8";
      description = ''
        Container image, pinned by version. The image bundles the entire
        application; only state lives on the host.
      '';
    };

    redisImage = lib.mkOption {
      type = lib.types.str;
      default = "redis:7-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2";
      description = "Redis container image for session storage.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Port the web application serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Overleaf needs at least:

          MONGO_URL              MongoDB connection string (must be a replica set)
          REDIS_HOST             Redis hostname (usually the service name)
          REDIS_PORT             Redis port (usually 6379)

        And if using OIDC or other auth:
          OAUTH2_CLIENT_ID       OIDC client ID
          OAUTH2_CLIENT_SECRET   OIDC client secret
          (or other auth-related configuration)

        This recipe never renders the Secret. Rendering one would put
        credentials into a manifest tree.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding projects, compile artifacts, and history.
        Must persist across restarts. Maps to /var/lib/overleaf in the container.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "documents";

      resources = {
        deployments.${name}.spec = {
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                envFrom = [{ secretRef.name = cfg.secretName; }];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/var/lib/overleaf";
                };
                readinessProbe = {
                  tcpSocket.port = cfg.port;
                  initialDelaySeconds = 45;
                  periodSeconds = 10;
                  failureThreshold = 40;
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

        deployments.${redisName}.spec = {
          selector.matchLabels.app = redisName;
          template = {
            metadata.labels.app = redisName;
            spec = {
              containers.${redisName} = {
                name = "redis";
                image = cfg.redisImage;
                ports.redis = {
                  name = "redis";
                  containerPort = 6379;
                };
                readinessProbe = {
                  tcpSocket.port = 6379;
                  periodSeconds = 10;
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

        services.${redisName}.spec = {
          type = "ClusterIP";
          selector.app = redisName;
          ports.redis = {
            name = "redis";
            port = 6379;
            targetPort = 6379;
          };
        };
      };
    };
  };
}
