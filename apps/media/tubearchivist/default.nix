# nixapps.media.tubearchivist — TubeArchivist, a self-hosted YouTube archiver.
#
# What this recipe knows about TubeArchivist:
#
#   - It is a three-container stack: the Django app (serves HTTP on :8000),
#     an Elasticsearch instance (port 9200 + transport 9300), and Redis (port 6379).
#     Each reaches the others via in-cluster DNS.
#   - The app runs as root (django installs in /root/.local; no PUID support).
#     Elasticsearch and Redis are standard images with no special requirements.
#   - State lives in three directories: the video archive, thumbnails/cache,
#     and the Elasticsearch index. All must be provided. None are optional.
#   - Recreate strategy on all three deployments: each is single-writer over
#     its on-disk state. A rolling update would break everything.
#   - Elasticsearch requires vm.max_map_count >= 262144 on the node where it
#     runs, or it will refuse to start. Verify before deploy.
#   - The Elasticsearch index may be large (gigabytes). Pre-migration to the
#     host path before bringing the app online; Elasticsearch will not
#     initialize a fresh index if it finds an existing one — migrating after
#     deploy loses your metadata.
#   - Secrets are required: ELASTIC_PASSWORD (Elasticsearch auth, shared with
#     the app) and TA_PASSWORD (the admin user password). Create them out-of-band.
#   - The secrets are referenced by key name, not loaded wholesale. Both must
#     exist in the Secret.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.media.tubearchivist;
  appName = "tubearchivist";
  esName = "tubearchivist-es";
  redisName = "tubearchivist-redis";
