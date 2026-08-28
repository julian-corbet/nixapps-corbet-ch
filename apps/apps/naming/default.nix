# naming — the private name-discovery product's web/control-plane shell.
#
# This recipe deliberately describes only the continuously reachable HTTP process. Long-running
# discovery and verification runs are not children of an HTTP request and must not be implemented
# by keeping work inside this pod: the owning product will submit finite Kubernetes Jobs, each of
# which exits when its run is complete. That is why this Deployment is always-on and why no
# HTTPScaledObject, autoscaler, queue, database, or worker appears here yet.
#
# The product source and generated names are proprietary. This public recipe contains neither: the
# operator supplies the names of two existing ConfigMaps, one holding the private static payload and
# one holding the nginx virtual-host configuration. Naming a ConfigMap is a site value in the same
# sense as naming a Secret; the recipe knows where the files belong, while the deployment owns their
# bytes.
#
# Exposure is likewise absent. The recipe renders a plain ClusterIP Service and stops; NetBird,
# public ingress, fixed addresses, DNS, placement, resources, and replica policy remain the site's
# responsibility under CONTRACT.md R6/R8.
{ config, lib, ... }:
let
  cfg = config.nixapps.apps.naming;
in
{
  options.nixapps.apps.naming = {
    enable = lib.mkEnableOption "the naming web/control-plane shell";

    namespace = lib.mkOption {
      type = lib.types.str;
      description = "Kubernetes namespace for the naming application. Required; no site is guessed.";
    };

    siteConfigMapName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Existing ConfigMap containing the private static payload. Its keys are mounted read-only at
        /usr/share/nginx/html. Required because product content belongs to the deployment, not this
        public recipe.
      '';
    };

    nginxConfigMapName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Existing ConfigMap whose default.conf key configures nginx. It is mounted as one read-only
        file so the image's other configuration remains intact.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "nginxinc/nginx-unprivileged:1.31.3-alpine@sha256:18d67281256ded39ff65e010ae4f831be18f19356f83c60bc546492c7eb6dd23";
      description = ''
        Immutable nginx-unprivileged image. The digest is part of the portable recipe: it serves
        static files on 8080 as a non-root user and changes only through review.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.naming = {
      namespace = cfg.namespace;
      createNamespace = true;
      project = "apps";

      resources = {
        deployments.naming.spec = {
          selector.matchLabels."app.kubernetes.io/name" = "naming";
          template = {
            metadata.labels."app.kubernetes.io/name" = "naming";
            spec = {
              automountServiceAccountToken = false;
              securityContext = {
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };

              containers.naming = {
                name = "naming";
                image = cfg.image;
                ports.http = {
                  name = "http";
                  containerPort = 8080;
                  protocol = "TCP";
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = [ "ALL" ];
                };
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = "http";
                  };
                  periodSeconds = 10;
                  failureThreshold = 6;
                  timeoutSeconds = 1;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = "http";
                  };
                  periodSeconds = 30;
                  failureThreshold = 3;
                  timeoutSeconds = 1;
                };
                volumeMounts = {
                  site = {
                    name = "site";
                    mountPath = "/usr/share/nginx/html";
                    readOnly = true;
                  };
                  nginx-config = {
                    name = "nginx-config";
                    mountPath = "/etc/nginx/conf.d/default.conf";
                    subPath = "default.conf";
                    readOnly = true;
                  };
                  runtime = {
                    name = "runtime";
                    mountPath = "/tmp";
                  };
                };
              };

              volumes = {
                site = {
                  name = "site";
                  configMap.name = cfg.siteConfigMapName;
                };
                nginx-config = {
                  name = "nginx-config";
                  configMap.name = cfg.nginxConfigMapName;
                };
                runtime = {
                  name = "runtime";
                  emptyDir = { };
                };
              };
            };
          };
        };

        services.naming.spec = {
          selector."app.kubernetes.io/name" = "naming";
          ports.http = {
            name = "http";
            port = 80;
            targetPort = "http";
            protocol = "TCP";
          };
        };
      };
    };
  };
}
