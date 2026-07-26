# nixapps.files.nextcloud — Nextcloud, a self-hosted file sync and collaborative platform.
#
# What this recipe knows about Nextcloud:
#
#   - It is a three-container pod: php-fpm (the app), nginx (the web front), and
#     notify_push (realtime WebSocket service). All three share a read-write
#     volume mounted at /var/www/html. Only nginx exposes :8080 to the outside;
#     php-fpm runs on :9000 (fastcgi) and notify_push runs on :7867 (for
#     proximity to nginx).
#   - Two persistent host paths: /var/www/html (the code and config) and a data
#     directory (user files, appdata). The code volume is expected to be
#     pre-populated (e.g., from a prior AIO docker installation); Nextcloud
#     itself does not install its code on first boot.
#   - It requires an external PostgreSQL database and a Redis instance for
#     caching and locking. This recipe deploys a sibling Redis; the database
#     must already exist and be referenced in the secrets.
#   - The php-fpm container runs as uid 33 (www-data); both volumes must be
#     owned 33:33. fsGroup is omitted because hostPath mounts would rechown them.
#   - It runs with Recreate strategy: two pods holding the same hostPath would
#     corrupt the shared data directory and the database. The pod will not roll
#     to a new version until the old one exits completely.
#   - It pins the image by tag (e.g. 33.0.5-fpm) rather than a floating tag,
#     because it reads the existing config files on startup, and upgrading the
#     app code + database schema requires the old pod to exit. A floating tag
#     can upgrade mid-lifecycle, orphaning running users.
#   - The instanceid, secret, and passwordsalt crypto identity keys are carried
#     in the sealed secret overlay (config/zzz-secrets.config.php). An
#     initContainer asserts they are present before the app starts; losing them
#     breaks SSO, app passwords, and server-side encryption.
#   - Redis is internal-only, password-less, and memory-bounded to prevent
#     excessive OOM. Imaginary (preview generator) is also internal-only, with
#     no URL-based image fetching (SSRF hardened). Background jobs run in a
#     CronJob every 5 minutes; after cutover, set `occ background:cron` in
#     config.php to enable the task queue and disable the legacy cron behavior.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.files.nextcloud;
  name = "nextcloud";
