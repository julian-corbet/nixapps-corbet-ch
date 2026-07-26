# nixapps.data.directus — Directus, a headless data platform and CMS.
#
# What this recipe knows about Directus:
#
#   - It is a Node.js application serving HTTP on :8055. No separate web server.
#   - Its database is SQLite (not external). The database file and all persistent
#     data live on disk in three directories: database (the .db file), uploads
#     (asset files), and extensions (the extension registry).
#   - It runs schema migrations on startup. The startup and readiness probes are
#     patient because boots are slow: fresh installs migrate the schema, and
#     extension scans are heavy.
#   - It runs as runAsUser 3027 with no passwd entry. HOME must be writable; the
#     image uses pm2-runtime, which needs $HOME/.pm2. If HOME is root-owned and
#     unwritable, pm2 dies with EACCES and Directus never starts.
#   - The extension bundler needs a writable emptyDir at /directus/node_modules/.directus.
#     The image path is read-only, so the bundler can't mkdir it; a writable volume
#     is the workaround.
#   - Only one replica allowed. SQLite is single-writer; two pods on the same
#     database corrupt it instantly.
#   - Probe at /server/ping (returns 200 to anonymous requests). The /server/health
#     endpoint requires authentication and cannot be used as a kubelet probe.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.data.directus;
  name = "directus";
in
{
  options.nixapps.data.directus = {
    enable = lib.mkEnableOption "Directus, a headless data platform and CMS";

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
      default = "directus/directus:12.1.1@sha256:27fd291463f4e746a7911139377a1dbc7a5c09ae82ee15b028b97bcc4950c69d";
      description = ''
        Container image, pinned by digest rather than a tag.

        Directus migrates the database it reads on startup. A floating tag can
        therefore run a schema migration nobody reviewed, and afterwards there
        is no diff to look at. Pin it, and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8055;
      description = "Port the in-image Node.js application serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Directus needs at least:

          KEY                             a random 32-char string for signing
          SECRET                          a random 32-char string for encryption
          ADMIN_PASSWORD                  password for the initial admin user
          AUTH_POCKET_ID_CLIENT_SECRET    OAuth client secret (if using pocket-id
                                          OpenID provider)

        Also add site-specific variables to this secret:

          PUBLIC_URL                      public https:// URL of the instance;
                                          asset URLs and redirects are built
                                          from it, so getting it wrong breaks
                                          the application
          ADMIN_EMAIL                     email of the initial admin user
          TZ                              timezone (e.g. Europe/Zurich)
          AUTH_DISABLE_DEFAULT            set to "true" to disable built-in auth
          AUTH_PROVIDERS                  comma-separated auth provider names
          AUTH_POCKET_ID_*                OpenID configuration if using pocket-id:
                                          ISSUER_URL, CLIENT_ID, SCOPE, LABEL,
                                          ICON, DRIVER, IDENTIFIER_KEY, MODE,
                                          REQUIRE_VERIFIED_EMAIL, SYNC_USER_INFO,
                                          ALLOW_PUBLIC_REGISTRATION, etc.; see
                                          the Directus docs for the full set

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };

    databasePath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the Directus SQLite database file.

        This is the critical data. Store it on persistent, reliable storage
        tuned for database access patterns.
      '';
    };

    uploadsPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding uploaded asset files (images, documents, etc.).

        Sequential write workload; worth putting on storage tuned for that.
      '';
    };

    extensionsPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the extension registry.

        Directus scans and builds registered extensions into node_modules at boot.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "data";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. SQLite is single-writer; a rolling update briefly
          # runs the old and new pod together, both holding the database open, and
          # concurrent writes corrupt it instantly.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              securityContext = {
                runAsUser = 3027;
                runAsGroup = 3027;
                runAsNonRoot = true;
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                envFrom = [{ secretRef.name = cfg.secretName; }];
                # Infrastructure env vars: hardcoded to match the image design.
                env = [
                  { name = "NODE_ENV"; value = "production"; }
                  { name = "NPM_CONFIG_UPDATE_NOTIFIER"; value = "false"; }
                  { name = "DB_CLIENT"; value = "sqlite3"; }
                  { name = "DB_FILENAME"; value = "/directus/database/crm.db"; }
                  # HOME must be writable for pm2-runtime (writes $HOME/.pm2).
                  # The image's default HOME is root-owned and unwritable when
                  # running as uid 3027, causing pm2 to crash at EACCES before
                  # Directus ever starts.
                  { name = "HOME"; value = "/home/directus"; }
                  { name = "PM2_HOME"; value = "/home/directus/.pm2"; }
                ];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                # Directus boots slowly: schema migrations, extension scan, etc.
                # Startup probe is longest (300s), readiness shorter, liveness
                # the shortest. All probe /server/ping (anonymous, returns 200).
                # The /server/health endpoint requires authentication and cannot
                # be used as a kubelet probe.
                startupProbe = {
                  httpGet = {
                    path = "/server/ping";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 60;
                  timeoutSeconds = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/server/ping";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 36;
                  timeoutSeconds = 3;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/server/ping";
                    port = cfg.port;
                  };
                  periodSeconds = 15;
                  failureThreshold = 6;
                  timeoutSeconds = 3;
                };
                volumeMounts = {
                  database = {
                    name = "database";
                    mountPath = "/directus/database";
                  };
                  uploads = {
                    name = "uploads";
                    mountPath = "/directus/uploads";
                  };
                  extensions = {
                    name = "extensions";
                    mountPath = "/directus/extensions";
                  };
                  pm2home = {
                    name = "pm2home";
                    mountPath = "/home/directus";
                  };
                  extbuild = {
                    name = "extbuild";
                    mountPath = "/directus/node_modules/.directus";
                  };
                };
              };
              volumes = {
                database = {
                  name = "database";
                  hostPath = {
                    path = cfg.databasePath;
                    type = "Directory";
                  };
                };
                uploads = {
                  name = "uploads";
                  hostPath = {
                    path = cfg.uploadsPath;
                    type = "Directory";
                  };
                };
                extensions = {
                  name = "extensions";
                  hostPath = {
                    path = cfg.extensionsPath;
                    type = "Directory";
                  };
                };
                pm2home = {
                  name = "pm2home";
                  emptyDir = {};
                };
                extbuild = {
                  name = "extbuild";
                  emptyDir = {};
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
