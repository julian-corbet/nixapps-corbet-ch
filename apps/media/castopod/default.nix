# nixapps.media.castopod — Castopod, a self-hosted podcast host.
#
# What this recipe knows about Castopod:
#
#   - It is a PHP application with Caddy in the image; there is no separate web
#     server to run. It serves HTTP on :8080.
#   - Its database is external MySQL/MariaDB. You point it at one; this recipe
#     does not run a database for you.
#   - The only thing it writes to disk is uploaded media (episode audio, cover
#     art). Everything else lives in the database, so that one directory is the
#     whole persistence story.
#   - It runs its schema migrations on startup. That is why the readiness probe
#     is patient and why the image is pinned by digest rather than a tag.
#   - It wants a cache handler. `file` works and needs no extra service; the
#     documented `redis` option means running Redis purely for regenerable data.
#
# This is the reference recipe: plain nixidy, plain mkOption, nothing clever.
# Options with a default are things true of Castopod anywhere. Options without
# one are things only you know, and evaluation fails until you say them.
{ lib, config, ... }:
let
  cfg = config.nixapps.media.castopod;
  name = "castopod";
in
{
  options.nixapps.media.castopod = {
    enable = lib.mkEnableOption "Castopod, a self-hosted podcast host";

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
      default = "castopod/castopod@sha256:4e4f0440520f45257bfeac7be4347defd20048b4efef8f53d73ec9ed3a4f7966";
      description = ''
        Container image, pinned by digest rather than a tag.

        Castopod migrates the database it also owns. A floating tag can therefore
        run a schema migration on a deploy nobody reviewed, and afterwards there
        is no diff to look at. Pin it, and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the in-image Caddy serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Castopod needs at least:

          CP_DATABASE_HOSTNAME   host of the MySQL/MariaDB server
          CP_DATABASE_NAME       database name
          CP_DATABASE_USERNAME   database user
          CP_DATABASE_PASSWORD   database password
          CP_BASEURL             public https:// URL; feed links are built from
                                 it, so getting it wrong ships broken RSS to
                                 every subscriber
          CP_CACHE_HANDLER       `file` unless you want to run Redis for cache

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };

    mediaPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding uploaded episode audio and cover art.

        Large sequential files: worth putting on storage tuned for that rather
        than wherever the container runtime happens to keep its layers.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "media";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. A rolling update briefly runs the old and new
          # pod together, both holding the media directory open, and Castopod
          # expects to be its single writer.
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
                volumeMounts.media = {
                  name = "media";
                  mountPath = "/var/www/castopod/public/media";
                };
                # Three minutes of patience. A fresh install migrates more than a
                # restart does, and declaring it dead mid-migration is exactly how
                # a half-migrated schema happens.
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  initialDelaySeconds = 20;
                  periodSeconds = 10;
                  failureThreshold = 18;
                };
              };
              volumes.media = {
                name = "media";
                hostPath = {
                  path = cfg.mediaPath;
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
