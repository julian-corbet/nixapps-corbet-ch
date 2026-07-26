# nixapps.documents.papra — Papra document management system.
#
# What this recipe knows about Papra:
#
#   - It is a modern DMS with an embedded SQLite database and in-process OCR.
#     Single pod only; replicas = 1 and strategy = Recreate because SQLite
#     cannot have concurrent writers.
#   - The rootless image runs as uid 3038 (or whatever securityContext specifies).
#     It does NOT use fsGroup chown, which would break multi-door ownership on
#     the host dataset. If your data dir is shared with other services, omit
#     fsGroup; if Papra owns it alone, fsGroup matching the container user is OK.
#   - Documents are stored with human-readable filenames on disk, not opaque
#     documentId keys. This trades some flexibility for debuggability: files can
#     be grepped, backed up by name, and viewed outside Papra.
#   - An ingestion folder watches for new documents dropped via SMB or NFS.
#     Files are moved (not copied) into the app's storage after processing.
#   - Authentication is SSO-only via OIDC; email login is disabled. The first
#     user to log in via OIDC becomes admin.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.documents.papra;
  name = "papra";
in
{
  options.nixapps.documents.papra = {
    enable = lib.mkEnableOption "Papra, a document management system";

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
      default = "ghcr.io/papra-hq/papra:26.5.0-rootless";
      description = ''
        Container image. The -rootless variant runs without privilege escalation.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1221;
      description = "Port the web application serves HTTP on.";
    };

    runAsUser = lib.mkOption {
      type = lib.types.int;
      default = 3038;
      description = ''
        UID to run the container as. Should match the owner of the host
        directories to avoid chown complications. The default (3038) is the
        per-app uid reserved for Papra.
      '';
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Papra needs at least:

          AUTH_SECRET              A random string for cookie signing
          AUTH_PROVIDERS_CUSTOMS   JSON object defining OIDC provider(s),
                                   including client ID and secret

        This recipe never renders the Secret. Rendering one would put
        credentials into a manifest tree.
      '';
    };

    appdataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the SQLite database, search index, and other
        opaque app state. Must persist across restarts.
      '';
    };

    cloudsPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding documents and the ingestion watch folder.
        Documents are stored with human-readable names for backup, grep, and
        direct file-level access. The ingestion/ subfolder is watched for new
        files to be processed and moved into the documents/ tree.
      '';
    };

    documentStorageKeyPattern = lib.mkOption {
      type = lib.types.str;
      default = "{{organization.id}}/{{document.name}}";
      description = ''
        Pattern for the document storage key (filesystem path). Placeholders
        include {{organization.id}}, {{document.name}}, and others. The
        default uses organization-level directories with document names.
      '';
    };

    ingestionPostProcessingStrategy = lib.mkOption {
      type = lib.types.enum [ "move" "copy" "delete" ];
      default = "move";
      description = ''
        What to do with ingested files. "move" is the default and most common:
        files are read from the ingestion folder and moved into storage.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "documents";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. SQLite cannot have two writers.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              securityContext = {
                runAsUser = cfg.runAsUser;
                runAsGroup = cfg.runAsUser;  # use same group as user
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
                # fsGroup deliberately omitted to preserve multi-door ownership.
                # If Papra owns the host dirs alone, you may add
                # fsGroup = cfg.runAsUser; but that requires the dirs to be
                # Papra-only.
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env = {
                  PORT = { name = "PORT"; value = builtins.toString cfg.port; };
                  APP_BASE_URL = {
                    name = "APP_BASE_URL";
                    value = "https://papra.example.com";  # override via env
                  };
                  TRUSTED_ORIGINS = {
                    name = "TRUSTED_ORIGINS";
                    value = "https://papra.example.com";  # override via env
                  };
                  DATABASE_URL = {
                    name = "DATABASE_URL";
                    value = "file:/app/app-data/db/db.sqlite";
                  };
                  DOCUMENT_STORAGE_DRIVER = {
                    name = "DOCUMENT_STORAGE_DRIVER";
                    value = "filesystem";
                  };
                  DOCUMENT_STORAGE_FILESYSTEM_ROOT = {
                    name = "DOCUMENT_STORAGE_FILESYSTEM_ROOT";
                    value = "/app/clouds/documents";
                  };
                  DOCUMENT_STORAGE_USE_LEGACY_STORAGE_KEY_DEFINITION_SYSTEM = {
                    name = "DOCUMENT_STORAGE_USE_LEGACY_STORAGE_KEY_DEFINITION_SYSTEM";
                    value = "false";  # use human-readable filenames
                  };
                  DOCUMENT_STORAGE_KEY_PATTERN = {
                    name = "DOCUMENT_STORAGE_KEY_PATTERN";
                    value = cfg.documentStorageKeyPattern;
                  };
                  INGESTION_FOLDER_IS_ENABLED = {
                    name = "INGESTION_FOLDER_IS_ENABLED";
                    value = "true";
                  };
                  INGESTION_FOLDER_ROOT_PATH = {
                    name = "INGESTION_FOLDER_ROOT_PATH";
                    value = "/app/clouds/ingestion";
                  };
                  INGESTION_FOLDER_POST_PROCESSING_STRATEGY = {
                    name = "INGESTION_FOLDER_POST_PROCESSING_STRATEGY";
                    value = cfg.ingestionPostProcessingStrategy;
                  };
                  AUTH_PROVIDERS_EMAIL_IS_ENABLED = {
                    name = "AUTH_PROVIDERS_EMAIL_IS_ENABLED";
                    value = "false";  # SSO-only
                  };
                  AUTH_IS_REGISTRATION_ENABLED = {
                    name = "AUTH_IS_REGISTRATION_ENABLED";
                    value = "false";  # OIDC signup only
                  };
                  AUTH_FIRST_USER_AS_ADMIN = {
                    name = "AUTH_FIRST_USER_AS_ADMIN";
                    value = "true";
                  };
                };
                envFrom = [{ secretRef.name = cfg.secretName; }];
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = [ "ALL" ];
                };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts = {
                  appdata = {
                    name = "appdata";
                    mountPath = "/app/app-data";
                  };
                  clouds = {
                    name = "clouds";
                    mountPath = "/app/clouds";
                  };
                };
                readinessProbe = {
                  tcpSocket.port = cfg.port;
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  failureThreshold = 18;
                };
                livenessProbe = {
                  tcpSocket.port = cfg.port;
                  initialDelaySeconds = 30;
                  periodSeconds = 30;
                  failureThreshold = 6;
                };
              };
              volumes = {
                appdata = {
                  name = "appdata";
                  hostPath = {
                    path = cfg.appdataPath;
                    type = "Directory";
                  };
                };
                clouds = {
                  name = "clouds";
                  hostPath = {
                    path = cfg.cloudsPath;
                    type = "Directory";
                  };
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
