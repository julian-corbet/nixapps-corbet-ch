# lib/web.nix — the shape almost every app has.
#
# CONTRACT.md R5: no two recipes duplicate a rendering. Measured against a real
# production cluster of 43 application manifests, 35 are exactly one Deployment
# plus one Service (sometimes plus a wake object), and 7 of the remaining 8 are
# that same shape plus one companion workload. So this is not a speculative
# abstraction — it is the shape, and a recipe that renders it by hand is
# duplicating this file.
#
# What stays out: exposure beyond a Service (R6 — no Ingress here, ever), the
# storage backing (R7 — `mounts` arrive already resolved), and anything that
# does the waking (R8 — `podLabels` carry discovery labels, nothing more).
{ lib, storage }:
rec {
  # One workload and its Service. Returns a `resources` fragment to be assigned
  # or merged into an application, so a recipe can add its own objects (a CRD via
  # the raw-YAML path, a ConfigMap) without this function knowing about them.
  tenant =
    {
      name,
      image,
      port,
      portName ? "http",
      # From runtime.replicasFor — an attrset, empty when a wake front owns the
      # scale. Passed pre-computed rather than as a count so that "nobody renders
      # replicas here" stays a single decision made in one place.
      replicas ? { },
      strategy ? null,
      command ? null,
      args ? null,
      env ? { },
      # Names of Secrets that already exist in the namespace. This library never
      # creates a Secret: a recipe that generated one would have to be given the
      # material, and material does not belong in a rendered manifest tree.
      secretRefs ? [ ],
      mounts ? { },
      readinessProbe ? null,
      livenessProbe ? null,
      startupProbe ? null,
      resources ? null,
      podLabels ? { },
      podSpecExtra ? { },
      containerExtra ? { },
      containerLimits ? { },
      initContainers ? [ ],
      clusterIP ? null,
      extraPorts ? [ ],
    }:
    let
      volumes = storage.toVolumes mounts;
      volumeMounts = storage.toVolumeMounts mounts;

      container =
        {
          inherit name image;
          ports = [ { containerPort = port; name = portName; } ] ++ extraPorts;
        }
        // lib.optionalAttrs (command != null) { inherit command; }
        // lib.optionalAttrs (args != null) { inherit args; }
        // lib.optionalAttrs (env != { }) {
          env = lib.mapAttrsToList (n: v: { name = n; value = v; }) env;
        }
        // lib.optionalAttrs (secretRefs != [ ]) {
          envFrom = map (s: { secretRef.name = s; }) secretRefs;
        }
        // lib.optionalAttrs (volumeMounts != [ ]) { inherit volumeMounts; }
        // lib.optionalAttrs (readinessProbe != null) { inherit readinessProbe; }
        // lib.optionalAttrs (livenessProbe != null) { inherit livenessProbe; }
        // lib.optionalAttrs (startupProbe != null) { inherit startupProbe; }
        // lib.optionalAttrs (resources != null || containerLimits != { }) {
          resources =
            (if resources != null then resources else { })
            // lib.optionalAttrs (containerLimits != { }) {
              limits = (if resources != null then resources.limits or { } else { }) // containerLimits;
            };
        }
        // containerExtra;
    in
    {
      deployments.${name} = {
        # The selector label is `app = <name>` throughout. Fixed rather than
        # configurable: a Deployment's selector is immutable after creation, so
        # making it an option hands operators a knob whose only effect is to make
        # a future change require deleting the workload.
        metadata.labels.app = name;
        spec =
          {
            selector.matchLabels.app = name;
            template = {
              metadata.labels = { app = name; } // podLabels;
              spec =
                { containers = [ container ]; }
                // lib.optionalAttrs (initContainers != [ ]) { inherit initContainers; }
                // lib.optionalAttrs (volumes != [ ]) { inherit volumes; }
                // podSpecExtra;
            };
          }
          // replicas
          // lib.optionalAttrs (strategy != null) { inherit strategy; };
      };

      services.${name}.spec =
        {
          selector.app = name;
          ports =
            [ { name = portName; inherit port; targetPort = port; } ]
            ++ map (p: { name = p.name; port = p.containerPort; targetPort = p.containerPort; }) extraPorts;
        }
        // lib.optionalAttrs (clusterIP != null) { inherit clusterIP; };
    };

  # A companion is a workload that belongs to an app but has no front door of its
  # own — a cache, a converter, a sidecar service the main workload calls. It
  # gets its own Deployment and Service so it can be scaled and addressed
  # independently, which is what distinguishes it from a second container in the
  # same pod.
  companion = args: tenant args;

  # Merge several fragments into one `resources` attrset. Recipes with companions
  # build a list and fold it, rather than hand-merging nested attrsets and
  # getting the deep-merge subtly wrong.
  mergeResources = fragments: lib.foldl' lib.recursiveUpdate { } fragments;
}
