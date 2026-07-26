# nixapps.dev.chartdb — ChartDB, a database schema diagram and visualization tool.
#
# What this recipe knows about ChartDB:
#
#   - It is a static single-page application (SPA) that runs entirely in the
#     browser. The backend is a simple HTTP server that serves the static
#     assets and WebSocket for real-time collaboration.
#   - It has no persistent state; a pod restart loses any unsaved work. Data is
#     stored in the browser's localStorage or exported by the user.
#   - It serves HTTP on port 80. Startup is fast (just serving static files),
#     so the readiness probe is patient only to account for the initial HTTP
#     connection setup.
#   - The Recreate strategy is used for consistency, though for a truly stateless
#     app a Rolling strategy would also work. Recreate is simpler and matches
#     the deployment pattern of other apps in this collection.
#   - KEDA HTTP scale-to-zero is configured separately (outside this recipe) by
#     the operator's Argo application layer, watching the access domain and
#     idling the pod after 300 seconds of inactivity.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.dev.chartdb;
  name = "chartdb";
in
{
  options.nixapps.dev.chartdb = {
    enable = lib.mkEnableOption "ChartDB, a database schema diagram tool";

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
      default = "ghcr.io/chartdb/chartdb:1.20.1@sha256:9385f1a72174a2cdba27036127a98474a0c941c3c795dcc15149884c09834460";
      description = "Container image.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Port the HTTP server listens on.";
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "dev";

      resources = {
        deployments.${name}.spec = {
          # Recreate for consistency, even though ChartDB is stateless and
          # Rolling would work. Consistent with the deployment strategy of
          # other apps in this collection.
          strategy.type = "Recreate";
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
