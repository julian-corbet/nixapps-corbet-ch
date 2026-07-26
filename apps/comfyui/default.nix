# comfyui — the flagship DIRECT-GPU tenant: a scale-to-zero image-generation app that owns the whole
# card while it runs. It declares the three-line nixgpu contract (priorityClassName, `strategy:
# Recreate`, a device-resource token) and never thinks about the card again — see nixgpu CONTRACT.md
# for what that contract guarantees it in return (B1/B2/B8/B9: co-residence when it fits, clean
# priority-ordered yield when it doesn't, decided by live measured VRAM, never a card reset).
#
# GPU DEVICE INFRA (device tokens, priority ladder, pressure watcher) is a separate concern, shipped
# by the sibling nixgpu project — this module only *consumes* that contract, it does not provide it.
#
# WAKE-FRONT CONSUMER, NOT PROVIDER: this module can carry the opt-in labels
# (`sablier.enable`/`sablier.group`, see `wake.*` below) that let a scale-to-zero waiting-page front
# recognize and manage this Deployment — but it does not bundle Sablier or Caddy itself. That wiring
# already exists as its own module: nixgpu's `ondemand-front` (Sablier + a themed Caddy front). Bring
# your own `nixgpu.ondemandFront.apps.<name>` entry with a `group` matching `wake.sablierGroupLabelValue`
# below; this module only ever renders the consumer-side labels.
#
# REUSABLE PATTERN: injecting a custom pre-start hook into a read-only-ConfigMap-hostile image.
# Several ROCm/CUDA base images source an optional startup hook script (here: `preStartHookPath`) IF
# present, and unconditionally `chmod +x` it before sourcing — which fails, every single time, on a
# directly-mounted ConfigMap volume (Kubernetes projects those read-only, with no override). The fix
# generalizes past ComfyUI: an init container copies the ConfigMap's content onto an already-writable
# volume the main container also mounts, and chmods the COPY, not the ConfigMap-backed original. See
# `preStartScript` below for the full lesson and a worked example (a CUDA-only Python package several
# popular custom nodes pull in unconditionally, breaking every ROCm/non-CUDA GPU host the same way).
#
# Status: extracted from a production system where this exact shape runs live, scale-to-zero fronted,
# consuming a single shared GPU alongside other direct-GPU and serving-lane tenants. A Deployment
# resting at 0/0 replicas between requests is the expected steady state of a wake-front consumer, not
# a failure — see the `wake.enable` note below on why `replicas` is omitted entirely in that mode.
# This generalized module has not yet been re-verified live in a fresh cluster — re-verify before
# trusting it there.
{ lib, config, ... }:
let
  cfg = config.nixapps.comfyui;

  # Sablier's OWN discovery label key — fixed by Sablier itself, not a convention of this project
  # (unlike the nixgpu managed/engine label keys below, which ARE this project family's own
  # convention and therefore configurable). Only the *group* half is a per-app value worth exposing.
  sablierEnableLabelKey = "sablier.enable";

  # The always-present CLI flags (own the listen address, route output to outputMountPath), plus
  # whatever extra native ComfyUI/base-image flags the consumer wants appended.
  cliArgs = lib.concatStringsSep " "
    ([ "--listen" "0.0.0.0" "--output-directory" cfg.outputMountPath ] ++ cfg.extraCliArgs);

  preStartHookDir = builtins.dirOf cfg.preStartHookPath;
