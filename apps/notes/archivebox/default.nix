# nixapps.notes.archivebox — ArchiveBox, a self-hosted web archive.
#
# What this recipe knows about ArchiveBox:
#
#   - It is a Python/Django web archiver that snapshots web pages (WARC + text,
#     screenshots, DOM).
#   - The index (SQLite + config) and archive snapshots both live under /data.
#     This recipe splits them into two volumes: /data for the index and /data/archive
#     for the snapshot tree. Mount them as separate datasets if they have different
#     retention/performance needs.
#   - It must start as root to initialize the runtime environment. The entrypoint
#     script uses PUID and PGID to drop privileges before launching the app process.
#     Do not add securityContext.runAsUser or runAsNonRoot to this recipe; the image
#     is designed to start as root.
#   - Single-writer SQLite: never run two pods on the same index.
#   - PUID and PGID in the environment are read by the entrypoint script, which uses
#     them to set up ownership and permissions before dropping privileges. Always set
#     them to match your index/archive ownership.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.notes.archivebox;
  name = "archivebox";
in
{
  options.nixapps.notes.archivebox = {
    enable = lib.mkEnableOption "ArchiveBox, a self-hosted web archive";

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
      default = "ghcr.io/archivebox/archivebox@sha256:fdf2936192aa1e909b0c3f286f60174efa24078555be4b6b90a07f2cef1d4909";
      description = ''
        Container image, pinned by digest. ArchiveBox migrations are non-trivial;
        a floating tag could migrate the index without review.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "Port the app serves HTTP on.";
    };

    indexPath = lib.mkOption {
      type = lib.types.str;
      description = "Host directory for the SQLite index and application config.";
    };

    archivePath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory for the archive snapshot tree (WARC, assets, text).
        Mounted inside the container at /data/archive so it is a nested mount
        under /data.
      '';
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 911;
      description = ''
        User ID the app process runs as (after the entrypoint drops privileges).
        Must match the uid of the user who should own the index.
      '';
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 911;
      description = ''
        Group ID the app process runs as (after the entrypoint drops privileges).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "notes";

      resources = {
        deployments.${name}.spec = {
          # Single-writer SQLite index.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env.PUID = { name = "PUID"; value = toString cfg.uid; };
                env.PGID = { name = "PGID"; value = toString cfg.gid; };
                env.TIMEOUT = { name = "TIMEOUT"; value = "120"; };
                env.PUBLIC_INDEX = { name = "PUBLIC_INDEX"; value = "False"; };
                env.PUBLIC_SNAPSHOTS = { name = "PUBLIC_SNAPSHOTS"; value = "False"; };
                env.PUBLIC_ADD_VIEW = { name = "PUBLIC_ADD_VIEW"; value = "False"; };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.index = {
                  name = "index";
                  mountPath = "/data";
                };
                volumeMounts.archive = {
                  name = "archive";
                  mountPath = "/data/archive";
                };
              };
              volumes.index = {
                name = "index";
                hostPath = {
                  path = cfg.indexPath;
                  type = "DirectoryOrCreate";
                };
              };
              volumes.archive = {
                name = "archive";
                hostPath = {
                  path = cfg.archivePath;
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
