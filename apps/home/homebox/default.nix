# nixapps.home.homebox — Homebox, a household inventory and asset management application.
#
# What this recipe knows about Homebox:
#
#   - It is a self-contained Go application with an embedded SQLite database.
#     There is no separate database to manage. All data lives in the shared
#     data directory: homebox.db (SQLite), attachment files, and configuration.
#   - It runs on a single port (7745) for both web UI and API.
#   - It requires an authentication API key pepper (>=32 bytes) to initialize
#     the database and manage encryption of stored credentials. This pepper
#     must be the same across restarts; a new pepper invalidates existing API
#     keys and login sessions but does NOT affect inventory data.
#   - It is single-writer: only one pod should ever access the database.
#     The Recreate strategy enforces this.
#   - It runs as UID:GID 3030:3030, the per-app identity. The data directory
#     must be owned by this UID and group.
#
# The pod does not set runAsUser/runAsGroup at the pod level, and fsGroup is
# intentionally omitted (it would recursively chown the hostPath and conflict
# with the app's own init). The image's entrypoint runs as root, chowns the
# /data directory to the configured PUID/PGID (3030:3030), and then drops
# privilege. Container-level securityContext denies privilege escalation and
# drops all Linux capabilities.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.home.homebox;
  name = "homebox";
in
{
  options.nixapps.home.homebox = {
    enable = lib.mkEnableOption "Homebox, a household inventory and asset management application";

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
      default = "ghcr.io/sysadminsmedia/homebox:0.26.2@sha256:b1ad7e3c63f732a5f6daa466e8116be4f545b3b120383a64dcb62beb00a660cc";
      description = ''
        Container image, pinned to 0.26.2 by digest.

        Homebox may migrate its database schema on startup. A floating tag can
        run unreviewed migrations. The image is pinned by digest; to update it,
        edit this option and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 7745;
      description = "Port the Homebox application serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Homebox requires at least:

          HBOX_AUTH_API_KEY_PEPPER     >=32 byte string for database encryption
                                       key management. Must be the same across
                                       restarts; a new value invalidates API
                                       keys and sessions but not inventory data.
                                       Generate via: openssl rand -base64 48

        Optional but common:
          HBOX_MAILER_PASSWORD         if email notifications are desired

        Environment variables for email (if using HBOX_MAILER_PASSWORD):
          HBOX_MAILER_HOST             SMTP server hostname
          HBOX_MAILER_PORT             SMTP server port
          HBOX_MAILER_USERNAME         SMTP authentication username
          HBOX_MAILER_FROM             sender email address

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the Homebox data: homebox.db (SQLite),
        attachment files, and configuration. Must be owned by UID:GID 3030:3030.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "home";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. Homebox is single-writer on its SQLite
          # database. Never run two pods on the same database.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              securityContext = {
                runAsUser = 3030;
                runAsGroup = 3030;
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = [ "ALL" ];
                };
                env = {
                  HBOX_MODE.value = "production";
                  HBOX_DATABASE_SQLITE_PATH.value = "/data/homebox.db?_pragma=busy_timeout=2000&_pragma=journal_mode=WAL&_fk=1&_time_format=sqlite";
                  HBOX_STORAGE_CONN_STRING.value = "file:///?no_tmp_dir=true";
                  HBOX_STORAGE_PREFIX_PATH.value = "data";
                  HBOX_OPTIONS_ALLOW_REGISTRATION.value = "false";
                  HBOX_OPTIONS_AUTO_INCREMENT_ASSET_ID.value = "true";
                  HBOX_OPTIONS_CHECK_GITHUB_RELEASE.value = "true";
                  HBOX_LOG_FORMAT.value = "text";
                  HBOX_LOG_LEVEL.value = "info";
                  HBOX_WEB_MAX_UPLOAD_SIZE.value = "100";
                  HBOX_WEB_READ_TIMEOUT.value = "60s";
                  HBOX_WEB_WRITE_TIMEOUT.value = "60s";
                  HBOX_WEB_IDLE_TIMEOUT.value = "60s";
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
                  httpGet = {
                    path = "/api/v1/status";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 24;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/api/v1/status";
                    port = cfg.port;
                  };
                  periodSeconds = 15;
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
