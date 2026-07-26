# nixapps.dev.bytestash — Bytestash, a self-hosted code snippet manager.
#
# What this recipe knows about Bytestash:
#
#   - It is a Node.js web application that stores snippets in SQLite, persisted
#     to disk. It is stateless otherwise (no database container needed), and the
#     one directory it writes to is the entire persistence story.
#   - It runs on HTTP port 5000. The startup probe is patient because a cold
#     boot of a SQLite-backed app can be slow.
#   - It uses OIDC for SSO authentication. Internal account creation and login
#     can be disabled to enforce SSO-only auth.
#   - It requires a long-lived JWT signing key to preserve existing sessions
#     across restarts. These secrets must be created and stored out-of-band
#     (in a k8s Secret) before the first deployment.
#   - Deployment uses Recreate strategy, not rolling updates. SQLite allows only
#     one writer; running two pods would corrupt the database. The container
#     runs as a non-root user whose UID/GID must match the owner of the
#     persisted data directory.
#
# KEDA HTTP scale-to-zero is configured separately (outside this recipe) by
# the operator's Argo application layer, watching the same domain and idling
# the pod after 300 seconds of inactivity.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.dev.bytestash;
  name = "bytestash";
in
{
  options.nixapps.dev.bytestash = {
    enable = lib.mkEnableOption "Bytestash, a self-hosted code snippet manager";

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
      default = "ghcr.io/jordan-dalby/bytestash:1.5.12@sha256:eb4f736b8cd45443be0ed6d8da3ee49b76dbf27f4d3925b81b3c407207e62531";
      description = "Container image.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Port the HTTP server listens on.";
    };

    oidcIssuerUrl = lib.mkOption {
      type = lib.types.str;
      description = ''
        Public HTTPS URL of the OIDC provider (e.g., https://auth.example.com).
        This is where users will be redirected to log in.
      '';
    };

    oidcClientId = lib.mkOption {
      type = lib.types.str;
      description = ''
        Client ID registered with the OIDC provider for this application.
      '';
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Bytestash requires at least:

          OIDC_CLIENT_SECRET   from your OIDC provider registration
          JWT_SECRET           arbitrary secret string for signing JWTs; preserve
                               this across deployments to keep sessions valid

        The Secret may also contain any of these optional configuration keys:
          ALLOW_NEW_ACCOUNTS   "true" or "false" (default: false)
          DISABLE_INTERNAL_ACCOUNTS "true" or "false"; set to enforce OIDC-only
          TOKEN_EXPIRY         token lifetime (e.g. "2w" for 2 weeks)
          DEBUG                "true" or "false"
          OIDC_ENABLED         "true" or "false"
          OIDC_DISPLAY_NAME    label shown on login button (e.g., "Corporate ID")
          TZ                   timezone name (e.g., "UTC", "America/New_York")

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the SQLite database and snippet storage.

        Bytestash writes to snippets.db and related SQLite files inside the
        directory pointed to by this path. This must be an existing directory
        owned by a non-root UID/GID that the pod is configured to run as.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "dev";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. SQLite is single-writer; running two pods
          # on the same database will corrupt it. The old pod must be torn down
          # before the new one starts.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env.OIDC_ISSUER_URL = {
                  name = "OIDC_ISSUER_URL";
                  value = cfg.oidcIssuerUrl;
                };
                env.OIDC_CLIENT_ID = {
                  name = "OIDC_CLIENT_ID";
                  value = cfg.oidcClientId;
                };
                envFrom = [{ secretRef.name = cfg.secretName; }];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/data/snippets";
                };
                # Cold boot can be slow (initializing SQLite, possible migrations).
                # 300 second budget before giving up and restarting.
                startupProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 60;
                  timeoutSeconds = 5;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 10;
                  failureThreshold = 6;
                  timeoutSeconds = 5;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 20;
                  failureThreshold = 6;
                  timeoutSeconds = 5;
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
