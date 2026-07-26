# nixapps.utility.cyberchef — CyberChef, a client-side data-transformation toolkit.
#
# What this recipe knows about CyberChef:
#
#   - It is a static web application (HTML, CSS, JavaScript) served by nginx.
#     No backend server, no database, no state. All transformations happen in
#     the browser.
#   - It runs nginx as non-root on port 8080.
#   - Because it is purely static content with no processing, it can scale
#     freely. There is no reason to scale it to zero.
#   - Deployment defaults to 1 replica, always running. If you need it
#     scale-to-zero, enable KEDA in your cluster and adjust replica settings.
#
# This is a simple, stateless web application. Nginx handles all traffic.
{ lib, config, ... }:
let
  cfg = config.nixapps.utility.cyberchef;
  name = "cyberchef";
in
{
  options.nixapps.utility.cyberchef = {
    enable = lib.mkEnableOption "CyberChef, a client-side data-transformation toolkit";

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
      default = "ghcr.io/gchq/cyberchef:11@sha256:59849a25292c9d6fb6a85a3efc1706653d9b7f168f8901ef684fa2414b968be8";
      description = ''
        Container image, pinned to 11 by digest.

        A floating tag can change behavior between deploys with nothing to review
        beforehand. The image is pinned by digest; to update it, edit this option
        and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port nginx serves HTTP on.";
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
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 10;
                  failureThreshold = 6;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 20;
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
