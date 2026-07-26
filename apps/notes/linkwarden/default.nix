# nixapps.notes.linkwarden — linkwarden, a self-hosted bookmark manager.
#
# What this recipe knows about linkwarden:
#
#   - It is a web app backed by PostgreSQL. You must supply the database
#     connection URL and authentication details via a Secret.
#   - It runs schema migrations on startup (Prisma). If the database is not
#     responding, the entrypoint exits immediately, crash-looping the pod.
#     This recipe includes an initContainer to wait for the database before
#     the app starts.
#   - It writes user-uploaded files (archives, previews) to disk. The data
#     directory is the only persistence needed; the database holds schema
#     and metadata.
#   - It runs as a single pod. Recreate strategy to prevent concurrent writes
#     to the data directory.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.notes.linkwarden;
  name = "linkwarden";
in
{
  options.nixapps.notes.linkwarden = {
    enable = lib.mkEnableOption "linkwarden, a self-hosted bookmark manager";

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
      default = "ghcr.io/linkwarden/linkwarden:v2.15.1";
      description = ''
        Container image, pinned to the version matching your migrated schema.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port the app serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace loaded wholesale into the
        container's environment. linkwarden needs at least:

          DATABASE_URL      postgres connection string (postgresql://user:pass@host:5432/dbname)
          NEXTAUTH_SECRET   session encryption key
          NEXTAUTH_URL      public https:// URL for OAuth callbacks

        Additional variables (NEXTAUTH_GOOGLE_ID, AUTH0_ID, AUTH0_SECRET) are
        optional, for third-party authentication providers.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = "Host directory for user uploads and file storage.";
    };

    databaseHost = lib.mkOption {
      type = lib.types.str;
      description = ''
        Hostname or service name of the PostgreSQL server (e.g.,
        postgres.dbs.svc.cluster.local). The initContainer waits for TCP
        connections on this host port 5432 before the app starts.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "notes";

      resources = {
        deployments.${name}.spec = {
          # Single writer on the data directory.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              initContainers.wait-for-db = {
                name = "wait-for-db";
                image = "busybox:1.36";
                command = [
                  "sh" "-c"
                  "until nc -z ${cfg.databaseHost} 5432; do echo waiting-for-postgres; sleep 2; done"
                ];
              };
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
                  mountPath = "/data/data";
                };
                # Starts migrations immediately. Patient probe.
                readinessProbe = {
                  tcpSocket = {
                    port = cfg.port;
                  };
                  initialDelaySeconds = 20;
                  periodSeconds = 10;
                  failureThreshold = 12;
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
