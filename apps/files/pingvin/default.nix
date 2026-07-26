# nixapps.files.pingvin — Pingvin Share, a simple file-sharing service.
#
# What this recipe knows about Pingvin:
#
#   - It is a lightweight file-share application with all configuration
#     (public URLs, SMTP, OAuth settings) stored in a SQLite database
#     (/opt/app/backend/data/pingvin-share.db). There is no Kubernetes Secret;
#     preserving the data directory preserves all configuration.
#   - The data directory holds both the SQLite database and the uploads/ tree.
#     Both live in a single host directory. The container runs as uid 3040
#     (pingvin); the directory must be owned 3040:3040.
#   - It runs with Recreate strategy: the SQLite database is single-writer,
#     and two pods holding the same database file would corrupt it. The pod
#     will not roll to a new version until the old one exits completely.
#   - The web interface listens on port 3000. The readiness probe queries
#     /api/configs, which proxies to the backend; the pod is marked Ready only
#     when the full app is serving (avoiding premature traffic during boot).
#   - It idles cheaply and is a good candidate for resting at zero between
#     uploads, but this recipe does not decide that. Scale and wake behaviour
#     belong to the site (CONTRACT.md R8), so nothing here renders an autoscaler
#     or a waiting front, and whatever owns scaling keeps ownership.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.files.pingvin;
  name = "pingvin";
in
{
  options.nixapps.files.pingvin = {
    enable = lib.mkEnableOption "Pingvin Share, a simple file-sharing service";

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
      default = "stonith404/pingvin-share:v1.13.0@sha256:6bf2bcd3043ee68cb61264f0857511ccf7f212fdb984382b7f2d491635184ad6";
      description = ''
        Container image. Defaults to the latest community build. All config
        lives in the data directory (SQLite database), so upgrading is safe
        as long as the data persists.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port the Pingvin web interface listens on.";
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory for the SQLite database and uploads tree
        (/opt/app/backend/data in the container). Holds pingvin-share.db and
        the uploads/ folder with all shared files.
        Must be owned 3040:3040 (pingvin).
      '';
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "UTC";
      description = "IANA timezone for the container. E.g., Europe/Berlin, America/New_York.";
    };



  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "files";

      resources = {
        deployments.${name}.spec = {
          strategy.type = "Recreate";  # single-writer SQLite
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              securityContext = {
                runAsUser = 3040;
                runAsGroup = 3040;
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
                # fsGroup intentionally omitted (would recursively chown hostPath)
              };
              containers.${name} = {
                name = name;
                image = cfg.image;
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = [ "ALL" ];
                };
                env.TZ.value = cfg.timezone;
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/api/configs";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 30;
                };
                livenessProbe = {
                  tcpSocket.port = cfg.port;
                  periodSeconds = 20;
                  failureThreshold = 6;
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/opt/app/backend/data";
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
