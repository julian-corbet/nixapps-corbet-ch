# tts — the second nixapps tenant (see apps/README.md), and a deliberately DIFFERENT shape from
# comfyui: not one Deployment but TWO, independently enabled, sharing one namespace/Argo
# application —
#
#   - kokoro: stock narrator-voice text-to-speech. CPU-only, always schedulable, no GPU option
#     surface at all (not even an unused one) — small enough to run in real time on CPU per
#     upstream's own benchmarks, so it never needs the shared card.
#   - chatterbox: voice-CLONING text-to-speech (a short reference clip in, a cloned voice out).
#     GPU-backed, and OPTIONAL — it carries the identical three-line nixgpu contract as comfyui
#     (priorityClassName, `strategy: Recreate`, a device-resource token) and never thinks about
#     the card again. See nixgpu CONTRACT.md for what that contract guarantees it in return
#     (B1/B2/B8: co-residence when it fits, priority-ordered yield when it doesn't, decided by
#     live measured VRAM, never a card reset).
#
# GPU DEVICE INFRA (device tokens, priority ladder, pressure watcher) is a separate concern,
# shipped by the sibling nixgpu project — chatterbox only *consumes* that contract, it does not
# provide it.
#
# SCALE-TO-ZERO: A THIRD PATTERN, NOT A VARIANT OF THE OTHER TWO. comfyui is Sablier-fronted (a
# waiting page in front of a public URL); a KEDA HTTPScaledObject front is the other common shape
# elsewhere in this project family. Neither applies here. Both Deployments in this module simply
# default to `replicas: 0` and are scaled 1<->0 by an EXTERNAL operator or workflow script issuing
# a plain `kubectl scale` — no interceptor, no waiting page, no front of any kind. That is a
# deliberate design choice, not a missing feature: these are backend tools an internal pipeline
# calls into (generate narration, clone a voice), never a public URL a browser lands on cold. With
# no anonymous browser caller in the loop, there is no one to show a "warming up" page to — the
# caller IS the thing that already knows to wait for the pod to go Ready. If you came here looking
# for the wiring that scales these Deployments up and down, it does not belong in this module at
# all; that is the operator/workflow's job, not this tenant's.
#
# CRITICAL GITOPS PREREQUISITE — read before wiring any operator script to this module: unlike a
# Sablier-fronted tenant (where `replicas` is omitted from the manifest entirely so the front can
# own it out-of-band, free of any GitOps opinion), `replicas` HERE is an ordinary, git-tracked
# field defaulting to 0. An external `kubectl scale --replicas=1` is therefore live drift against
# the declared desired state the instant it runs. If your GitOps controller reconciles this
# Application with self-healing enabled and nothing tells it to ignore `spec.replicas` on these
# Deployments (a `spec.ignoreDifferences` rule for `apps/Deployment` — cluster-wide, or scoped to
# this one Application — or simply not self-healing this Application), the very next reconcile
# silently scales the pod straight back to 0. This does not look like a GitOps error: there is no
# crash, no sync failure, no obvious signal anywhere in this module's own manifests. It looks like
# "the operator script scaled it up, and a few minutes later it was back down for no reason" —
# easy to misdiagnose as a bug in the scale script itself when the real cause is GitOps quietly
# winning a fight the scale script never knew it was in. Get the ignore-diff (or sync-mode) story
# straight on your own cluster BEFORE pointing any automation at `kubectl scale` on these
# Deployments.
#
# HEALTH-PROBE LESSON (chatterbox, generalizes past this one server): the reference chatterbox
# image ships with NO dedicated health endpoint. Its root path ("/") serves the web UI, and that
# UI only starts responding once the model has actually finished loading — so this module probes
# "/", not an assumed "/health" (confirmed against the real server: "/health" 404s the whole time,
# "/" 200s only once truly ready). Guessing wrong here fails in two different, equally unpleasant
# directions: assume a health path that always 404s and the pod never goes Ready at all; assume
# one that 200s unconditionally (a liveness-only stub, a static file, a proxy default page) and the
# pod goes "Ready" the instant the process starts, long before the model is actually usable, and
# every request that lands during the gap fails against a technically-Ready pod. Check what your
# own image really serves, at rest, before trusting a path name alone.
#
# STORAGE LESSON (chatterbox's three required host paths, `hfCacheHostPath` / `voicesHostPath` /
# `referenceAudioHostPath`): these are not interchangeable and must not be merged into one mount
# just because the container happens to read all three. `hfCacheHostPath` is a DERIVED, disposable
# download cache — wipe it and the container simply re-downloads on next start. The other two hold
# irreplaceable USER DATA: saved voice presets and the reference audio clips fed to a cloning
# request. Treating the cache path with the same caution you'd give the other two costs nothing;
# treating the other two with the "it's just a cache, it'll come back" carelessness that's fine for
# the first one loses real recordings that do not come back.
#
# Status: extracted from a production system where this exact shape runs live — two independently
# scaled-to-zero Deployments, one CPU-only and always on standby, one GPU-backed and driven by the
# same external workflow tooling that also drives comfyui and the shared LLM broker on the same
# card. This generalized module has not yet been re-verified live in a fresh cluster — re-verify
# before trusting it there.
{ lib, config, ... }:
let
  cfg = config.nixapps.tts;

  # Fixed by the kokoro-fastapi image's own directory convention (where it scans for voice models
  # beyond the stock pack baked into the image) — not an option. Exposing this as a configurable
  # knob would only invite someone to "fix" it into a value the image silently never reads.
  kokoroModelMountPath = "/app/api/src/models/extra";

  # Same reasoning for chatterbox's three mount points: fixed by devnen/Chatterbox-TTS-Server's own
  # container layout (which the ROCm rebuild `chatterbox.image` defaults to does not change), not a
  # convention of this module.
  chatterboxHfCacheMountPath = "/app/hf_cache";
  chatterboxVoicesMountPath = "/app/voices";
  chatterboxReferenceAudioMountPath = "/app/reference_audio";

  kokoroDeployment = {
    metadata.labels.app = "kokoro";
    spec = {
      replicas = cfg.kokoro.replicas;
      # strategy: Recreate even though this Deployment is CPU-only and holds no GPU slot to
      # protect. The reason is different from chatterbox's (below): this tenant's replica count is
      # toggled externally (see the module-level comment on scale-to-zero above), and Recreate
      # keeps "at most one kokoro pod exists at any moment" true regardless of whether the pod
      # change came from a version rollout or from the external 0<->1 toggle — a surging
      # RollingUpdate pod would otherwise transiently coexist with whichever pod the external
      # toggle script is watching for readiness, which is exactly the kind of ambiguity an
      # externally-driven scale-to-zero pattern should not have to reason about.
      strategy.type = "Recreate";
      selector.matchLabels.app = "kokoro";
      template = {
        metadata.labels.app = "kokoro";
        spec.containers = [{
          name = "kokoro";
          image = cfg.kokoro.image;
          ports = [{ containerPort = cfg.kokoro.port; }];
          readinessProbe = {
            httpGet = { path = cfg.kokoro.readinessProbe.path; port = cfg.kokoro.port; };
            periodSeconds = cfg.kokoro.readinessProbe.periodSeconds;
            failureThreshold = cfg.kokoro.readinessProbe.failureThreshold;
          };
          resources = {
            requests = {
              cpu = cfg.kokoro.resources.requests.cpu;
              memory = cfg.kokoro.resources.requests.memory;
            };
            limits.memory = cfg.kokoro.resources.limits.memory;
          };
          volumeMounts = [{ name = "models"; mountPath = kokoroModelMountPath; }];
        }];
        spec.volumes = [{
          name = "models";
          hostPath = { path = cfg.kokoro.modelStoreHostPath; type = "Directory"; };
        }];
      };
    };
  };

  kokoroService.spec = {
    selector.app = "kokoro";
    ports = [{ port = cfg.kokoro.port; targetPort = cfg.kokoro.port; }];
  };

  chatterboxDeployment = {
    metadata.labels.app = "chatterbox";
    spec = {
      replicas = cfg.chatterbox.replicas;
      # strategy: Recreate — this pod holds the ONE compute device-resource slot
      # (gpu.deviceResourceCount, default 1); a surging new pod couldn't schedule anyway while the
      # old one still holds it, so Recreate tears the old pod down first rather than leaving a new
      # one stuck Pending. Same rationale as comfyui and nixllm's broker.
      strategy.type = "Recreate";
      selector.matchLabels.app = "chatterbox";
      template = {
        metadata.labels = {
          app = "chatterbox";
          "${cfg.chatterbox.gpu.managedLabelKey}" = "true";
          "${cfg.chatterbox.gpu.engineLabelKey}" = cfg.chatterbox.gpu.engineLabelValue;
        };
        spec = {
          nodeSelector = cfg.chatterbox.gpu.nodeSelector;
          priorityClassName = cfg.chatterbox.gpu.priorityClassName;
          imagePullSecrets = lib.optional (cfg.chatterbox.existingImagePullSecretName != null)
            { name = cfg.chatterbox.existingImagePullSecretName; };
          containers = [{
            name = "chatterbox";
            image = cfg.chatterbox.image;
            env = lib.optional (cfg.chatterbox.gpu.hsaOverrideGfxVersion != "")
              { name = "HSA_OVERRIDE_GFX_VERSION"; value = cfg.chatterbox.gpu.hsaOverrideGfxVersion; };
            ports = [{ containerPort = cfg.chatterbox.port; }];
            # See the module-level HEALTH-PROBE LESSON comment above for why this probes "/" and
            # why failureThreshold defaults so high: a cold model load with no page-cache warmth
            # (the common case right after this Deployment is scaled up from 0) can take several
            # minutes, and the whole point of scaling to zero between uses is that most starts ARE
            # that cold case, not the exception.
            readinessProbe = {
              httpGet = { path = cfg.chatterbox.readinessProbe.path; port = cfg.chatterbox.port; };
              periodSeconds = cfg.chatterbox.readinessProbe.periodSeconds;
              failureThreshold = cfg.chatterbox.readinessProbe.failureThreshold;
            };
            resources = {
              limits = {
                "${cfg.chatterbox.gpu.deviceResourceName}" = cfg.chatterbox.gpu.deviceResourceCount;
                memory = cfg.chatterbox.resources.limits.memory;
              };
              requests.memory = cfg.chatterbox.resources.requests.memory;
            };
            # Carried as-is from the originating production deployment (undocumented there beyond
            # "required" — this generalized module has not independently re-derived why, only
            # preserved it): without SYS_PTRACE + an unconfined seccomp profile, this ROCm image's
            # process fails to initialize the GPU correctly. Same note as comfyui and nixllm's
            # broker — evidently a recurring trait of ROCm containers on this family of cards, not
            # specific to any one of them.
            securityContext = {
              capabilities.add = [ "SYS_PTRACE" ];
              seccompProfile.type = "Unconfined";
            };
            volumeMounts = [
              { name = "hf-cache"; mountPath = chatterboxHfCacheMountPath; }
              { name = "voices"; mountPath = chatterboxVoicesMountPath; }
              { name = "reference-audio"; mountPath = chatterboxReferenceAudioMountPath; }
            ];
          }];
          # DirectoryOrCreate, not Directory: unlike kokoro's model store (an existing directory
          # you point this at), a fresh chatterbox deployment's hf_cache/voices/reference_audio
          # trees plausibly don't exist yet on a new node — the container populates hf_cache itself
          # on first run, and an operator adds voices/reference_audio content afterwards. See the
          # module-level STORAGE LESSON comment for why these stay three separate host paths rather
          # than one shared root.
          volumes = [
            {
              name = "hf-cache";
              hostPath = { path = cfg.chatterbox.hfCacheHostPath; type = "DirectoryOrCreate"; };
            }
            {
              name = "voices";
              hostPath = { path = cfg.chatterbox.voicesHostPath; type = "DirectoryOrCreate"; };
            }
            {
              name = "reference-audio";
              hostPath = {
                path = cfg.chatterbox.referenceAudioHostPath;
                type = "DirectoryOrCreate";
              };
            }
          ];
        };
      };
    };
  };

  chatterboxService.spec = {
    selector.app = "chatterbox";
    ports = [{ port = cfg.chatterbox.port; targetPort = cfg.chatterbox.port; }];
  };
