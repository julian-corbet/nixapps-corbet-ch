# nixapps.office.eurooffice — EuroOffice DocumentServer, a WOPI office editor.
#
# What this recipe knows about EuroOffice:
#
#   - It is the IONOS/Nextcloud/Proton-backed fork of ONLYOFFICE Docs, used as
#     a WOPI server for document collaboration. It is stateless w.r.t. user files
#     (those live in the WOPI host and arrive over WOPI protocol).
#   - It persists two directories: a document cache (App_Data) and a WOPI identity
#     directory holding proof keys and secrets. Both must survive pod restarts;
#     without persistence, the entrypoint regenerates WOPI keys on every restart,
#     and WOPI hosts cache stale keys, causing all WOPI calls to fail with
#     "crypto/rsa: verification error" until they re-fetch the discovery document.
#   - It uses an external PostgreSQL database, not the bundled one. The entrypoint
#     expects DB_HOST≠localhost and skips the internal Postgres. This recipe does
#     not run a database; you must provide one.
#   - It runs its database schema on the first boot, detecting absence via the
#     to_regclass() SQL function. An initContainer handles schema creation
#     idempotently; the main entrypoint does not load it on its own.
#   - It runs as root (the ONLYOFFICE-derived image breaks under a forced
#     runAsUser securityContext). No uid override is applied.
#   - Readiness probes are patient (30s initial, 18 cycles of 10s = 180s total)
#     because the image boots slowly and database initialization takes time.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.office.eurooffice;
  name = "eurooffice";
in
{
  options.nixapps.office.eurooffice = {
    enable = lib.mkEnableOption "EuroOffice DocumentServer, a WOPI office editor";

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
      default = "ghcr.io/euro-office/documentserver:v9.3.2";
      description = ''
        Container image, pinned by tag. This image runs database migrations
        on boot, so a floating tag can update the schema without review.
        Pin it deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Port the EuroOffice HTTP server listens on inside the container.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded into the
        container's environment. EuroOffice requires:

          JWT_SECRET        signing key for browser/WOPI traffic
          DB_PWD            password for the PostgreSQL user

        The recipe sets DB_HOST, DB_PORT, DB_NAME, and DB_USER via environment.
        This recipe never renders the Secret; rendering credentials into a
        manifest tree would be unsafe.
      '';
    };

    dbHost = lib.mkOption {
      type = lib.types.str;
      description = ''
        Hostname or IP of the PostgreSQL server. The database name is hardcoded
        to `eurooffice` and the user is hardcoded to `eurooffice`; only the
        host and password vary per installation.
      '';
    };

    dbPort = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = "Port the PostgreSQL server listens on.";
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory for the document cache (App_Data). Written by uid 105
        at runtime; must be pre-created and owned uid:gid 105:107 with mode 2770.

        Large sequential I/O: worth placing on storage tuned for that profile
        rather than on container ephemeral overlay.
      '';
    };

    identityPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory for WOPI proof keys and .private secrets. Must survive
        pod restarts; if destroyed, the entrypoint regenerates keys, and WOPI
        hosts (which cache proof keys in memory) reject all calls until they
        refresh the discovery document.

        Pre-create this directory; the root entrypoint writes here (mode 755).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "office";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. The RWO host volumes are written by one pod
          # at a time; running two pods briefly would break consistency and leave
          # stale cache. WOPI also expects a single editor.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              # Runs as root (no securityContext). The ONLYOFFICE-derived image
              # manages uid transitions internally and breaks under forced
              # runAsUser constraints.

              initContainers."${name}-db-init" = {
                name = "db-schema-init";
                image = cfg.image;
                command = ["/bin/sh" "-c"];
                args = [''
                  set -eu
                  until PGPASSWORD="$DB_PWD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc 'select 1' >/dev/null 2>&1; do
                    echo "waiting for $DB_HOST:$DB_PORT..."
                    sleep 3
                  done
                  if [ -z "$(PGPASSWORD="$DB_PWD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "select to_regclass('public.doc_changes')")" ]; then
                    echo "schema absent -> loading createdb.sql"
                    PGPASSWORD="$DB_PWD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f /var/www/euro-office/documentserver/server/schema/postgresql/createdb.sql
                  else
                    echo "schema present -> skip"
                  fi
                ''];
                env = {
                  DB_HOST = { name = "DB_HOST"; value = cfg.dbHost; };
                  DB_PORT = { name = "DB_PORT"; value = toString cfg.dbPort; };
                  DB_NAME = { name = "DB_NAME"; value = "eurooffice"; };
                  DB_USER = { name = "DB_USER"; value = "eurooffice"; };
                };
                envFrom = [{ secretRef.name = cfg.secretName; }];
              };

              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env = {
                  JWT_ENABLED = { name = "JWT_ENABLED"; value = "true"; };
                  JWT_HEADER = { name = "JWT_HEADER"; value = "Authorization"; };
                  WOPI_ENABLED = { name = "WOPI_ENABLED"; value = "true"; };
                  ALLOW_PRIVATE_IP_ADDRESS = { name = "ALLOW_PRIVATE_IP_ADDRESS"; value = "true"; };
                  EXAMPLE_ENABLED = { name = "EXAMPLE_ENABLED"; value = "false"; };
                  DB_TYPE = { name = "DB_TYPE"; value = "postgres"; };
                  DB_HOST = { name = "DB_HOST"; value = cfg.dbHost; };
                  DB_PORT = { name = "DB_PORT"; value = toString cfg.dbPort; };
                  DB_NAME = { name = "DB_NAME"; value = "eurooffice"; };
                  DB_USER = { name = "DB_USER"; value = "eurooffice"; };
                };
                envFrom = [{ secretRef.name = cfg.secretName; }];

                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };

                readinessProbe = {
                  httpGet = {
                    path = "/healthcheck";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 30;
                  periodSeconds = 10;
                  failureThreshold = 18;
                };

                volumeMounts.data = {
                  name = "data";
                  mountPath = "/var/lib/euro-office/documentserver";
                };

                volumeMounts.identity = {
                  name = "identity";
                  mountPath = "/var/www/euro-office/Data";
                };
              };

              volumes.data = {
                name = "data";
                hostPath = {
                  path = cfg.dataPath;
                  type = "Directory";
                };
              };

              volumes.identity = {
                name = "identity";
                hostPath = {
                  path = cfg.identityPath;
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
