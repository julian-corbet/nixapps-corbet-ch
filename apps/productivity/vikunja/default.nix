# nixapps.productivity.vikunja — Vikunja, a self-hosted to-do and task manager.
#
# What this recipe knows about Vikunja:
#
#   - It is a single static Go binary serving both API and frontend from one origin (:3456).
#   - It uses SQLite for the database, not an external database server. The database file
#     must be mounted at /etc/vikunja/vikunja.db and is single-writer: only one pod
#     must run at a time.
#   - Task attachments are stored at /app/vikunja/files.
#   - It requires a config file for OIDC provider setup, mounted from a Secret at
#     /app/vikunja/config.yml. Environment variables cannot express provider keys
#     containing underscores (e.g., pocket_id), so the provider configuration must
#     live in the YAML file.
#   - The readiness probe targets /api/v1/info, which is patient because the database
#     may take time to initialize.
#   - securityContext does not include fsGroup: recursively chowning the hostPath dataset
#     would break existing dataset ownership.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.productivity.vikunja;
  name = "vikunja";
in
{
  options.nixapps.productivity.vikunja = {
    enable = lib.mkEnableOption "Vikunja, a self-hosted to-do and task manager";

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
      default = "vikunja/vikunja:2.3.0";
      description = ''
        Container image, pinned by tag.

        Vikunja owns its SQLite schema. A floating tag can run a schema migration
        on a deploy nobody reviewed. Pin it, and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3456;
      description = "Port the application serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace. Must contain a key `config.yml`
        with the Vikunja configuration file. This file must declare the OIDC provider(s),
        including any keys with underscores (e.g., pocket_id), because environment
        variables split on underscores and cannot express such keys. The config file
        should include provider name, authurl (the issuer, not /authorize), clientId,
        and clientSecret.
      '';
    };

    filesPath = lib.mkOption {
      type = lib.types.str;
      description = "Host directory holding task attachments (mounted at /app/vikunja/files).";
    };

    dbPath = lib.mkOption {
      type = lib.types.str;
      description = "Host directory holding the SQLite database (mounted at /etc/vikunja).";
    };

    publicUrl = lib.mkOption {
      type = lib.types.str;
      description = ''
        Public https:// URL where Vikunja is accessible. This is used for CORS
        and feed generation. Set it to the URL where your reverse proxy exposes the app.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "productivity";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. SQLite is single-writer: two pods on the same
          # database file cause corruption.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              # securityContext does not include fsGroup. Recursively chowning the
              # hostPath dataset would break the existing dataset ownership model.
              securityContext = {
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
                env.VIKUNJA_SERVICE_PUBLICURL = {
                  name = "VIKUNJA_SERVICE_PUBLICURL";
                  value = cfg.publicUrl;
                };
                env.VIKUNJA_SERVICE_ROOTPATH = {
                  name = "VIKUNJA_SERVICE_ROOTPATH";
                  value = "/app/vikunja/";
                };
                env.VIKUNJA_SERVICE_ENABLEREGISTRATION = {
                  name = "VIKUNJA_SERVICE_ENABLEREGISTRATION";
                  value = "false";
                };
                env.VIKUNJA_SERVICE_ENABLEEMAILREMINDERS = {
                  name = "VIKUNJA_SERVICE_ENABLEEMAILREMINDERS";
                  value = "false";
                };
                env.VIKUNJA_SERVICE_ENABLEUSERDELETION = {
                  name = "VIKUNJA_SERVICE_ENABLEUSERDELETION";
                  value = "false";
                };
                env.VIKUNJA_DATABASE_TYPE = {
                  name = "VIKUNJA_DATABASE_TYPE";
                  value = "sqlite";
                };
                env.VIKUNJA_DATABASE_PATH = {
                  name = "VIKUNJA_DATABASE_PATH";
                  value = "/etc/vikunja/vikunja.db";
                };
                env.VIKUNJA_AUTH_LOCAL_ENABLED = {
                  name = "VIKUNJA_AUTH_LOCAL_ENABLED";
                  value = "false";
                };
                env.VIKUNJA_AUTH_OPENID_ENABLED = {
                  name = "VIKUNJA_AUTH_OPENID_ENABLED";
                  value = "true";
                };
                env.VIKUNJA_CORS_ENABLE = {
                  name = "VIKUNJA_CORS_ENABLE";
                  value = "true";
                };
                env.VIKUNJA_MAILER_ENABLED = {
                  name = "VIKUNJA_MAILER_ENABLED";
                  value = "false";
                };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.config = {
                  name = "config";
                  mountPath = "/app/vikunja/config.yml";
                  subPath = "config.yml";
                  readOnly = true;
                };
                volumeMounts.files = {
                  name = "files";
                  mountPath = "/app/vikunja/files";
                };
                volumeMounts.db = {
                  name = "db";
                  mountPath = "/etc/vikunja";
                };
                readinessProbe = {
                  httpGet = {
                    path = "/api/v1/info";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 24;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/api/v1/info";
                    port = cfg.port;
                  };
                  periodSeconds = 15;
                  failureThreshold = 6;
                };
              };
              volumes.config = {
                name = "config";
                secret.secretName = cfg.secretName;
              };
              volumes.files = {
                name = "files";
                hostPath = {
                  path = cfg.filesPath;
                  type = "Directory";
                };
              };
              volumes.db = {
                name = "db";
                hostPath = {
                  path = cfg.dbPath;
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
