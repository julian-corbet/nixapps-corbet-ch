# nixapps.home.homarr — Homarr, a self-hosted dashboard application.
#
# What this recipe knows about Homarr:
#
#   - It is a self-contained Node.js application with embedded SQLite and
#     embedded Redis. No separate database or cache service needed. All data
#     lives in the shared /appdata directory: SQLite database (db/db.sqlite),
#     Redis dump (redis/), user-supplied CA certificates (trusted-certificates/),
#     and Tailscale CA fallback (tailscale/).
#   - It serves HTTP on a single port (7575) for web UI and API.
#   - It authenticates users via OIDC (OpenID Connect) against an external
#     identity provider. The operator must supply the OIDC issuer URL, client ID,
#     and client secret.
#   - It encrypts stored integration credentials at-rest using a secret encryption
#     key. This key must be the same across restarts; a new key invalidates
#     existing stored credentials but does NOT affect dashboards or inventory data.
#   - It is single-writer: only one pod should ever access /appdata (SQLite
#     database + Redis dump). The Recreate strategy enforces this.
#   - It runs as UID:GID 3002:3002. The data directory must be owned by this
#     UID and group.
#
# The pod does not set runAsUser/runAsGroup/fsGroup in the securityContext.
# The image's entrypoint runs as root, chowns /appdata to the configured
# PUID/PGID (3002:3002 via env vars), and then drops privilege via its own init.
# Forcing runAsUser would prevent the root-only chown and cause crash-loops.
# Container-level securityContext denies privilege escalation. A startup probe
# owns the cold-boot window (Node + DB migrations + Redis initialization) so
# the readiness probe does not flap under host I/O load.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.home.homarr;
  name = "homarr";
in
{
  options.nixapps.home.homarr = {
    enable = lib.mkEnableOption "Homarr, a self-hosted dashboard application";

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
      default = "ghcr.io/homarr-labs/homarr@sha256:dc16da05861c8f6f5839495bf59c241e7f4bacd850fe7d472ad3c4fa37fb2f75";
      description = ''
        Container image, pinned by digest (upstream publishes no version label,
        only a floating tag that changes on every rebuild).

        A floating tag can change behavior between deploys with nothing to review
        beforehand. The image is pinned by digest; to update it, edit this option
        and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 7575;
      description = "Port the Homarr application serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace. Homarr requires:

          SECRET_ENCRYPTION_KEY             secret key for at-rest encryption of
                                            stored integration credentials. Must
                                            be >=32 bytes and the same across
                                            restarts. A new value invalidates
                                            stored credentials but not dashboards
                                            or widget data. If migrating data
                                            from an existing Homarr instance,
                                            the key MUST match the original value
                                            or credentials cannot be decrypted.
                                            Generate via: openssl rand -base64 48

          AUTH_OIDC_CLIENT_SECRET           OIDC client secret for the identity
                                            provider configured in
                                            authOidcIssuer and authOidcClientId

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };

    authOidcIssuer = lib.mkOption {
      type = lib.types.str;
      description = ''
        OIDC issuer URL (e.g., https://auth.example.com). Users will be
        redirected here for login.
      '';
    };

    authOidcClientId = lib.mkOption {
      type = lib.types.str;
      description = ''
        OIDC client ID registered with the issuer above.
      '';
    };

    authOidcClientName = lib.mkOption {
      type = lib.types.str;
      default = "Homarr";
      description = ''
        Display name for the OIDC provider shown on the login page.
      '';
    };

    adminGroup = lib.mkOption {
      type = lib.types.str;
      description = ''
        OIDC groups claim value that grants admin access (e.g., "homarr_admin").
        Users in this group will be admins; others will be members.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the Homarr application data: SQLite database
        (db/db.sqlite), embedded Redis dump (redis/), user CA certificates
        (trusted-certificates/), and Tailscale CA fallback (tailscale/).
        Must be owned by UID:GID 3002:3002. DirectoryOrCreate allows the
        pod to initialize an empty directory on first run.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "home";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. Homarr is single-writer on its SQLite
          # database and embedded Redis dump. Never run two pods on the same
          # /appdata.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              # NO pod-level securityContext runAsUser/runAsGroup/fsGroup: the
              # homarr image entrypoint MUST start as root to chown /appdata to
              # PUID/PGID, then drops to PUID 3002 via its own init. Forcing
              # runAsUser prevents this and causes crash-loops. fsGroup would
              # recursively chown the hostPath dataset and conflict with the app
              # init, so it is omitted.
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                securityContext = {
                  allowPrivilegeEscalation = false;
                };
                env = {
                  PUID.value = "3002";
                  PGID.value = "3002";
                  NODE_ENV.value = "production";
                  REDIS_IS_EXTERNAL.value = "false";
                  CA_TS_FALLBACK_DIR.value = "/appdata/tailscale";
                  # OIDC authentication
                  AUTH_PROVIDERS.value = "oidc";
                  AUTH_OIDC_ISSUER.value = cfg.authOidcIssuer;
                  AUTH_OIDC_CLIENT_ID.value = cfg.authOidcClientId;
                  AUTH_OIDC_CLIENT_NAME.value = cfg.authOidcClientName;
                  AUTH_OIDC_SCOPE_OVERWRITE.value = "openid email profile groups";
                  AUTH_OIDC_GROUPS_ATTRIBUTE.value = "groups";
                  AUTH_OIDC_NAME_ATTRIBUTE_OVERWRITE.value = "preferred_username";
                  AUTH_OIDC_AUTO_LOGIN.value = "false";
                  AUTH_LOGOUT_REDIRECT_URL.value = "";
                  AUTH_SESSION_EXPIRY_TIME.value = "30d";
                  ADMIN_GROUP.value = cfg.adminGroup;
                  # Database (embedded SQLite)
                  DB_DRIVER.value = "better-sqlite3";
                  DB_DIALECT.value = "sqlite";
                  DB_URL.value = "/appdata/db/db.sqlite";
                  DB_MIGRATIONS_DISABLED.value = "false";
                };
                # Load secret values: SECRET_ENCRYPTION_KEY, AUTH_OIDC_CLIENT_SECRET
                envFrom = [{ secretRef.name = cfg.secretName; }];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.appdata = {
                  name = "appdata";
                  mountPath = "/appdata";
                };
                # Startup probe owns the cold-boot window (Node + DB migrations +
                # Redis init) so readiness doesn't flap under host I/O load.
                startupProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 3;
                  failureThreshold = 40;
                  timeoutSeconds = 5;
                };
                # Readiness gates the Service endpoint so the KEDA interceptor
                # (if in use) only forwards the held request once HTTP is up.
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 30;
                  timeoutSeconds = 5;
                };
              };
              volumes.appdata = {
                name = "appdata";
                hostPath = {
                  path = cfg.dataPath;
                  type = "DirectoryOrCreate";
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
