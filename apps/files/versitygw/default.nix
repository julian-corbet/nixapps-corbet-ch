# nixapps.files.versitygw — Versity Gateway, a lightweight S3-compatible object store.
#
# What this recipe knows about Versity Gateway:
#
#   - It is a lightweight S3-compatible gateway that fronts a POSIX filesystem
#     as an S3 bucket store. The container runs the versity/versitygw binary
#     pointing at a host directory as the storage backend.
#   - Two host directories are mounted: /data (the S3 object store, where
#     bucket/object trees are stored as plain files) and /iam (the identity
#     and access management directory, holding ACLs and policies).
#   - It requires two secrets: ROOT_ACCESS_KEY and ROOT_SECRET_KEY, injected
#     from a Secret in the same namespace. These are the default admin S3
#     credentials; other users and buckets are managed via the IAM API.
#   - It runs an initContainer that writes a probe file to /data, verifying
#     the filesystem is writable before the main container starts. This early
#     check catches hostPath mount failures rather than failing later during
#     S3 PUT requests.
#   - The server listens on port 7070 and exposes /health for readiness and
#     liveness checks. The health endpoint returns 200 only when the server
#     is fully initialized.
#   - It runs with Recreate strategy (no concurrent instances; only one S3
#     gateway should front the same POSIX directory). The on-disk IAM state
#     is not replicated.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.files.versitygw;
  name = "versitygw";
in
{
  options.nixapps.files.versitygw = {
    enable = lib.mkEnableOption "Versity Gateway, an S3-compatible object store gateway";

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
      default = "versity/versitygw:v1.6.0";
      description = ''
        Container image, pinned by version tag. The gateway binary is
        lightweight and stable; use a specific release tag.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 7070;
      description = "Port the S3 gateway listens on.";
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory for S3 objects (/data in the container). This is the
        POSIX filesystem tree that backs all S3 buckets and objects. Bucket
        and object hierarchies are stored as plain files and directories.
        Must be writable by the container.
      '';
    };

    iamPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory for IAM data (/iam in the container). Holds S3 users,
        access keys, bucket ACLs, and policies. Created on first startup if
        it does not exist. Must be writable by the container.
      '';
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace holding the root S3
        credentials. Must contain two keys:

          access_key     the root access key (AWS_ACCESS_KEY_ID)
          secret_key     the root secret key (AWS_SECRET_ACCESS_KEY)

        These are the default admin credentials for all S3 operations via
        this gateway. Additional S3 users are managed via the IAM API.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "files";

      resources = {
        deployments.${name}.spec = {
          strategy.type = "Recreate";  # single S3 writer on the POSIX tree
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              initContainers.write-probe = {
                name = "write-probe";
                image = cfg.image;
                command = [
                  "/bin/sh"
                  "-c"
                  "set -e; t=/data/.vgw-write-probe; touch \"$t\" && rm -f \"$t\"; echo 'posix root writable ok'"
                ];
                volumeMounts.data = {
                  name = "data";
                  mountPath = "/data";
                };
              };
              containers.${name} = {
                name = "versitygw";
                image = cfg.image;
                args = [
                  "--port" ":${toString cfg.port}"
                  "--health" "/health"
                  "--iam-dir" "/iam"
                  "posix" "/data"
                ];
                env = {
                  ROOT_ACCESS_KEY = {
                    name = "ROOT_ACCESS_KEY";
                    valueFrom.secretKeyRef = {
                      name = cfg.secretName;
                      key = "access_key";
                    };
                  };
                  ROOT_SECRET_KEY = {
                    name = "ROOT_SECRET_KEY";
                    valueFrom.secretKeyRef = {
                      name = cfg.secretName;
                      key = "secret_key";
                    };
                  };
                };
                ports.s3 = {
                  name = "s3";
                  containerPort = cfg.port;
                  protocol = "TCP";
                };
                readinessProbe = {
                  httpGet = {
                    path = "/health";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 3;
                  periodSeconds = 10;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/health";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 10;
                  periodSeconds = 30;
                  timeoutSeconds = 5;
                  failureThreshold = 5;
                };
                volumeMounts = {
                  data = {
                    name = "data";
                    mountPath = "/data";
                  };
                  iam = {
                    name = "iam";
                    mountPath = "/iam";
                  };
                };
              };
              volumes = {
                data = {
                  name = "data";
                  hostPath = {
                    path = cfg.dataPath;
                    type = "Directory";
                  };
                };
                iam = {
                  name = "iam";
                  hostPath = {
                    path = cfg.iamPath;
                    type = "DirectoryOrCreate";
                  };
                };
              };
            };
          };
        };

        services.${name}.spec = {
          type = "ClusterIP";
          selector.app = name;
          ports.s3 = {
            name = "s3";
            port = cfg.port;
            targetPort = cfg.port;
            protocol = "TCP";
          };
        };
      };
    };
  };
}
