# lib/runtime.nix — probes, lifecycle intent, and sizing.
#
# CONTRACT.md R8: a recipe declares that it runs always, or that it may be woken
# on demand. It never bundles the thing that does the waking, and it never names
# a particular autoscaler — which front an operator runs, and how that front
# discovers workloads, is site-specific.
{ lib, options }:
let
  inherit (options) knowledge value;
in
rec {
  # ── Probes ────────────────────────────────────────────────────────────────
  # Probe TIMING is knowledge: how long an app takes to become ready is a fact
  # about the app, usually learned the hard way, and it is exactly the kind of
  # fact worth publishing (R3). The numbers are the recipe's; only pathological
  # hardware justifies an override.
  probeOptions =
    {
      path,
      periodSeconds,
      failureThreshold,
      reason,
      timeoutSeconds ? null,
      initialDelaySeconds ? null,
    }:
    {
      path = knowledge {
        type = lib.types.str;
        default = path;
        description = "HTTP path this app answers readiness on. Upstream's, not yours.";
      };

      periodSeconds = knowledge {
        type = lib.types.ints.positive;
        default = periodSeconds;
        description = "Seconds between readiness attempts.";
      };

      failureThreshold = knowledge {
        type = lib.types.ints.positive;
        default = failureThreshold;
        description = ''
          Consecutive failures tolerated before the pod is considered unhealthy.

          Multiplied by periodSeconds this is the app's boot grace. ${reason}
        '';
      };
    }
    // lib.optionalAttrs (timeoutSeconds != null) {
      timeoutSeconds = knowledge {
        type = lib.types.ints.positive;
        default = timeoutSeconds;
        description = "Seconds an individual probe attempt may take before counting as a failure.";
      };
    }
    // lib.optionalAttrs (initialDelaySeconds != null) {
      initialDelaySeconds = knowledge {
        type = lib.types.ints.unsigned;
        default = initialDelaySeconds;
        description = ''
          Seconds to wait before the first probe attempt.

          Worth setting where an app is known to need a fixed warm-up: probing
          earlier only fills the event log with failures that were never
          informative.
        '';
      };
    };

  mkHttpProbe =
    probe: port:
    {
      httpGet = { path = probe.path; inherit port; };
      periodSeconds = probe.periodSeconds;
      failureThreshold = probe.failureThreshold;
    }
    // lib.optionalAttrs (probe ? timeoutSeconds) { inherit (probe) timeoutSeconds; }
    // lib.optionalAttrs (probe ? initialDelaySeconds) { inherit (probe) initialDelaySeconds; };

  # ── Lifecycle ─────────────────────────────────────────────────────────────
  lifecycleOptions =
    {
      default,
      reason,
    }:
    {
      lifecycle = knowledge {
        type = lib.types.enum [ "always" "onDemand" ];
        inherit default;
        description = ''
          Whether this app is expected to run continuously, or may rest at zero
          replicas and be woken on first use. ${reason}

          This is intent. Nothing in this repository implements waking — see
          `wake.labels` for how an external front finds this workload.
        '';
      };

      wake.labels = value {
        type = lib.types.attrsOf lib.types.str;
        description = ''
          Discovery labels your wake front requires on this workload, keyed by
          label name.

          Site-specific because the front is: different fronts key off different
          labels, and which one you run is your choice, not this recipe's. Only
          read when lifecycle = "onDemand", so always-on deployments never owe a
          value here.
        '';
      };
    };

  # A woken workload must NOT render a replica count: whatever front owns its
  # scale would fight the manifest for it on every sync, and the app would be
  # dragged back up seconds after being put to sleep. Omitting the field cedes
  # ownership cleanly.
  replicasFor =
    { lifecycle, replicas }: lib.optionalAttrs (lifecycle == "always") { inherit replicas; };

  labelsFor =
    cfg: lib.optionalAttrs (cfg.lifecycle == "onDemand") cfg.wake.labels;

  # ── Sizing ────────────────────────────────────────────────────────────────
  # Defaults are knowledge — a starting point that works — but they are the
  # option most likely to be legitimately overridden, because sizing depends on
  # hardware and on how hard one operator drives an app.
  resourceOptions =
    {
      cpuRequest ? null,
      memoryRequest,
      memoryLimit,
    }:
    {
      memoryRequest = knowledge {
        type = lib.types.str;
        default = memoryRequest;
        description = "Memory reservation. A working starting point; tune to your load.";
      };

      memoryLimit = knowledge {
        type = lib.types.str;
        default = memoryLimit;
        description = ''
          Memory ceiling. Set on every recipe deliberately: an app without one
          can take a node down with it, which on a single-node cluster means
          taking everything down with it.
        '';
      };
    }
    // lib.optionalAttrs (cpuRequest != null) {
      cpuRequest = knowledge {
        type = lib.types.str;
        default = cpuRequest;
        description = "CPU reservation. No limit is set — CPU throttling degrades an app more confusingly than it protects the node.";
      };
    };

  toResources =
    r:
    {
      requests =
        { memory = r.memoryRequest; }
        // lib.optionalAttrs (r ? cpuRequest) { cpu = r.cpuRequest; };
      limits.memory = r.memoryLimit;
    };
}