in
{
  options.nixapps.comfyui = {
    enable = lib.mkEnableOption "the ComfyUI image-generation tenant (a direct GPU consumer under the nixgpu contract)";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "comfyui";
      description = "Namespace the Deployment and Service run in.";
    };

    appName = lib.mkOption {
      type = lib.types.str;
      default = "comfyui";
      description = ''
        Name of the generated nixidy/Argo application. Override to adopt an EXISTING application's
        name so a migration onto this module becomes an in-place spec update (no prune/recreate
        race) instead of a delete-and-recreate across two applications.
      '';
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this application creates its own namespace.";
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "apps";
      description = ''
        nixidy AppProject this application is filed under. Map it to whatever your Argo CD
        AppProject tiering scheme calls the tier for apps that touch the GPU directly — this pod
        holds a device-resource token and a GPU priority class, so it belongs with other direct GPU
        consumers, not with plain CPU-only workloads or with the platform/device-infra tier that
        nixgpu itself occupies (device tokens, priority ladder, pressure watcher).
      '';
    };

    modelStoreHostPath = lib.mkOption {
      type = lib.types.str;
      example = "/srv/comfyui/models";
      description = ''
        Absolute host filesystem path to ComfyUI's `models/` directory root, on whatever node the
        pod is scheduled to. REQUIRED, no default — every real deployment's storage layout is
        different, and any default here would silently point at a path that doesn't exist on your
        node.

        Unlike nixllm's serving lane (which mounts one hostPath per model-owning subdirectory),
        this is ONE mount of ComfyUI's whole `models/` tree, because ComfyUI itself (and its
        ecosystem of custom nodes / model managers) expects the full conventional layout —
        `checkpoints/`, `loras/`, `controlnet/`, `insightface/`, and whatever families your custom
        nodes add — present as siblings under one root, not curated per-subdirectory by this
        module. If your cluster keeps one big model store shared across several apps, point this
        at a dedicated subtree scoped to what ComfyUI should see (or curate via bind mounts on the
        host) rather than the whole shared store, so a reorganization elsewhere in that store can't
        silently change what this pod sees.
      '';
    };

    modelMountPath = lib.mkOption {
      type = lib.types.str;
      default = "/root/ComfyUI/models";
      description = ''
        In-pod path `modelStoreHostPath` is mounted at. Defaults to ComfyUI's own convention: a
        `ComfyUI/models` directory under the app's working directory (see `stateMountPath`). Only
        change this if you run a different ComfyUI-compatible image with a different expected
        layout.
      '';
    };

    stateHostPath = lib.mkOption {
      type = lib.types.str;
      example = "/srv/comfyui/state";
      description = ''
        Absolute host filesystem path for the pod's persistent working directory — ComfyUI's own
        installation lives here (its Python venv, `custom_nodes/`, user data, cache) across pod
        restarts. REQUIRED, no default, for the same reason as `modelStoreHostPath`. The directory
        is created on first use if missing; the container runs as root and owns everything under it
        as root — this module makes no attempt to chown it to a non-root uid.
      '';
    };

    stateMountPath = lib.mkOption {
      type = lib.types.str;
      default = "/root";
      description = ''
        In-pod mount path for `stateHostPath`, and the base directory `preStartHookPath` and
        `modelMountPath` (ComfyUI's own default install location) are both relative to. Matches the
        default image's own home-directory convention; only change this for an image laid out
        differently.
      '';
    };

    outputHostPath = lib.mkOption {
      type = lib.types.str;
      example = "/srv/comfyui/output";
      description = ''
        Absolute host filesystem path rendered images are written to. REQUIRED, no default — point
        this at wherever your own storage/media layout wants generated images to land. The
        container writes here as root (see `stateHostPath` above): if this directory is owned by, or
        grants write access to, a non-root user or group on your host (a setgid directory, an ACL),
        files written by this pod will still show `root` as their owner — a harmless cosmetic gap,
        not a permissions failure, since the parent directory's own ownership is unaffected.
      '';
    };

    outputMountPath = lib.mkOption {
      type = lib.types.str;
      default = "/output";
      description = ''
        In-pod mount path for `outputHostPath`. Also becomes the `--output-directory` value passed
        to ComfyUI via `CLI_ARGS`, so every render lands here rather than in ComfyUI's own working
        tree under `stateMountPath`.
      '';
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 8188;
      description = "Port ComfyUI listens on inside the pod, and that the Service targets. Matches ComfyUI's own default.";
    };

    extraCliArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--lowvram" "--preview-method" "auto" ];
      description = ''
        Extra native ComfyUI / base-image CLI flags, appended after the always-present
        `--listen 0.0.0.0 --output-directory <outputMountPath>`. Empty by default — most
        deployments need nothing here.
      '';
    };

    preStartHookPath = lib.mkOption {
      type = lib.types.str;
      default = "/root/user-scripts/pre-start.sh";
      description = ''
        In-pod path the base image's own entrypoint sources on every container start, IF a file
        exists there. This default is `yanwk/comfyui-boot`'s own convention (its ROCm entrypoint
        checks this exact path) — a different base image may hook startup differently, or not at
        all; check its own entrypoint before assuming this path applies.
      '';
    };

    preStartScript = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = ''
        #!/bin/bash
        set -eu
        echo "Installing custom node Python requirements..."
        for req in /root/ComfyUI/custom_nodes/*/requirements.txt; do
          [ -f "$req" ] || continue
          # Non-fatal per node: one custom node's flaky/optional dependency must not take down
          # every other node sharing this pod.
          pip install --no-cache-dir -r "$req" || echo "WARN: failed installing $req"
        done
        # onnxruntime-gpu is CUDA-only and several popular custom nodes (face/ID-swap nodes among
        # them) list it unconditionally for any x86_64 Linux host — their requirements.txt carries
        # no ROCm/CUDA marker at all. On a non-CUDA GPU host it silently clobbers a working plain
        # `onnxruntime` install and breaks every node that imports onnxruntime/insightface. Strip
        # it every time, regardless of which node pulled it in.
        if pip show onnxruntime-gpu >/dev/null 2>&1; then
          pip uninstall -y onnxruntime-gpu
          pip install --no-cache-dir --force-reinstall --no-deps onnxruntime
        fi
      '';
      description = ''
        Optional shell script content, run once per pod start BEFORE ComfyUI itself starts, via the
        copy-then-chmod init container this module renders when set. Use it for custom-node
        bootstrap work the base image doesn't do for you — most commonly installing a git-cloned
        custom node's own `requirements.txt` (ComfyUI-Manager does this automatically when a node
        is installed through its own UI; a node added by cloning straight into `custom_nodes/`
        otherwise gets no dependency install at all) and any package-conflict fixups your custom
        nodes need (see the CUDA/onnxruntime example above — the general lesson: a
        GPU-vendor-conditional Python package pulled in by a dependency that assumes CUDA is the
        only non-CPU backend in existence). `null` (the default) skips the hook entirely: no
        ConfigMap, no init container, nothing mounted or written at `preStartHookPath`.

        WHY an init container copies this onto a writable volume instead of mounting the ConfigMap
        directly at `preStartHookPath`: ConfigMap volumes are always projected READ-ONLY, with no
        override — but an entrypoint that unconditionally `chmod +x`'s this hook before sourcing it
        (as the default image's does) fails on a read-only mount and, under the entrypoint's own
        `set -e`, aborts startup before the app ever runs. Every time, not intermittently. The fix
        generalizes past ComfyUI: whenever a base image insists on `chmod`-ing a file you supply via
        ConfigMap, mount the ConfigMap somewhere else read-only and have an init container copy it
        onto an already-writable volume the main container also mounts, then chmod the COPY, never
        the ConfigMap-backed original.
      '';
    };

    readiness = {
      periodSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "How often the readiness probe polls once startup begins.";
      };

      failureThreshold = lib.mkOption {
        type = lib.types.ints.positive;
        default = 180;
        description = ''
          Consecutive probe failures tolerated before the pod is considered failed. At the default
          `periodSeconds` this is 15 minutes of grace — sized for a genuinely slow cold start (a
          `preStartScript` installing custom-node dependencies from scratch, plus first model load)
          rather than the average one. This matters specifically because a wake-front (see `wake.*`)
          holds callers on an honest waiting page until the pod is Ready: too short a threshold here
          shows up as k8s declaring the pod failed and restarting it mid cold-start, every time a
          slow load coincides with a fresh pull or a cold page cache — not as an occasional flake.
          Raise it further if your custom nodes or models are heavier than the reference deployment.
        '';
      };
    };

    resources = {
      memoryLimit = lib.mkOption {
        type = lib.types.str;
        default = "24Gi";
        description = ''
          Pod memory limit. This is ordinary system RAM, separate from the VRAM the device-resource
          token below gates — image-generation pipelines commonly stage tensors and decode/encode
          buffers through system RAM around the VRAM-bound steps, so a too-tight memory limit
          OOM-kills the pod even when the GPU itself had headroom.
        '';
      };

      memoryRequest = lib.mkOption {
        type = lib.types.str;
        default = "4Gi";
        description = "Pod memory request.";
      };
    };

    clusterIP = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional fixed ClusterIP for the Service. Leave null for a normal, cluster-assigned
        ClusterIP (the right choice for almost everyone). Only set this if your cluster's
        CNI/routing convention needs consuming apps (or a wake-front's reverse proxy) to reach a
        stable, pre-known VIP rather than resolving the Service by DNS.
      '';
    };

    gpu = {
      priorityClassName = lib.mkOption {
        type = lib.types.str;
        default = "gpu-besteffort";
        description = ''
          PriorityClass for the pod. Defaults to the nixgpu ladder's best-effort rung (see nixgpu's
          priority-ladder module) — a throwaway render nobody is actively waiting on is exactly what
          best-effort is for: first to yield under VRAM pressure (nixgpu CONTRACT.md B2), with no
          starvation protection. Priority is a property of intent, not of this app's identity — raise
          it to a higher rung only for the duration of a specific run an operator is actively waiting
          on, per the ladder's own design.
        '';
      };

      nodeSelector = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { gpu = "amd"; };
        description = "Node selector restricting the pod to the node(s) that carry the shared GPU.";
      };

      deviceResourceName = lib.mkOption {
        type = lib.types.str;
        default = "devic.es/rocm-compute";
        description = ''
          Extended-resource name the pod requests, matching whatever device plugin advertises the
          GPU's compute lane (e.g. nixgpu's device-tokens module, which by default advertises this
          exact resource name via squat/generic-device-plugin). This is the ONE contract token that
          makes this a direct GPU consumer — it co-resides with other tenants requesting the same
          lane, up to the plugin's own concurrency ceiling.
        '';
      };

      deviceResourceCount = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "How many device-resource slots the pod requests. One pod holds one compute slot.";
      };

      managedLabelKey = lib.mkOption {
        type = lib.types.str;
        default = "example.com/managed";
        description = ''
          Pod label key marking this pod as under nixgpu's management (e.g. visible to a pressure
          watcher that reclaims VRAM by priority). Set to "true" on the pod template. The default is
          a placeholder domain — rename it to match whatever label domain the rest of your nixgpu
          deployment uses (it must agree with that deployment's own `managedLabelKey`, e.g. the
          pressure-watcher module's option of the same name).
        '';
      };

      engineLabelKey = lib.mkOption {
        type = lib.types.str;
        default = "example.com/engine";
        description = ''
          Pod label key identifying which GPU engine this pod uses (see engineLabelValue). The
          default is a placeholder domain — rename it to match whatever label domain the rest of
          your nixgpu deployment uses (it must agree with that deployment's own `engineLabelKey`).
        '';
      };

      engineLabelValue = lib.mkOption {
        type = lib.types.str;
        default = "compute";
        description = ''
          Engine identifier for the label above. Image generation uses the compute engine (as
          opposed to a media/video-codec engine, which runs on separate silicon and is unaffected by
          compute-side pressure — see nixgpu CONTRACT.md B3).
        '';
      };

      hsaOverrideGfxVersion = lib.mkOption {
        type = lib.types.str;
        default = "10.3.0";
        description = ''
          `HSA_OVERRIDE_GFX_VERSION` passed to the container. ROCm ships official support for a
          fixed list of GPU architectures; this override tells ROCm to treat the card as the nearest
          supported architecture. This option DEFAULTS to "10.3.0" — the value an RDNA2 consumer
          card needs — IT IS AN EXAMPLE, not a universal default. Find your own card's correct value
          from ROCm's supported-GPU list, or set this to "" (empty string) to omit the env var
          entirely on a card ROCm already supports natively.
        '';
      };
    };

    # Carrying the wake-front CONSUMER labels (Sablier's own `sablier.enable`/`sablier.group`
    # discovery labels) on this Deployment. This module never bundles Sablier or a Caddy front
    # itself — pair `wake.enable = true` with nixgpu's `ondemand-front` module (or any Sablier
    # deployment you run yourself) and add a matching `nixgpu.ondemandFront.apps.<name>` entry
    # whose `group` equals `wake.sablierGroupLabelValue` below.
    #
    # `wake.enable` also changes how `replicas` is rendered (see the `config` section below): when
    # enabled, `replicas` is OMITTED from the Deployment spec entirely, deliberately, because the
    # wake-front now owns the replica count out-of-band (scaling the Deployment 0<->1 on traffic).
    # If GitOps also declared a fixed replica count here, every sync would fight the wake-front's
    # own scaling, flapping the pod between the two. Leave this disabled only for a tenant that
    # runs unscaled at a fixed replica count of 1.
    wake = {
      enable = lib.mkEnableOption
        "carrying the wake-front consumer labels (Sablier's sablier.enable/sablier.group), and omitting replicas so the wake-front owns scaling — see the comment above this option group";

      sablierGroupLabelKey = lib.mkOption {
        type = lib.types.str;
        default = "sablier.group";
        description = ''
          Sablier's own discovery label key, fixed by Sablier itself — not this project's
          convention (unlike `gpu.managedLabelKey`/`gpu.engineLabelKey` above). Override only if
          your Sablier deployment is configured with a non-default label-tag prefix.
        '';
      };

      sablierGroupLabelValue = lib.mkOption {
        type = lib.types.str;
        default = cfg.appName;
        description = ''
          Sablier group name for this Deployment. Must match the `group` field of the corresponding
          entry in the wake-front's own `apps` option (e.g. `nixgpu.ondemandFront.apps.<name>.group`)
          — this is how the wake-front's Sablier instance knows which workload a given waiting-page
          route is waiting for. Defaults to `appName`, which is fine as long as you use the same
          value on both sides; only diverge if you need the two names to differ.
        '';
      };
    };

    images = {
      comfyui = lib.mkOption {
        type = lib.types.str;
        default = "yanwk/comfyui-boot@sha256:7c64b5765f649536887f7cfad5f3b5559d1ec81547974e5ed325834782b04d61";
        description = ''
          ComfyUI image. Pinned by DIGEST, not a floating tag — a moving `:rocm`-style tag can
          change crash behavior under you between deploys with nothing to diff or review; a digest
          pin makes every upgrade a deliberate, auditable bump instead of a silent rebase. Point
          this at your own image if you use a different ComfyUI distribution or a different backend
          (CUDA, etc.) — in which case also revisit `gpu.hsaOverrideGfxVersion` and the ROCm-specific
          `securityContext` this module sets, which may not apply.
        '';
      };

      preStartInstaller = lib.mkOption {
        type = lib.types.str;
        default = "busybox:stable@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f";
        description = ''
          Minimal image for the copy-then-chmod init container that installs `preStartScript` onto
          the writable state volume (see that option's doc) — a POSIX shell plus cp/chmod is all it
          needs. Only rendered/used when `preStartScript` is set.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${cfg.appName} = {
      namespace = cfg.namespace;
      createNamespace = cfg.createNamespace;
      project = cfg.project;

      # `resources` is built as ONE attrset (rather than via top-level `//` on `applications.${cfg.appName}`
      # itself) so that conditionally adding `configMaps` below can never shallow-overwrite `deployments`/
      # `services` — `//` only merges the keys present on each side, and `resources` must stay the single
      # attrset those keys are merged onto.
      resources = {
        deployments.comfyui = {
          # `sablier.enable`/`sablier.group` are Sablier's own discovery labels and, per Sablier's
          # own convention, live on the DEPLOYMENT's resource labels — not the pod template's —
          # since the wake-front's Sablier instance discovers scaling targets by querying
          # Deployments directly. The nixgpu managed/engine labels below are the opposite: they
          # mark individual PODS for a pressure watcher that inspects running pods, so they belong
          # on the template.
          metadata.labels = { app = "comfyui"; } // lib.optionalAttrs cfg.wake.enable {
            "${sablierEnableLabelKey}" = "true";
            "${cfg.wake.sablierGroupLabelKey}" = cfg.wake.sablierGroupLabelValue;
          };

          spec = {
            # strategy: Recreate, not RollingUpdate: this pod holds the ONE compute device-resource
            # slot (gpu.deviceResourceCount, default 1), so a surging new pod couldn't schedule
            # anyway while the old one is still up — Recreate tears the old pod down first,
            # avoiding a pod stuck Pending for the whole rollout.
            strategy.type = "Recreate";
            selector.matchLabels.app = "comfyui";
            template = {
              metadata.labels = {
                app = "comfyui";
                "${cfg.gpu.managedLabelKey}" = "true";
                "${cfg.gpu.engineLabelKey}" = cfg.gpu.engineLabelValue;
              };
              spec = {
                nodeSelector = cfg.gpu.nodeSelector;
                priorityClassName = cfg.gpu.priorityClassName;

                initContainers = lib.optional (cfg.preStartScript != null) {
                  name = "pre-start-install";
                  image = cfg.images.preStartInstaller;
                  command = [
                    "sh"
                    "-c"
                    "mkdir -p ${preStartHookDir} && cp /pre-start-src/pre-start.sh ${cfg.preStartHookPath} && chmod +x ${cfg.preStartHookPath}"
                  ];
                  volumeMounts = [
                    { name = "state"; mountPath = cfg.stateMountPath; }
                    { name = "pre-start"; mountPath = "/pre-start-src"; }
                  ];
                };

                containers = [{
                  name = "comfyui";
                  image = cfg.images.comfyui;
                  env = [
                    { name = "CLI_ARGS"; value = cliArgs; }
                  ] ++ lib.optional (cfg.gpu.hsaOverrideGfxVersion != "")
                    { name = "HSA_OVERRIDE_GFX_VERSION"; value = cfg.gpu.hsaOverrideGfxVersion; };
                  ports = [{ name = "http"; containerPort = cfg.httpPort; }];
                  # Ready only when ComfyUI actually serves — see readiness.failureThreshold's doc
                  # for why the tolerance is generous: a wake-front holds callers on its waiting
                  # page until this probe passes, so a threshold sized for the average cold start
                  # (rather than the slowest one) shows up as spurious restarts mid-load, not as an
                  # occasional flake.
                  readinessProbe = {
                    httpGet = { path = "/"; port = cfg.httpPort; };
                    periodSeconds = cfg.readiness.periodSeconds;
                    failureThreshold = cfg.readiness.failureThreshold;
                  };
                  resources = {
                    limits = {
                      "${cfg.gpu.deviceResourceName}" = cfg.gpu.deviceResourceCount;
                      memory = cfg.resources.memoryLimit;
                    };
                    requests.memory = cfg.resources.memoryRequest;
                  };
                  # Carried as-is from the originating production deployment (undocumented there
                  # beyond "required" — this generalized module has not independently re-derived
                  # why, only preserved it): without SYS_PTRACE + an unconfined seccomp profile,
                  # this ROCm base image's process fails to initialize the GPU correctly.
                  securityContext = {
                    capabilities.add = [ "SYS_PTRACE" ];
                    seccompProfile.type = "Unconfined";
                  };
                  volumeMounts = [
                    { name = "models"; mountPath = cfg.modelMountPath; }
                    { name = "state"; mountPath = cfg.stateMountPath; }
                    { name = "output"; mountPath = cfg.outputMountPath; }
                  ];
                }];

                volumes = [
                  { name = "models"; hostPath = { path = cfg.modelStoreHostPath; type = "Directory"; }; }
                  { name = "state"; hostPath = { path = cfg.stateHostPath; type = "DirectoryOrCreate"; }; }
                  { name = "output"; hostPath = { path = cfg.outputHostPath; type = "Directory"; }; }
                ] ++ lib.optional (cfg.preStartScript != null) {
                  name = "pre-start";
                  # 0755 (rwxr-xr-x) — belt-and-suspenders only: the init container chmods its OWN
                  # copy explicitly, this just avoids handing out a non-executable file on the
                  # read-only ConfigMap-backed source in the meantime.
                  configMap = { name = "${cfg.appName}-pre-start"; defaultMode = 493; };
                };
              };
            };
            # `replicas` is deliberately OMITTED when `wake.enable` is true — see the comment above
            # the `wake` option group. Rendering `replicas = 1` here as well as `wake.enable`'s
            # labels would make every GitOps sync fight the wake-front's own 0<->1 scaling.
          } // lib.optionalAttrs (!cfg.wake.enable) { replicas = 1; };
        };

        services.comfyui.spec = {
          selector.app = "comfyui";
          type = "ClusterIP";
          ports = [{ name = "http"; port = cfg.httpPort; targetPort = cfg.httpPort; }];
        } // lib.optionalAttrs (cfg.clusterIP != null) { clusterIP = cfg.clusterIP; };
      } // lib.optionalAttrs (cfg.preStartScript != null) {
        configMaps."${cfg.appName}-pre-start".data."pre-start.sh" = cfg.preStartScript;
      };
    };
  };
}
