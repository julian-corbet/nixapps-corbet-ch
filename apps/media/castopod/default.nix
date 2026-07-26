# nixapps.media.castopod — self-hosted podcast host.
#
# The reference recipe: read this one first. It is deliberately short, because
# everything true of more than one app lives in `lib` (CONTRACT.md R5) and
# everything true of only one site is a value the operator supplies (R2). What
# remains here is castopod itself — its port, where it writes, how long it takes
# to answer, and why it must never run two replicas.
#
# It renders exactly one Deployment and one Service, which is the shape most
# applications have; `lib.web.tenant` does that rendering.
{ lib, config, ... }:
let
  # The shared shape, imported relative to this file rather than threaded in as
  # a module argument. A flake's paths all resolve inside one store copy of the
  # whole repository, so `../../../lib` reaches the sibling directory for a
  # consumer who imported only `nixidyModules.media.castopod` — and the recipe
  # stays evaluable on its own with plain `lib.evalModules`, which R11 needs.
  l = import ../../../lib { inherit lib; };

  cfg = config.nixapps.media.castopod;
in
{
  options.nixapps.media.castopod =
    l.envelope {
      app = "castopod";
      category = "media";
      defaultNamespace = "podcast";
    }
    // {
      image = l.knowledge {
        type = lib.types.str;
        default = "castopod/castopod@sha256:4e4f0440520f45257bfeac7be4347defd20048b4efef8f53d73ec9ed3a4f7966";
        description = ''
          Container image, pinned by digest.

          A digest rather than a tag because a podcast host writes to a database
          it also migrates: a moving tag can run a schema migration on a deploy
          nobody reviewed, and there is no diff to look at afterwards
          (CONTRACT R10).
        '';
      };

      port = l.knowledge {
        type = lib.types.port;
        default = 8080;
        description = "Port castopod's HTTP server listens on inside the container.";
      };

      storage.media = l.storage.mount {
        mountPath = "/var/www/castopod/public/media";
        reason = "Uploaded episode audio and cover art are written here and served from here.";
      };

      secretName = l.value {
        type = lib.types.str;
        description = ''
          Name of an existing Secret, in this app's namespace, supplying
          castopod's environment.

          Site-specific because its contents are: the secret must provide the
          database coordinates and credentials (`CP_DATABASE_HOSTNAME`,
          `CP_DATABASE_NAME`, `CP_DATABASE_USERNAME`, `CP_DATABASE_PASSWORD`),
          the public base URL castopod builds feed links from (`CP_BASEURL`),
          and a cache handler (`CP_CACHE_HANDLER`; `file` is the option that
          needs no extra service).

          This recipe never creates the Secret. Rendering one would mean putting
          credentials into a manifest tree.
        '';
      };

      readiness = l.runtime.probeOptions {
        path = "/";
        initialDelaySeconds = 20;
        periodSeconds = 10;
        failureThreshold = 18;
        reason = ''
          Three minutes. Castopod runs its database migrations on first start,
          and a fresh install has more to do than a restart — probing it dead
          before the migration finishes would restart it mid-migration, which is
          how a half-migrated schema happens.
        '';
      };

      resources = l.runtime.resourceOptions {
        cpuRequest = "100m";
        memoryRequest = "256Mi";
        memoryLimit = "1Gi";
      };

      clusterIP = l.optionalValue {
        type = lib.types.str;
        description = ''
          Fixed cluster-internal address for this app's Service.

          Site-specific, and null for almost everyone: only set it if something
          outside the cluster routes to a pre-known address rather than resolving
          the Service by name. Exposure beyond the Service is not this recipe's
          business (CONTRACT R6).
        '';
      };
    }
    // l.runtime.lifecycleOptions {
      default = "always";
      reason = ''
        Always, by default. A podcast host publishes RSS that aggregators poll on
        their own schedule, and a feed that is asleep when a client checks is a
        feed that looks broken — so the usual reason to rest at zero does not
        apply here.
      '';
    };

  config = lib.mkIf cfg.enable {
    applications.${cfg.appName} = {
      inherit (cfg) namespace createNamespace project;

      resources = l.web.tenant {
        name = cfg.appName;
        inherit (cfg) image port clusterIP;

        replicas = l.runtime.replicasFor {
          inherit (cfg) lifecycle;
          # One. Castopod is the single writer of its media directory, and two
          # pods sharing that directory corrupt each other's uploads.
          replicas = 1;
        };

        # Recreate for the same reason: a rolling update would briefly run the
        # old and new pod together, both holding the media directory open.
        strategy.type = "Recreate";

        secretRefs = [ cfg.secretName ];
        mounts = { media = cfg.storage.media; };
        readinessProbe = l.runtime.mkHttpProbe cfg.readiness cfg.port;
        resources = l.runtime.toResources cfg.resources;
        podLabels = l.runtime.labelsFor cfg;
      };
    };
  };
}
