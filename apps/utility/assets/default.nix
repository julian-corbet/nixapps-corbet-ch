# nixapps.utility.assets — DumbAssets, an asset inventory and tracker.
#
# What this recipe knows about DumbAssets:
#
#   - It is a Node.js application serving HTTP on port 3000.
#   - It stores the complete inventory as a single JSON file plus user-uploaded
#     file assets, all on disk. There is no separate database. This is a
#     single-writer application: only one pod should run at a time.
#   - It requires Recreate strategy to enforce the single-writer invariant.
#   - It runs as root, which is unusual. The reason: at startup it writes a
#     manifest into /app/public that a non-root UID cannot write to in the
#     image. The app's data is owned root:root, which matches.
#   - It needs an HTTP basic-auth PIN to access the web interface, supplied
#     via a Secret that holds the DUMBASSETS_PIN environment variable.
#   - It is not especially resource-hungry. By default it will not scale
#     to zero: start it, and it stays running.
#
# This is a single-writer stateful application. The data directory is crucial
# and should be on durable storage. Do not migrate the directory between
# cluster runs without proper backup.
{ lib, config, ... }:
let
  cfg = config.nixapps.utility.assets;
  name = "assets";
in
{
  options.nixapps.utility.assets = {
    enable = lib.mkEnableOption "DumbAssets, an asset inventory and tracker";

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
      default = "dumbwareio/dumbassets@sha256:1bbe3a1c4aa404f3cbd9641cbf7ef24dfd3f4f09a92570eecc88d48de31517ab";
      description = ''
        Container image, pinned by digest (upstream publishes no version label).

        A floating tag can change behavior between deploys with nothing to review
        beforehand. The image is pinned by digest; to update it, edit this option
        and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port the Node.js app serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. DumbAssets needs:

          DUMBASSETS_PIN   HTTP basic-auth PIN required to access the web interface

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the JSON inventory file and uploaded assets.

        This directory must be writable by root (the container user). Owned
        root:root to match the image's expectations.
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
                envFrom = [{ secretRef.name = cfg.secretName; }];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/app/data";
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