in
{
  options.nixapps.tts = {
    enable = lib.mkEnableOption "the tts voice tier (Kokoro CPU narration + optional Chatterbox GPU voice cloning)";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "tts";
      description = "Namespace both Deployments (whichever are enabled) and their Services run in.";
    };

    appName = lib.mkOption {
      type = lib.types.str;
      default = "tts";
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
        nixidy AppProject this application is filed under. Kokoro alone needs no GPU-tier
        permissions, but chatterbox (if enabled) is a direct GPU consumer sharing one application
        with it — map this to whatever tier your Argo CD AppProject scheme uses for apps that touch
        the GPU directly, the same tier comfyui and nixllm's broker file under, rather than the
        tier for plain CPU-only workloads.
      '';
    };

    kokoro = {
      # Plain mkOption (not mkEnableOption, which always defaults to false): this tenant is
      # genuinely different from chatterbox and defaults ON. It is CPU-only, needs no GPU, no
      # private image, and no pull secret — the only thing it requires is modelStoreHostPath, which
      # has no default for the same reason every hostPath option in this family doesn't (every
      # deployment's storage layout differs). Turning `nixapps.tts.enable` on without an opinion on
      # kokoro specifically should give you the tenant that costs nothing extra to run.
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to render the Kokoro (CPU narrator-voice) Deployment and Service.";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/remsky/kokoro-fastapi-cpu:v0.6.0";
        description = ''
          Kokoro image. Pinned to a version tag, never `:latest` — a moving tag can change crash
          behavior under you between deploys with nothing to diff or review before it happens.
          Upstream benchmarks this model as real-time even on CPU (82M parameters), which is the
          whole reason this tenant needs no GPU option surface at all.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8880;
        description = "Port Kokoro listens on inside the pod, and that the Service targets.";
      };

      replicas = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = ''
          Desired replica count. Defaults to 0 — see the module-level scale-to-zero comment for the
          full rationale and, critically, the GitOps prerequisite for this default to survive
          contact with an external `kubectl scale` toggle. A Deployment resting at 0/0 between uses
          is this tenant's normal steady state, not a sign anything is broken or missing.
        '';
      };

      modelStoreHostPath = lib.mkOption {
        type = lib.types.str;
        example = "/srv/tts/kokoro-models";
        description = ''
          Absolute host filesystem path to a directory of EXTRA voice models, on whatever node the
          pod is scheduled to. REQUIRED, no default — every real deployment's storage layout is
          different, and any default here would silently point at a path that doesn't exist on your
          node. This is additive to, not a replacement for, the stock voice pack already baked into
          the image: point it at an empty directory if you have nothing to add yet, rather than
          skipping the mount — Kokoro's own image expects something mounted at its extra-models path
          regardless of whether it currently holds anything.
        '';
      };

      resources = {
        requests = {
          cpu = lib.mkOption {
            type = lib.types.str;
            default = "500m";
            description = "Pod CPU request.";
          };

          memory = lib.mkOption {
            type = lib.types.str;
            default = "1Gi";
            description = "Pod memory request.";
          };
        };

        limits.memory = lib.mkOption {
          type = lib.types.str;
          default = "2Gi";
          description = "Pod memory limit.";
        };
      };

      readinessProbe = {
        path = lib.mkOption {
          type = lib.types.str;
          default = "/health";
          description = ''
            HTTP path polled for readiness. Kokoro's reference image ships a real dedicated health
            endpoint at this path — unlike chatterbox below, no root-path workaround is needed here.
          '';
        };

        periodSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 3;
          description = "How often the readiness probe polls once startup begins.";
        };

        failureThreshold = lib.mkOption {
          type = lib.types.ints.positive;
          default = 60;
          description = ''
            Consecutive probe failures tolerated before the pod is considered failed. At the default
            `periodSeconds` this is 3 minutes of grace — generous even for a "real-time on CPU"
            model, because that benchmark describes steady-state inference, not cold weight-loading
            right after a scale-up from 0.
          '';
        };
      };
    };

    chatterbox = {
      enable = lib.mkEnableOption ''
        the Chatterbox (GPU voice-cloning) Deployment and Service. Opt-in and off by default,
        unlike kokoro: this tenant needs the shared GPU, a private image, and three required host
        paths with no defaults — a materially heavier bar than "just point it at a directory"
      '';

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/julian-corbet/chatterbox-tts-rocm:latest";
        description = ''
          Chatterbox image. Upstream's own Dockerfile (devnen/Chatterbox-TTS-Server) hardcodes
          CUDA; this default points at a ROCm-patched rebuild instead (built by the sibling
          chatterbox-tts-corbet-ch repo). `:latest` here is only a bootstrap-friendly starting
          point — pin a digest once you've validated a build, the same discipline `kokoro.image`
          already follows above: a moving tag is a real production incident waiting to happen, not
          a hypothetical one. Point this at your own image if you use a different Chatterbox
          distribution or backend — in which case also revisit `gpu.hsaOverrideGfxVersion` and the
          ROCm-specific `securityContext` this module sets, which may not apply.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8004;
        description = "Port Chatterbox listens on inside the pod, and that the Service targets.";
      };

      replicas = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = ''
          Desired replica count. Defaults to 0, identically to `kokoro.replicas` — see that option
          and the module-level scale-to-zero comment for the full rationale. Never set this above 1:
          a device-resource limit of `gpu.deviceResourceCount` per pod means a second replica would
          simply fail to schedule once the first holds the card's only slot for this tenant.
        '';
      };

      existingImagePullSecretName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Name of an EXISTING `kubernetes.io/dockerconfigjson` Secret, in this application's
          namespace, granting pull access to `image` above. This module does not create the
          Secret — bring your own via whatever mechanism your cluster uses (sealed-secrets,
          external-secrets, a plain manually-applied Secret). Needed because the reference image is
          a private ghcr package; leave this `null` if you point `image` at a public one instead, in
          which case no `imagePullSecrets` entry is rendered at all.
        '';
      };

      hfCacheHostPath = lib.mkOption {
        type = lib.types.str;
        example = "/srv/tts/chatterbox/hf-cache";
        description = ''
          Absolute host filesystem path for Chatterbox's own HuggingFace download cache. REQUIRED,
          no default, same reasoning as every hostPath option in this family. Unlike the two paths
          below, this one is DERIVED and disposable — see the module-level STORAGE LESSON comment:
          wipe it and the container simply re-downloads on next start. Created on first use if
          missing.
        '';
      };

      voicesHostPath = lib.mkOption {
        type = lib.types.str;
        example = "/srv/tts/chatterbox/voices";
        description = ''
          Absolute host filesystem path for saved voice PRESETS used for cloning. REQUIRED, no
          default. Irreplaceable user data — see the module-level STORAGE LESSON comment. Created on
          first use if missing, but do not treat an empty/missing directory here as harmless the way
          an empty `hfCacheHostPath` is: it just means you have not saved any voice presets yet, not
          that nothing was lost.
        '';
      };

      referenceAudioHostPath = lib.mkOption {
        type = lib.types.str;
        example = "/srv/tts/chatterbox/reference-audio";
        description = ''
          Absolute host filesystem path for user-supplied reference audio clips (a 5-10s sample)
          fed to a cloning request. REQUIRED, no default. Irreplaceable user data, same caution as
          `voicesHostPath` above — kept as a separate path rather than merged into it because
          upstream's own container layout expects them at two distinct mount points, and separating
          them on the host mirrors that boundary instead of blurring it.
        '';
      };

      resources = {
        requests.memory = lib.mkOption {
          type = lib.types.str;
          default = "2Gi";
          description = "Pod memory request. Ordinary system RAM, separate from the VRAM the device-resource token below gates.";
        };

        limits.memory = lib.mkOption {
          type = lib.types.str;
          default = "12Gi";
          description = ''
            Pod memory limit. Voice cloning stages the HuggingFace model and audio buffers through
            system RAM around the VRAM-bound steps, so a too-tight limit OOM-kills the pod even when
            the GPU itself had headroom.
          '';
        };
      };

      readinessProbe = {
        path = lib.mkOption {
          type = lib.types.str;
          default = "/";
          description = ''
            HTTP path polled for readiness. See the module-level HEALTH-PROBE LESSON comment: this
            reference image has no dedicated health endpoint, and root ("/") is the path confirmed
            live to 200 only once the model has actually finished loading. Verify what your own
            image serves before assuming this still applies if you point `image` elsewhere.
          '';
        };

        periodSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 5;
          description = "How often the readiness probe polls once startup begins.";
        };

        failureThreshold = lib.mkOption {
          type = lib.types.ints.positive;
          default = 120;
          description = ''
            Consecutive probe failures tolerated before the pod is considered failed. At the default
            `periodSeconds` this is 10 minutes of grace, sized for a genuinely cold model load (no
            page-cache warmth) right after a scale-up from 0 — the common case for this tenant, not
            the exception, precisely because it spends most of its life at 0 replicas between uses.
          '';
        };
      };

      gpu = {
        priorityClassName = lib.mkOption {
          type = lib.types.str;
          default = "gpu-besteffort";
          description = ''
            PriorityClass for the pod. Defaults to the nixgpu ladder's best-effort rung (see
            nixgpu's priority-ladder module) — same rung as comfyui, and for the same reason:
            an on-demand backend tool nobody is actively waiting on with low-latency expectations
            is exactly what best-effort is for — first to yield under VRAM pressure (nixgpu
            CONTRACT.md B2), with no starvation protection.
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
            exact resource name via squat/generic-device-plugin). This is the ONE contract token
            that makes chatterbox a direct GPU consumer, co-residing with other tenants requesting
            the same lane up to the plugin's own concurrency ceiling.
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
            watcher that reclaims VRAM by priority). Set to "true" on the pod template. The default
            is a placeholder domain — rename it to match whatever label domain the rest of your
            nixgpu deployment uses (it must agree with that deployment's own `managedLabelKey`, e.g.
            the pressure-watcher module's option of the same name).
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
            Engine identifier for the label above. Voice cloning uses the compute engine (as opposed
            to a media/video-codec engine, which runs on separate silicon and is unaffected by
            compute-side pressure — see nixgpu CONTRACT.md B3).
          '';
        };

        hsaOverrideGfxVersion = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            `HSA_OVERRIDE_GFX_VERSION` passed to the container. ROCm ships official support for a
            fixed list of GPU architectures; this override tells ROCm to treat the card as the
            nearest supported architecture.

            DEFAULTS TO "" — the env var is omitted entirely, which is correct for any card ROCm
            supports natively. It is deliberately NOT defaulted to a real architecture value: a
            concrete default is only ever right for the one card its author happened to own, and
            silently applying someone else's GFX override to your card produces confusing ROCm
            misbehaviour rather than an honest error. Look your own card up in ROCm's supported-GPU
            list and set it explicitly if it needs one — e.g. an RDNA2 consumer card wants "10.3.0".
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${cfg.appName} = {
      namespace = cfg.namespace;
      createNamespace = cfg.createNamespace;
      project = cfg.project;

      # `deployments`/`services` are each built as ONE attrset, merging per-tenant contributions at
      # the leaf (the individual app-name key), NOT by `//`-merging two whole `{ deployments = ...;
      # services = ...; }` bundles together. That distinction actually matters here, unlike in a
      # single-tenant module: kokoro and chatterbox are each independently optional, but BOTH
      # contribute to the SAME two top-level keys (deployments, services) rather than disjoint
      # ones — a naive top-level `//` between "kokoro's bundle" and "chatterbox's bundle" would let
      # whichever bundle is merged second silently replace the first's `deployments` (and
      # `services`) key wholesale, not add to it, dropping that tenant's manifests entirely
      # whenever both are enabled together.
      resources = {
        deployments =
          lib.optionalAttrs cfg.kokoro.enable { kokoro = kokoroDeployment; }
          // lib.optionalAttrs cfg.chatterbox.enable { chatterbox = chatterboxDeployment; };

        services =
          lib.optionalAttrs cfg.kokoro.enable { kokoro = kokoroService; }
          // lib.optionalAttrs cfg.chatterbox.enable { chatterbox = chatterboxService; };
      };
    };
  };
}
