# nixapps.utility.rclone — rclone remote-control daemon and Web GUI.
#
# What this recipe knows about rclone:
#
#   - It runs the rclone rcd (remote-control daemon) with the Web GUI enabled.
#     The daemon listens for commands on port 5572.
#   - It is configured and controlled via a rclone.conf file on disk. The app
#     reads this file at startup and every time the operator updates it.
#   - The web interface and rclone API require HTTP basic authentication via
#     RCLONE_RC_USER and RCLONE_RC_PASS. These are supplied via a Secret.
#   - The app sets HOME=/config/rclone so it can write the downloaded web GUI
#     bundle and cache files to the persistent config directory. Without this,
#     the web interface would fail (404) on every cold start.
#   - It runs as a non-root user (uid 3043 by default, the rclone user in the
#     image). This user must own the config directory.
#   - It uses Recreate strategy because the config file is single-writer on
#     the hostPath. Do not run two pods on the same config directory.
#   - The readiness probe is a raw tcpSocket check, not HTTP. The rc API may
#     work before the web GUI is ready to serve.
#
# This is a single-writer stateful application. The config directory must be
# backed up. If you add new remotes to rclone.conf, the daemon picks them up
# on reload (or pod restart).
{ lib, config, ... }:
let
  cfg = config.nixapps.utility.rclone;
  name = "rclone";
in
{
  options.nixapps.utility.rclone = {
    enable = lib.mkEnableOption "rclone, a remote-control daemon and Web GUI";

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
      default = "rclone/rclone:1.74.4@sha256:c61954aaa32328a5486715dd063a81c7879f5195ad3505cd362deddd509dc4a1";
      description = ''
        Container image, pinned to 1.74.4 by digest.

        A floating tag can change behavior between deploys with nothing to review
        beforehand. The image is pinned by digest; to update it, edit this option
        and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5572;
      description = "Port the rcd daemon listens on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. rclone needs:

          RCLONE_RC_USER   username for HTTP basic auth to the rc API and web GUI
          RCLONE_RC_PASS   password for HTTP basic auth to the rc API and web GUI

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding rclone.conf and the downloaded web GUI bundle.

        The directory must be owned by uid 3043 (rclone) and gid 3043, or you
        must change userId and groupId below to match your preferred user. The
        app needs write permission to cache the GUI bundle across pod restarts.
      '';
    };

    userId = lib.mkOption {
      type = lib.types.int;
      default = 3043;
      description = ''
        UID the rclone daemon runs as. Must match the owner of configPath.
      '';
    };

    groupId = lib.mkOption {
      type = lib.types.int;
      default = 3043;
      description = ''
        GID the rclone daemon runs as. Must match the group of configPath.
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
              securityContext = {
                runAsUser = cfg.userId;
                runAsGroup = cfg.groupId;
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                args = [
                  "rcd"
                  "--rc-web-gui"
                  "--rc-web-gui-no-open-browser"
                  "--rc-addr=:${builtins.toString cfg.port}"
                ];
                env = {
                  RCLONE_CONFIG = {
                    name = "RCLONE_CONFIG";
                    value = "/config/rclone/rclone.conf";
                  };
                  HOME = {
                    name = "HOME";
                    value = "/config/rclone";
                  };
                  RCLONE_RC_USER = {
                    name = "RCLONE_RC_USER";
                    valueFrom.secretKeyRef = {
                      name = cfg.secretName;
                      key = "RCLONE_RC_USER";
                    };
                  };
                  RCLONE_RC_PASS = {
                    name = "RCLONE_RC_PASS";
                    valueFrom.secretKeyRef = {
                      name = cfg.secretName;
                      key = "RCLONE_RC_PASS";
                    };
                  };
                };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.cfg = {
                  name = "cfg";
                  mountPath = "/config/rclone";
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = [ "ALL" ];
                };
                readinessProbe = {
                  tcpSocket.port = cfg.port;
                  periodSeconds = 5;
                  failureThreshold = 30;
                };
                livenessProbe = {
                  tcpSocket.port = cfg.port;
                  periodSeconds = 20;
                  failureThreshold = 6;
                };
              };
              volumes.cfg = {
                name = "cfg";
                hostPath = {
                  path = cfg.configPath;
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