in
{
  options.nixapps.files.nextcloud = {
    enable = lib.mkEnableOption "Nextcloud, a self-hosted file sync and collaboration platform";

    namespace = lib.mkOption {
      type = lib.types.str;
      description = "Namespace to deploy into. Shared with other cloud apps (e.g. opencloud).";
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
      default = "nextcloud:33.0.5-fpm";
      description = ''
        Container image, pinned by tag. Use a specific tag (e.g., 33.0.5-fpm)
        and never "latest". Nextcloud reads the existing schema on startup; a
        floating tag can upgrade the code without coordinating with the database,
        breaking the deployment.
      '';
    };

    nginxImage = lib.mkOption {
      type = lib.types.str;
      default = "nginxinc/nginx-unprivileged:1.31.3-alpine@sha256:18d67281256ded39ff65e010ae4f831be18f19356f83c60bc546492c7eb6dd23";
      description = "Nginx image for the reverse proxy / fastcgi handler.";
    };

    redisImage = lib.mkOption {
      type = lib.types.str;
      default = "redis:7-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2";
      description = "Redis image for cache and distributed locking.";
    };

    imaginaryImage = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/nextcloud-releases/aio-imaginary@sha256:ef9832c16d4253a33ed9af0bf61ce148bca6635da8f34cdbaf92a713373edffd";
      description = ''
        Imaginary image for internal preview generation. No URL-based fetching
        (SSRF hardened); Nextcloud POSTs file bytes to it.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the nginx container serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        containers' environment. Nextcloud requires at least:

          POSTGRES_PASSWORD       password for the database role
          zzz-secrets.config.php  (as a key, containing the crypto identity
                                   overlay). Must include: instanceid, secret,
                                   passwordsalt. Losing these breaks SSO, app
                                   passwords, and server-side encryption.

        A sealed secret overlay (zzz-secrets.config.php) is mandatory. The
        initContainer asserts it is present before the pod starts.
      '';
    };

    htmlPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory for /var/www/html (PHP code, config/, custom_apps/,
        version.php). Expected to be pre-populated from a prior installation.
        Must be owned 33:33 (www-data).
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory for /mnt/ncdata (user files, appdata_<instanceid>/,
        .ncdata). Must be owned 33:33 (www-data).
      '';
    };

    cronSchedule = lib.mkOption {
      type = lib.types.str;
      default = "*/5 * * * *";
      description = ''
        Cron schedule for background jobs (CronJob). Default is every 5 minutes.
        After cutover, set `occ background:cron` in config.php to enable the
        task queue and disable the legacy timer-based cron.
      '';
    };

    databaseHost = lib.mkOption {
      type = lib.types.str;
      description = ''
        PostgreSQL host (FQDN or service name). E.g., pg18-rw.dbs.svc.cluster.local.
      '';
    };

    databasePort = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = "PostgreSQL port.";
    };

    databaseName = lib.mkOption {
      type = lib.types.str;
      default = "nextcloud";
      description = "PostgreSQL database name.";
    };

    databaseUser = lib.mkOption {
      type = lib.types.str;
      default = "oc_nextcloud";
      description = "PostgreSQL role name (oc_* prefix preserved).";
    };

    redisHost = lib.mkOption {
      type = lib.types.str;
      default = "nextcloud-redis.${cfg.namespace}.svc.cluster.local";
      description = ''
        Redis host for distributed cache and locking. Defaults to the sibling
        redis Deployment (nextcloud-redis.<namespace>.svc.cluster.local).
        Overridable if using an external Redis instance.
      '';
    };

    redisPort = lib.mkOption {
      type = lib.types.port;
      default = 6379;
      description = "Redis port (password-less, internal-only).";
    };

    imaginaryUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://nextcloud-imaginary.${cfg.namespace}.svc.cluster.local:9000";
      description = ''
        URL for the imaginary preview service (internal cluster DNS). Defaults to
        the sibling imaginary Deployment (http://nextcloud-imaginary.<namespace>.svc.cluster.local:9000).
        Overridable if using an external preview service.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "files";

      resources = {
        # ── php-fpm + nginx + notify_push (three containers, one pod) ──
        deployments.${name}.spec = {
          strategy.type = "Recreate";  # single-writer hostPath + shared DB
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              securityContext = {
                runAsUser = 33;    # www-data
                runAsGroup = 33;
                # fsGroup omitted: hostPath mounts would rechown the directories
              };
              initContainers.assert-secrets = {
                name = "assert-secrets";
                image = cfg.image;
                command = [ "sh" "-c" ];
                args = [
                  ''
                    f=/var/www/html/config/zzz-secrets.config.php
                    for k in instanceid secret passwordsalt; do
                      grep -Eq "'$k'\s*=>\s*'[^<>'][^']*'" "$f" || { echo "FATAL: $k missing/placeholder in $f — refusing to start (would regenerate crypto identity)"; exit 1; }
                    done
                    echo "crypto identity overlay present (instanceid/secret/passwordsalt) — ok"
                  ''
                ];
                volumeMounts.secrets = {
                  name = "cfg-secret";
                  mountPath = "/var/www/html/config/zzz-secrets.config.php";
                  subPath = "zzz-secrets.config.php";
                  readOnly = true;
                };
              };
              containers.nextcloud = {
                name = "nextcloud";
                image = cfg.image;
                env = {
                  NEXTCLOUD_DATA_DIR.value = "/mnt/ncdata";
                  PHP_MEMORY_LIMIT.value = "1024M";
                  PHP_UPLOAD_LIMIT.value = "16G";
                  POSTGRES_HOST.value = cfg.databaseHost;
                  POSTGRES_DB.value = cfg.databaseName;
                  POSTGRES_USER.value = cfg.databaseUser;
                  POSTGRES_PASSWORD = {
                    name = "POSTGRES_PASSWORD";
                    valueFrom.secretKeyRef = {
                      name = cfg.secretName;
                      key = "POSTGRES_PASSWORD";
                    };
                  };
                };
                ports.fpm = {
                  name = "fpm";
                  containerPort = 9000;
                };
                volumeMounts = {
                  html = {
                    name = "html";
                    mountPath = "/var/www/html";
                  };
                  data = {
                    name = "data";
                    mountPath = "/mnt/ncdata";
                  };
                  cfg-k8s = {
                    name = "cfg-k8s";
                    mountPath = "/var/www/html/config/zz-k8s.config.php";
                    subPath = "zz-k8s.config.php";
                    readOnly = true;
                  };
                  cfg-secret = {
                    name = "cfg-secret";
                    mountPath = "/var/www/html/config/zzz-secrets.config.php";
                    subPath = "zzz-secrets.config.php";
                    readOnly = true;
                  };
                };
              };
              containers.nginx = {
                name = "nginx";
                image = cfg.nginxImage;
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts = {
                  html = {
                    name = "html";
                    mountPath = "/var/www/html";
                    readOnly = true;
                  };
                  nginx-conf = {
                    name = "nginx-conf";
                    mountPath = "/etc/nginx/nginx.conf";
                    subPath = "nginx.conf";
                    readOnly = true;
                  };
                };
                readinessProbe = {
                  httpGet = {
                    path = "/status.php";
                    port = cfg.port;
                  };
                  periodSeconds = 10;
                  failureThreshold = 6;
                };
              };
              containers.notify-push = {
                name = "notify-push";
                image = cfg.image;
                command = [
                  "sh" "-c"
                  "until [ -f /var/www/html/custom_apps/notify_push/bin/x86_64/notify_push ]; do sleep 3; done; exec /var/www/html/custom_apps/notify_push/bin/x86_64/notify_push /var/www/html/config/config.php"
                ];
                env = {
                  PORT.value = "7867";
                  NEXTCLOUD_URL.value = "http://localhost:${toString cfg.port}";
                  ALLOW_SELF_SIGNED.value = "true";
                };
                volumeMounts = {
                  html = {
                    name = "html";
                    mountPath = "/var/www/html";
                  };
                  cfg-k8s = {
                    name = "cfg-k8s";
                    mountPath = "/var/www/html/config/zz-k8s.config.php";
                    subPath = "zz-k8s.config.php";
                    readOnly = true;
                  };
                  cfg-secret = {
                    name = "cfg-secret";
                    mountPath = "/var/www/html/config/zzz-secrets.config.php";
                    subPath = "zzz-secrets.config.php";
                    readOnly = true;
                  };
                };
              };
              volumes = {
                html = {
                  name = "html";
                  hostPath = {
                    path = cfg.htmlPath;
                    type = "Directory";
                  };
                };
                data = {
                  name = "data";
                  hostPath = {
                    path = cfg.dataPath;
                    type = "Directory";
                  };
                };
                nginx-conf = {
                  name = "nginx-conf";
                  configMap.name = "nextcloud-nginx";
                };
                cfg-k8s = {
                  name = "cfg-k8s";
                  configMap.name = "nextcloud-config";
                };
                cfg-secret = {
                  name = "cfg-secret";
                  secret = {
                    secretName = cfg.secretName;
                    items = [
                      {
                        key = "zzz-secrets.config.php";
                        path = "zzz-secrets.config.php";
                      }
                    ];
                  };
                };
              };
            };
          };
        };

        # ── Redis (cache and distributed locking) ──
        deployments.nextcloud-redis.spec = {
          selector.matchLabels.app = "nextcloud-redis";
          template = {
            metadata.labels.app = "nextcloud-redis";
            spec = {
              containers.redis = {
                name = "redis";
                image = cfg.redisImage;
                args = [
                  "--maxmemory" "400mb"
                  "--maxmemory-policy" "allkeys-lru"
                ];
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

        # ── Imaginary (preview generator, internal-only) ──
        deployments.nextcloud-imaginary.spec = {
          selector.matchLabels.app = "nextcloud-imaginary";
          template = {
            metadata.labels.app = "nextcloud-imaginary";
            spec = {
              containers.imaginary = {
                name = "imaginary";
                image = cfg.imaginaryImage;
                args = [ "-p" "9000" "-concurrency" "50" ];
                ports.http = {
                  name = "http";
                  containerPort = 9000;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/health";
                    port = 9000;
                  };
                  periodSeconds = 10;
                };
              };
            };
          };
        };

        # ── Background jobs (CronJob, runs php cron.php every 5m) ──
        cronJobs.nextcloud-cron.spec = {
          schedule = cfg.cronSchedule;
          concurrencyPolicy = "Forbid";
          successfulJobsHistoryLimit = 1;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            activeDeadlineSeconds = 290;
            template.spec = {
              restartPolicy = "Never";
              securityContext = {
                runAsUser = 33;
                runAsGroup = 33;
              };
              containers.cron = {
                name = "cron";
                image = cfg.image;
                command = [ "php" "-f" "/var/www/html/cron.php" ];
                volumeMounts = {
                  html = {
                    name = "html";
                    mountPath = "/var/www/html";
                  };
                  data = {
                    name = "data";
                    mountPath = "/mnt/ncdata";
                  };
                  cfg-k8s = {
                    name = "cfg-k8s";
                    mountPath = "/var/www/html/config/zz-k8s.config.php";
                    subPath = "zz-k8s.config.php";
                    readOnly = true;
                  };
                  cfg-secret = {
                    name = "cfg-secret";
                    mountPath = "/var/www/html/config/zzz-secrets.config.php";
                    subPath = "zzz-secrets.config.php";
                    readOnly = true;
                  };
                };
              };
              volumes = {
                html = {
                  name = "html";
                  hostPath = {
                    path = cfg.htmlPath;
                    type = "Directory";
                  };
                };
                data = {
                  name = "data";
                  hostPath = {
                    path = cfg.dataPath;
                    type = "Directory";
                  };
                };
                cfg-k8s = {
                  name = "cfg-k8s";
                  configMap.name = "nextcloud-config";
                };
                cfg-secret = {
                  name = "cfg-secret";
                  secret = {
                    secretName = cfg.secretName;
                    items = [
                      {
                        key = "zzz-secrets.config.php";
                        path = "zzz-secrets.config.php";
                      }
                    ];
                  };
                };
              };
            };
          };
        };

        # ── Services ──
        services.${name}.spec = {
          type = "ClusterIP";
          selector.app = name;
          ports.http = {
            name = "http";
            port = 80;
            targetPort = cfg.port;
          };
        };

        services.nextcloud-redis.spec = {
          type = "ClusterIP";
          selector.app = "nextcloud-redis";
          ports.redis = {
            name = "redis";
            port = 6379;
            targetPort = 6379;
          };
        };

        services.nextcloud-imaginary.spec = {
          type = "ClusterIP";
          selector.app = "nextcloud-imaginary";
          ports.http = {
            name = "http";
            port = 9000;
            targetPort = 9000;
          };
        };

        # ── ConfigMaps ──
        configMaps.nextcloud-config.data = {
          "zz-k8s.config.php" = ''
            <?php
            $CONFIG = [
              'installed'            => true,
              'dbtype'              => 'pgsql',
              'dbhost'              => '${cfg.databaseHost}',
              'dbport'             => '${toString cfg.databasePort}',
              'dbname'             => '${cfg.databaseName}',
              'dbuser'             => '${cfg.databaseUser}',
              'dbtableprefix'      => 'oc_',
              'datadirectory'      => '/mnt/ncdata',
              'memcache.local'       => '\\OC\\Memcache\\APCu',
              'memcache.distributed' => '\\OC\\Memcache\\Redis',
              'memcache.locking'     => '\\OC\\Memcache\\Redis',
              'redis' => [
                'host'     => '${cfg.redisHost}',
                'port'     => ${toString cfg.redisPort},
              ],
              'enable_previews'      => true,
              'preview_imaginary_url'=> '${cfg.imaginaryUrl}',
              'log_type'        => 'errorlog',
              'loglevel'        => 2,
            ];
          '';
        };

        configMaps.nextcloud-nginx.data = {
          "nginx.conf" = ''
            worker_processes auto;
            error_log /dev/stderr warn;
            pid /tmp/nginx.pid;
            events { worker_connections 1024; }
            http {
              include mime.types;
              default_type application/octet-stream;
              client_body_temp_path /tmp/nginx-client-body;
              proxy_temp_path       /tmp/nginx-proxy;
              fastcgi_temp_path     /tmp/nginx-fastcgi;
              uwsgi_temp_path       /tmp/nginx-uwsgi;
              scgi_temp_path        /tmp/nginx-scgi;
              access_log /dev/stdout;
              sendfile on;
              server_tokens off;
              keepalive_timeout 65;
              upstream php-handler { server 127.0.0.1:9000; }

              server {
                listen ${toString cfg.port};
                client_max_body_size 16G;
                client_body_timeout 300s;
                fastcgi_buffers 64 4K;
                client_body_buffer_size 512k;

                gzip on; gzip_vary on; gzip_comp_level 4; gzip_min_length 256;

                root /var/www/html;
                index index.php index.html /index.php$request_uri;

                location = /robots.txt { allow all; log_not_found off; access_log off; }

                location ^~ /push/ {
                  proxy_pass http://127.0.0.1:7867/;
                  proxy_http_version 1.1;
                  proxy_set_header Upgrade $http_upgrade;
                  proxy_set_header Connection "Upgrade";
                  proxy_set_header Host $host;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
                }

                location ^~ /.well-known {
                  location = /.well-known/carddav { return 301 /remote.php/dav/; }
                  location = /.well-known/caldav  { return 301 /remote.php/dav/; }
                  return 301 /index.php$request_uri;
                }

                location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) { return 404; }
                location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)              { return 404; }

                location ~ \.php(?:$|/) {
                  fastcgi_split_path_info ^(.+?\.php)(/.*)$;
                  try_files $fastcgi_script_name =404;
                  include fastcgi_params;
                  fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                  fastcgi_param PATH_INFO $fastcgi_path_info;
                  fastcgi_param HTTPS on;
                  fastcgi_pass php-handler;
                }

                location ~ \.(?:css|js|svg|gif|ico|jpg|png|webp)$ {
                  try_files $uri /index.php$request_uri;
                  access_log off;
                }

                location / { try_files $uri $uri/ /index.php$request_uri; }
              }
            }
          '';
        };
      };
    };
  };
}
