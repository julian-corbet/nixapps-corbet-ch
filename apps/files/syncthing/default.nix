# nixapps.files.syncthing — Syncthing, a decentralized continuous file synchronization service.
#
# What this recipe knows about Syncthing:
#
#   - It is a decentralized sync service. The device identity (device ID, TLS
#     certificates, the index of synchronized files) lives in /config. This
#     directory MUST be pre-seeded with an existing configuration; Syncthing
#     regenerates a new device ID if /config is empty, breaking peer connections
#     and folder sync. This recipe does not create the PVC; it assumes
#     configClaimName points to an existing, pre-seeded PersistentVolumeClaim.
#   - The synced data lives in /syncthing (mounted from a host directory). The
#     container's folder config (config.xml) must reference paths within
#     /syncthing; if you move the mount point, you must update config.xml
#     manually via the WebUI.
#   - It runs on port 8384 (WebUI). Additional ports for peer-to-peer sync
#     (22000 tcp/udp, 21027 discovery udp) are opened by the container itself
#     and bound to the host; this recipe exposes them via a Service if needed.
#   - Recreate strategy: the config PVC is ReadWriteOnce (RWO), and syncthing
#     holds a lock file. Two pods sharing the same /config would corrupt the
#     index and lock state. The pod will not roll to a new version until the
#     old one exits completely.
#   - It runs as uid 3004 (linuxserver convention); the synced data and config
#     directories must be owned 3004:3004.
#   - No persistent volume is created by this recipe. You must pre-seed the
#     config claim with an existing syncthing device ID (via migration or manual
#     setup), then reference that claim by name in the configClaimName option.
#     Losing the config PVC loses the device ID, and the instance becomes a new
#     peer.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.files.syncthing;
  name = "syncthing";
in
{
  options.nixapps.files.syncthing = {
    enable = lib.mkEnableOption "Syncthing, a decentralized continuous file synchronization service";

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
      default = "lscr.io/linuxserver/syncthing:v2.1.2-ls226@sha256:ae909bee7c41f516be03fd7de72317a44f4a043bcba76884de941b99407b6957";
      description = ''
        Container image. Defaults to the linuxserver.io community image.
        Note: using "latest" is common for this image; if you prefer a pinned
        version, check the image repository for available tags.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8384;
      description = "Port the Syncthing WebUI listens on.";
    };

    configClaimName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing PersistentVolumeClaim holding the Syncthing device
        configuration (/config). This MUST be pre-seeded with a syncthing device
        ID (device key, certificate, and config.xml). An empty /config causes
        syncthing to regenerate its device ID, becoming a new peer and breaking
        sync with its former partners. If migrating from docker, rsync the
        docker appdata to the PVC before deploying this recipe.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory containing the synced files (/syncthing in the container).
        The folder paths in config.xml must all be subdirectories of /syncthing
        (e.g., /syncthing/documents, /syncthing/photos). If you change this
        path, you must update the folder paths in config.xml via the WebUI.
        Must be owned 3004:3004 (syncthing user).
      '';
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "UTC";
      description = "IANA timezone for the container. E.g., Europe/Berlin, America/New_York.";
    };

    umask = lib.mkOption {
      type = lib.types.str;
      default = "022";
      description = "File creation mask for synced files (octal string).";
    };

    exposeDiscovery = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to expose the discovery and sync ports (22000 tcp/udp,
        21027 udp) via a Service. Set true only if you need external peer
        discovery (peer-to-peer sync over WAN). Intra-cluster sync always works.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "files";

      resources = {
        deployments.${name}.spec = {
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              securityContext = {
                runAsUser = 3004;
                runAsGroup = 3004;
              };
              containers.${name} = {
                name = name;
                image = cfg.image;
                env = {
                  PUID.value = "3004";
                  PGID.value = "3004";
                  UMASK.value = cfg.umask;
                  TZ.value = cfg.timezone;
                };
                ports = {
                  webui = {
                    name = "webui";
                    containerPort = cfg.port;
                  };
                  sync-tcp = {
                    name = "sync-tcp";
                    containerPort = 22000;
                    protocol = "TCP";
                  };
                  sync-udp = {
                    name = "sync-udp";
                    containerPort = 22000;
                    protocol = "UDP";
                  };
                  discovery = {
                    name = "discovery";
                    containerPort = 21027;
                    protocol = "UDP";
                  };
                };
                volumeMounts = {
                  config = {
                    name = "config";
                    mountPath = "/config";
                  };
                  data = {
                    name = "data";
                    mountPath = "/syncthing";
                  };
                };
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 30;
                  periodSeconds = 30;
                  failureThreshold = 3;
                };
              };
              volumes = {
                config = {
                  name = "config";
                  persistentVolumeClaim = {
                    claimName = cfg.configClaimName;
                  };
                };
                data = {
                  name = "data";
                  hostPath = {
                    path = cfg.dataPath;
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
          ports.webui = {
            name = "webui";
            port = cfg.port;
            targetPort = cfg.port;
          };
        };

        services."${name}-sync" = lib.mkIf cfg.exposeDiscovery {
          spec = {
            type = "ClusterIP";
            selector.app = name;
            ports = {
              sync-tcp = {
                name = "sync-tcp";
                port = 22000;
                targetPort = 22000;
                protocol = "TCP";
              };
              sync-udp = {
                name = "sync-udp";
                port = 22000;
                targetPort = 22000;
                protocol = "UDP";
              };
              discovery = {
                name = "discovery";
                port = 21027;
                targetPort = 21027;
                protocol = "UDP";
              };
            };
          };
        };
      };
    };
  };
}
