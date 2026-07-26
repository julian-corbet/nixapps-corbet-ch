# nixapps.productivity.donetick — Donetick, a shared chore and to-do tracker.
#
# What this recipe knows about Donetick:
#
#   - It is a self-contained Go application serving both the REST API and bundled
#     SPA frontend on one port (:2021).
#   - It uses SQLite for the database, which is single-writer: only one pod must run
#     at a time.
#   - Configuration and database live at /config (configuration file) and
#     /usr/src/app/data (SQLite database).
#   - It supports scheduled jobs (due/overdue/pre-due reminders) and a realtime
#     WebSocket/SSE channel. Scale-to-zero is acceptable for personal use, as the
#     pod wakes on the next HTTP request and scheduler jobs are re-evaluated on wake.
#   - The "/" path serves the SPA index, which is a good readiness target.
#   - securityContext does not include fsGroup: recursively chowning the hostPath
#     dataset would break existing dataset ownership.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.productivity.donetick;
  name = "donetick";
in
{
  options.nixapps.productivity.donetick = {
    enable = lib.mkEnableOption "Donetick, a shared chore and to-do tracker";

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
      default = "donetick/donetick@sha256:2f32646ef4e613f44066163646f53c02d6d5b728b31abe47dfd111b3dfd53643";
      description = ''
        Container image. Consider pinning to a specific tag or digest to avoid
        unexpected schema migrations on deployment.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 2021;
      description = "Port the application serves HTTP on.";
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the configuration file (selfhosted.yaml).
        Mounted at /config inside the container.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the SQLite database and other runtime data.
        Mounted at /usr/src/app/data inside the container.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "productivity";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. SQLite is single-writer: two pods on the same
          # database file cause corruption.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              # securityContext does not include fsGroup. Recursively chowning the
              # hostPath dataset would break the existing dataset ownership model.
              securityContext = {
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = [ "ALL" ];
                };
                env.DT_SQLITE_PATH = {
                  name = "DT_SQLITE_PATH";
                  value = "/usr/src/app/data/donetick.db";
                };
                env.DONETICK_DISABLE_SIGNUP = {
                  name = "DONETICK_DISABLE_SIGNUP";
                  value = "true";
                };
                env.DT_ENV = {
                  name = "DT_ENV";
                  value = "selfhosted";
                };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                volumeMounts.config = {
                  name = "config";
                  mountPath = "/config";
                };
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/usr/src/app/data";
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
              volumes.config = {
                name = "config";
                hostPath = {
                  path = cfg.configPath;
                  type = "Directory";
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
