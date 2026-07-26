# nixapps.utility.czkawka — Czkawka, a duplicate-file finder with a GUI.
#
# What this recipe knows about Czkawka:
#
#   - It is a jlesage-based GUI application serving noVNC via HTTP on :5800.
#   - The image drops privileges from root to a specified user and group via
#     environment variables (USER_ID, GROUP_ID, SUP_GROUP_IDS). You must set
#     these to the UID and GID that own the content directories you want to scan.
#   - It scans content directories for duplicate files and allows interactive
#     deletion. These directories are mounted as-is into the container and must
#     be writable by the container's user.
#   - One directory holds the app's configuration (UI preferences). The rest
#     hold user content (audio, images, videos, etc.) that the app scans.
#   - It uses Recreate strategy because it is a GUI tool with long-running
#     interactive sessions; only one instance should run at a time.
#   - When the browser tab is closed, the app may scale to zero if KEDA is
#     configured. Scans are idempotent reads, so a mid-scan scale-down is safe.
#
# This is a jlesage image, not a generic app. The recipe models it anyway,
# exposing the content paths as required options so you can choose which
# directories to scan.
{ lib, config, ... }:
let
  cfg = config.nixapps.utility.czkawka;
  name = "czkawka";
in
{
  options.nixapps.utility.czkawka = {
    enable = lib.mkEnableOption "Czkawka, a duplicate-file finder with a GUI";

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
      default = "jlesage/czkawka@sha256:bb1012c8a162f79918eac88c7fd5e579b52e1464eeadc6fb2509363d2e569a10";
      description = "Container image, pinned by digest.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5800;
      description = "Port the noVNC GUI serves HTTP on.";
    };

    userId = lib.mkOption {
      type = lib.types.int;
      description = ''
        UID of the user running the container. The container starts as root,
        then drops to this UID. Must match the owner of the content directories
        so the app can read and delete files.
      '';
    };

    groupId = lib.mkOption {
      type = lib.types.int;
      description = ''
        GID of the user running the container. Must match the group of the
        content directories.
      '';
    };

    supplementaryGroups = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Comma-separated list of additional GIDs to add to the container user,
        e.g. "100,101". Set this if the content directories are owned by
        groups the primary GID does not include. Empty string disables this.
      '';
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory where Czkawka stores UI preferences and scan results.
        Mounted at /config inside the container.
      '';
    };

    audioPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory containing audio files to scan for duplicates.
        Mounted at /data/audio inside the container.
      '';
    };

    imagesPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory containing image files to scan for duplicates.
        Mounted at /data/images inside the container.
      '';
    };

    officePath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory containing office documents to scan for duplicates.
        Mounted at /data/office inside the container.
      '';
    };

    videosPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory containing video files to scan for duplicates.
        Mounted at /data/videos inside the container.
      '';
    };

    exchangePath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory containing exchanged files to scan for duplicates.
        Mounted at /data/exchange inside the container.
      '';
    };

    agentsPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory containing agent-managed files to scan for duplicates.
        Mounted at /data/agents inside the container.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "utility";

      resources = {
        deployments.${name}.spec = {
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env = {
                  USER_ID = {
                    name = "USER_ID";
                    value = builtins.toString cfg.userId;
                  };
                  GROUP_ID = {
                    name = "GROUP_ID";
                    value = builtins.toString cfg.groupId;
                  };
                  UMASK = {
                    name = "UMASK";
                    value = "0022";
                  };
                  KEEP_APP_RUNNING = {
                    name = "KEEP_APP_RUNNING";
                    value = "1";
                  };
                  WEB_LISTENING_PORT = {
                    name = "WEB_LISTENING_PORT";
                    value = builtins.toString cfg.port;
                  };
                } // lib.optionalAttrs (cfg.supplementaryGroups != "") {
                  SUP_GROUP_IDS = {
                    name = "SUP_GROUP_IDS";
                    value = cfg.supplementaryGroups;
                  };
                };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts = {
                  config = {
                    name = "config";
                    mountPath = "/config";
                  };
                  audio = {
                    name = "audio";
                    mountPath = "/data/audio";
                  };
                  images = {
                    name = "images";
                    mountPath = "/data/images";
                  };
                  office = {
                    name = "office";
                    mountPath = "/data/office";
                  };
                  videos = {
                    name = "videos";
                    mountPath = "/data/videos";
                  };
                  exchange = {
                    name = "exchange";
                    mountPath = "/data/exchange";
                  };
                  agents = {
                    name = "agents";
                    mountPath = "/data/agents";
                  };
                };
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 24;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 15;
                  failureThreshold = 6;
                };
              };
              volumes = {
                config = {
                  name = "config";
                  hostPath = {
                    path = cfg.configPath;
                    type = "Directory";
                  };
                };
                audio = {
                  name = "audio";
                  hostPath = {
                    path = cfg.audioPath;
                    type = "Directory";
                  };
                };
                images = {
                  name = "images";
                  hostPath = {
                    path = cfg.imagesPath;
                    type = "Directory";
                  };
                };
                office = {
                  name = "office";
                  hostPath = {
                    path = cfg.officePath;
                    type = "Directory";
                  };
                };
                videos = {
                  name = "videos";
                  hostPath = {
                    path = cfg.videosPath;
                    type = "Directory";
                  };
                };
                exchange = {
                  name = "exchange";
                  hostPath = {
                    path = cfg.exchangePath;
                    type = "Directory";
                  };
                };
                agents = {
                  name = "agents";
                  hostPath = {
                    path = cfg.agentsPath;
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
