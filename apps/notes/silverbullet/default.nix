# nixapps.notes.silverbullet — SilverBullet, a markdown note-taking app.
#
# What this recipe knows about SilverBullet:
#
#   - It is a single-writer markdown note app backed by a local filesystem /space.
#   - All state lives in that /space directory; there is no database container.
#   - It is designed to be accessed over the network and supports basic HTTP auth
#     via SB_USER (username:password plaintext in a Secret).
#   - It runs as a single pod writing to a RWO filesystem. It cannot be run
#     horizontally (Recreate strategy).
#   - Cold start is slow. The startup probe allows 40 * 3s = ~2 minutes before
#     giving up, to ensure readiness probes don't flap on first boot.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.notes.silverbullet;
  name = "silverbullet";
in
{
  options.nixapps.notes.silverbullet = {
    enable = lib.mkEnableOption "SilverBullet, a markdown note-taking app";

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
      default = "zefhemel/silverbullet:2.9.0@sha256:9deb1a9aca5c98bcce943a2f7f8b66ca980c608ea074628a506ccba830a465df";
      description = "Container image.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port the app serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace containing:

          SB_USER   username:password for HTTP basic auth

        This is the sole authentication gate for a public app, so set a strong
        value. Format: username:password (plaintext, colon-separated).
      '';
    };

    spacePath = lib.mkOption {
      type = lib.types.str;
      description = "Host directory for the /space filesystem (note storage).";
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "notes";

      resources = {
        deployments.${name}.spec = {
          # Single writer on a RWO hostPath.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env.SB_FOLDER = { name = "SB_FOLDER"; value = "/space"; };
                env.SB_HOSTNAME = { name = "SB_HOSTNAME"; value = "0.0.0.0"; };
                env.SB_PORT = { name = "SB_PORT"; value = toString cfg.port; };
                envFrom = [{ secretRef.name = cfg.secretName; }];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.space = {
                  name = "space";
                  mountPath = "/space";
                };
                # Slow cold start. Startup probe owns the boot window (40 * 3s).
                startupProbe = {
                  tcpSocket = {
                    port = cfg.port;
                  };
                  periodSeconds = 3;
                  failureThreshold = 40;
                  timeoutSeconds = 5;
                };
                readinessProbe = {
                  tcpSocket = {
                    port = cfg.port;
                  };
                  periodSeconds = 10;
                  failureThreshold = 6;
                  timeoutSeconds = 5;
                };
              };
              volumes.space = {
                name = "space";
                hostPath = {
                  path = cfg.spacePath;
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
