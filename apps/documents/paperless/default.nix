# nixapps.documents.paperless — Paperless-ngx document management system.
#
# What this recipe knows about Paperless:
#
#   - It is a Python web application serving HTTP on :8000. The image remaps
#     its internal user to uid 33 via USERMAP_UID/USERMAP_GID, so there is no
#     securityContext.runAsUser.
#   - Its database is SQLite, not external. The database, search index, and
#     classifier pickle live in one directory. This is the only required backup
#     target beyond the documents themselves.
#   - The mutable data spreads across four directories: the database, the media
#     documents (scanned PDFs), the consume folder (watched for new uploads),
#     and the export folder (for bulk export). All four must persist.
#   - It runs schema migrations on startup. The startup probe is patient because
#     a fresh installation can take several minutes.
#   - It needs Redis in-cluster as a broker for background tasks: the consumer
#     watches the consume folder and auto-ingests files, and the scheduler
#     handles email fetch and timers. Redis is ephemeral; queue state is lost
#     on restart but re-detected via polling.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.documents.paperless;
  name = "paperless";
  redisName = "paperless-redis";
in
{
  options.nixapps.documents.paperless = {
    enable = lib.mkEnableOption "Paperless-ngx, a document management system";

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
      default = "ghcr.io/paperless-ngx/paperless-ngx:2.20.15";
      description = ''
        Container image, pinned by version. Paperless runs schema migrations
        on startup, so upgrading is not automatic. Pin it deliberately.
      '';
    };

    redisImage = lib.mkOption {
      type = lib.types.str;
      default = "redis:7-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2";
      description = "Redis container image for the in-cluster broker.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "Port the web application serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Paperless needs at least:

          PAPERLESS_SECRET_KEY                  Django secret
          PAPERLESS_EMAIL_HOST_PASSWORD         SMTP password
          PAPERLESS_SOCIALACCOUNT_PROVIDERS     JSON object defining OIDC or
                                                OAuth providers (embeds secrets)

        This recipe never renders the Secret. Rendering one would put
        credentials into a manifest tree.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding SQLite database, search index, and classifier
        state. This is the core state and must persist across restarts.
      '';
    };

    mediaPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding scanned documents (uploaded PDFs and images).
        Must persist.
      '';
    };

    consumePath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory watched for new documents. Paperless polls this folder
        and auto-ingests any files found there. Often shared with Nextcloud
        or another upload interface.
      '';
    };

    exportPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory where Paperless writes exported documents. Must be
        writable and must persist.
      '';
    };

    ocrLanguage = lib.mkOption {
      type = lib.types.str;
      default = "deu+eng";
      description = ''
        Primary OCR language code for layout detection and tesseract training.
        Two-letter ISO 639-1 codes or combinations (e.g., "deu+eng").
      '';
    };

    ocrLanguages = lib.mkOption {
      type = lib.types.str;
      default = "deu eng lat";
      description = ''
        Space-separated list of additional OCR language codes. Tesseract
        downloads and caches these on first use.
      '';
    };

    consumePollingSeconds = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        How often to check the consume folder for new files (seconds).
        Set to 0 to rely on inotify, which may not work across different
        mount points.
      '';
    };

    filenameFormat = lib.mkOption {
      type = lib.types.str;
      default = "{{ created }}-{{ correspondent }}-{{ title }}";
      description = ''
        Format string for document filenames. Placeholders include
        {{ created }}, {{ correspondent }}, {{ title }}, etc.
      '';
    };

    emailFromAddress = lib.mkOption {
      type = lib.types.str;
      description = ''
        Email address used as sender for Paperless notifications.
        Required. If unset or left as a placeholder, email notifications will
        fail at runtime with "ValueError: invalid email address" or be rejected
        by the SMTP server.
      '';
    };

    emailHost = lib.mkOption {
      type = lib.types.str;
      description = "SMTP hostname (e.g., smtp.gmail.com).";
    };

    emailPort = lib.mkOption {
      type = lib.types.port;
      default = 465;
      description = "SMTP port (465 for SSL, 587 for TLS, 25 for plaintext).";
    };

    emailHostUser = lib.mkOption {
      type = lib.types.str;
      description = "SMTP username (often the full email address).";
    };

    emailUseSsl = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to wrap SMTP in SSL (port 465).";
    };

    emailUseTls = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to use STARTTLS (port 587). Set true only if emailUseSsl
        is false.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "documents";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. Paperless expects to be the single writer
          # to its SQLite database.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env = {
                  USERMAP_UID = { name = "USERMAP_UID"; value = "33"; };
                  USERMAP_GID = { name = "USERMAP_GID"; value = "33"; };
                  PAPERLESS_PORT = {
                    name = "PAPERLESS_PORT";
                    value = builtins.toString cfg.port;
                  };
                  PAPERLESS_OCR_LANGUAGE = {
                    name = "PAPERLESS_OCR_LANGUAGE";
                    value = cfg.ocrLanguage;
                  };
                  PAPERLESS_OCR_LANGUAGES = {
                    name = "PAPERLESS_OCR_LANGUAGES";
                    value = cfg.ocrLanguages;
                  };
                  PAPERLESS_FILENAME_FORMAT = {
                    name = "PAPERLESS_FILENAME_FORMAT";
                    value = cfg.filenameFormat;
                  };
                  PAPERLESS_CONSUMER_POLLING = {
                    name = "PAPERLESS_CONSUMER_POLLING";
                    value = builtins.toString cfg.consumePollingSeconds;
                  };
                  PAPERLESS_REDIS = {
                    name = "PAPERLESS_REDIS";
                    value = "redis://${redisName}.${cfg.namespace}.svc.cluster.local:6379";
                  };
                  PAPERLESS_EMAIL_FROM = {
                    name = "PAPERLESS_EMAIL_FROM";
                    value = cfg.emailFromAddress;
                  };
                  PAPERLESS_EMAIL_HOST = {
                    name = "PAPERLESS_EMAIL_HOST";
                    value = cfg.emailHost;
                  };
                  PAPERLESS_EMAIL_PORT = {
                    name = "PAPERLESS_EMAIL_PORT";
                    value = builtins.toString cfg.emailPort;
                  };
                  PAPERLESS_EMAIL_HOST_USER = {
                    name = "PAPERLESS_EMAIL_HOST_USER";
                    value = cfg.emailHostUser;
                  };
                  PAPERLESS_EMAIL_USE_SSL = {
                    name = "PAPERLESS_EMAIL_USE_SSL";
                    value = if cfg.emailUseSsl then "true" else "false";
                  };
                  PAPERLESS_EMAIL_USE_TLS = {
                    name = "PAPERLESS_EMAIL_USE_TLS";
                    value = if cfg.emailUseTls then "true" else "false";
                  };
                };
                envFrom = [{ secretRef.name = cfg.secretName; }];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts = {
                  data = {
                    name = "data";
                    mountPath = "/usr/src/paperless/data";
                  };
                  media = {
                    name = "media";
                    mountPath = "/usr/src/paperless/media";
                  };
                  consume = {
                    name = "consume";
                    mountPath = "/usr/src/paperless/consume";
                  };
                  export = {
                    name = "export";
                    mountPath = "/usr/src/paperless/export";
                  };
                };
                # Startup probe tolerates slow migrations on first boot.
                startupProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 20;
                  periodSeconds = 5;
                  failureThreshold = 72;  # ~6 minutes
                  timeoutSeconds = 5;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 20;
                  periodSeconds = 10;
                  failureThreshold = 6;
                  timeoutSeconds = 5;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 30;
                  failureThreshold = 6;
                  timeoutSeconds = 5;
                };
              };
              volumes = {
                data = {
                  name = "data";
                  hostPath = {
                    path = cfg.dataPath;
                    type = "Directory";
                  };
                };
                media = {
                  name = "media";
                  hostPath = {
                    path = cfg.mediaPath;
                    type = "Directory";
                  };
                };
                consume = {
                  name = "consume";
                  hostPath = {
                    path = cfg.consumePath;
                    type = "Directory";
                  };
                };
                export = {
                  name = "export";
                  hostPath = {
                    path = cfg.exportPath;
                    type = "Directory";
                  };
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