in
{
  options.nixapps.media.tubearchivist = {
    enable = lib.mkEnableOption "TubeArchivist, a self-hosted YouTube archiver";

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
      default = "bbilly1/tubearchivist:v0.5.10";
      description = ''
        Container image for the TubeArchivist Django app, pinned by tag.

        TubeArchivist is actively developed. Pin this to a known-good version
        and test upgrades first; the app will migrate metadata if the version
        changes.
      '';
    };

    elasticsearchImage = lib.mkOption {
      type = lib.types.str;
      default = "bbilly1/tubearchivist-es:8.19.0@sha256:9da63fb1973ec3d57daf6916be948eddd0d8a404cc8e447c938480c85fe2c554";
      description = "Container image for Elasticsearch. Should match the app version.";
    };

    redisImage = lib.mkOption {
      type = lib.types.str;
      default = "redis:alpine@sha256:8096655e437712b07503796fb64d81359256cfcff0ab29d95a7da72863786efb";
      description = "Container image for Redis. Alpine is sufficient; it is cache and queue only.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "Port the Django app serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace holding the passwords.
        TubeArchivist requires at least:

          ELASTIC_PASSWORD   Password for Elasticsearch (shared with the app
                             for internal authentication). Set to the same
                             value on both Elasticsearch and the app.
          TA_PASSWORD        Password for the admin user (TA_USERNAME is always
                             "admin"). Used to log into the web UI.

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };

    mediaPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the downloaded videos from YouTube.

        This is the main archive. The app writes videos here sequentially;
        consider a large, sequentially-optimized filesystem (e.g. appended to
        an SMR or sequential-write-optimized store).
      '';
    };

    cachePath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding video thumbnails and the working cache.

        The app generates thumbnails and metadata here. Must be read/write.
        Usually much smaller than mediaPath.
      '';
    };

    elasticsearchDataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the Elasticsearch index (typically several GB).

        Elasticsearch stores the searchable metadata index here. Do NOT let
        Elasticsearch initialize a fresh index if you have an existing one —
        migrate the existing index into this path BEFORE bringing the app online,
        or you will lose all metadata.
      '';
    };

    redisDataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the Redis dump.rdb snapshot.

        Redis is cache and task queue only. If this directory is empty, Redis
        starts fresh and is rebuilt on use. If you have an existing dump.rdb,
        migrate it here to preserve the queue state across deployments.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${appName} = {
      inherit (cfg) namespace createNamespace;
      project = "media";

      resources = {
        # ── Redis ─────────────────────────────────────────────────────────
        deployments.${redisName}.spec = {
          strategy.type = "Recreate";
          selector.matchLabels.app = redisName;
          template = {
            metadata.labels.app = redisName;
            spec = {
              containers.${redisName} = {
                name = redisName;
                image = cfg.redisImage;
                ports.redis = {
                  name = "redis";
                  containerPort = 6379;
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/data";
                };
              };
              volumes.data = {
                name = "data";
                hostPath = {
                  path = cfg.redisDataPath;
                  type = "Directory";
                };
              };
            };
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

        # ── Elasticsearch ─────────────────────────────────────────────────
        deployments.${esName}.spec = {
          strategy.type = "Recreate";
          selector.matchLabels.app = esName;
          template = {
            metadata.labels.app = esName;
            spec = {
              containers.${esName} = {
                name = esName;
                image = cfg.elasticsearchImage;
                env.discovery_type = {
                  name = "discovery.type";
                  value = "single-node";
                };
                env.xpack_security_enabled = {
                  name = "xpack.security.enabled";
                  value = "true";
                };
                env.ES_JAVA_OPTS = {
                  name = "ES_JAVA_OPTS";
                  value = "-Xms512m -Xmx512m";
                };
                env.path_repo = {
                  name = "path.repo";
                  value = "/usr/share/elasticsearch/data/snapshot";
                };
                env.ELASTIC_PASSWORD = {
                  name = "ELASTIC_PASSWORD";
                  valueFrom.secretKeyRef = {
                    name = cfg.secretName;
                    key = "ELASTIC_PASSWORD";
                  };
                };
                ports.http = {
                  name = "http";
                  containerPort = 9200;
                };
                ports.transport = {
                  name = "transport";
                  containerPort = 9300;
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/usr/share/elasticsearch/data";
                };
              };
              volumes.data = {
                name = "data";
                hostPath = {
                  path = cfg.elasticsearchDataPath;
                  type = "Directory";
                };
              };
            };
          };
        };

        services.${esName}.spec = {
          type = "ClusterIP";
          selector.app = esName;
          ports.http = {
            name = "http";
            port = 9200;
            targetPort = 9200;
          };
          ports.transport = {
            name = "transport";
            port = 9300;
            targetPort = 9300;
          };
        };

        # ── TubeArchivist App ─────────────────────────────────────────────
        deployments.${appName}.spec = {
          # Recreate, not rolling. TubeArchivist is single-writer over the
          # cache and media directories. A rolling update would corrupt state.
          strategy.type = "Recreate";
          selector.matchLabels.app = appName;
          template = {
            metadata.labels.app = appName;
            spec = {
              containers.${appName} = {
                name = appName;
                image = cfg.image;
                env.TA_USERNAME = {
                  name = "TA_USERNAME";
                  value = "admin";
                };
                env.TA_HOST = {
                  name = "TA_HOST";
                  value = "http://${appName}:${builtins.toString cfg.port}";
                };
                env.ES_URL = {
                  name = "ES_URL";
                  value = "http://${esName}:9200";
                };
                env.REDIS_CON = {
                  name = "REDIS_CON";
                  value = "redis://${redisName}:6379";
                };
                env.ELASTIC_PASSWORD = {
                  name = "ELASTIC_PASSWORD";
                  valueFrom.secretKeyRef = {
                    name = cfg.secretName;
                    key = "ELASTIC_PASSWORD";
                  };
                };
                env.TA_PASSWORD = {
                  name = "TA_PASSWORD";
                  valueFrom.secretKeyRef = {
                    name = cfg.secretName;
                    key = "TA_PASSWORD";
                  };
                };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.media = {
                  name = "media";
                  mountPath = "/youtube";
                };
                volumeMounts.cache = {
                  name = "cache";
                  mountPath = "/cache";
                };
                # Allow the app time to initialize and index. Checks every 10
                # seconds with 3 minutes of patience.
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 20;
                  periodSeconds = 10;
                  failureThreshold = 18;
                };
              };
              volumes.media = {
                name = "media";
                hostPath = {
                  path = cfg.mediaPath;
                  type = "Directory";
                };
              };
              volumes.cache = {
                name = "cache";
                hostPath = {
                  path = cfg.cachePath;
                  type = "Directory";
                };
              };
            };
          };
        };

        services.${appName}.spec = {
          type = "ClusterIP";
          selector.app = appName;
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
