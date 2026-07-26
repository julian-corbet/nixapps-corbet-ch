# nixapps.utility.quickchart — QuickChart, a chart-image render API.
#
# What this recipe knows about QuickChart:
#
#   - It is a stateless HTTP API that converts chart specifications to PNG or PDF images.
#   - It serves HTTP on port 3400 and has a /healthcheck endpoint for probes.
#   - All computation is ephemeral; there is no persistent state, database, or
#     configuration. Every request is independent.
#   - Because it is stateless, it can scale freely and requires no special
#     strategy or coordination.
#
# This is a minimal, purely functional utility. Pin the image to a specific
# version since floating tags can change behavior between chart render libraries.
{ lib, config, ... }:
let
  cfg = config.nixapps.utility.quickchart;
  name = "quickchart";
in
{
  options.nixapps.utility.quickchart = {
    enable = lib.mkEnableOption "QuickChart, a chart-image render API";

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
      default = "ianw/quickchart@sha256:12e2d442e2db9974f2b310b72fadd4f6d595d0a0bf5480c3d50ef5cb5967ee56";
      description = ''
        Container image, pinned by digest (upstream publishes no tags at all).

        A floating tag can change behavior between deploys with nothing to review
        beforehand. The image is pinned by digest; to update it, edit this option
        and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3400;
      description = "Port the render API serves HTTP on.";
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "utility";

      resources = {
        deployments.${name}.spec = {
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/healthcheck";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 24;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/healthcheck";
                    port = cfg.port;
                  };
                  periodSeconds = 15;
                  failureThreshold = 6;
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
