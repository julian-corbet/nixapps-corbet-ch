# nixapps.advanced.tts — Kokoro and Chatterbox voice synthesis services.
#
# What this recipe knows about tts:
#
#   - Kokoro is a lightweight text-to-speech engine with stock narrator voices,
#     CPU-only (no GPU needed). It is efficient enough (82M parameters) that it
#     runs comfortably on shared CPU. It exposes /health for readiness checks.
#   - Chatterbox is a voice-cloning engine: it takes 5-10 seconds of reference
#     audio and generates new speech in that speaker's voice. It is GPU-backed and
#     shares the GPU pool with other advanced workloads (like ComfyUI). It has no
#     dedicated /health path; the web UI at / is live once models are loaded.
#   - Neither is a public-facing service hit cold from a browser; both are
#     backend engines something else drives. That makes them good candidates for
#     resting at zero replicas between uses, but this recipe does not decide that
#     — scale and wake behaviour belong to the site (CONTRACT.md R8), so no
#     replica count is rendered at all and whatever owns scaling keeps ownership.
#   - Both require persistent model storage. Kokoro models are distributed by the
#     upstream image; Chatterbox stores Hugging Face caches, voice reference
#     samples, and voice clones on the host filesystem.
#   - Chatterbox requires image pull credentials if the image is private. The image
#     may be a private fork (e.g., a ROCm variant) that only you can access.
#
# This recipe lets you enable/disable each service independently. You can run
# just Kokoro (CPU-only, lowest overhead), just Chatterbox (GPU, full voice
# cloning), or both.
{ lib, config, ... }:
let
  cfg = config.nixapps.advanced.tts;
  ttsNamespace = cfg.namespace;
in
{
  options.nixapps.advanced.tts = {
    enable = lib.mkEnableOption "tts - Kokoro and Chatterbox voice services";

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

    kokoro = {
      enable = lib.mkEnableOption "Kokoro, a lightweight CPU-based text-to-speech engine with stock voices";

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/remsky/kokoro-fastapi-cpu:v0.6.0";
        description = "Container image for Kokoro, pinned by tag. CPU-only, no GPU.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8880;
        description = "Port the Kokoro API listens on.";
      };

      modelsPath = lib.mkOption {
        type = lib.types.str;
        description = ''
          Host directory where Kokoro models and voice data are cached.

          Mounted at /app/api/src/models/extra inside the container. The image
          ships with stock voices; this directory is for additional or custom
          voice models if you want to extend beyond the defaults.
        '';
      };
    };

    chatterbox = {
      enable = lib.mkEnableOption "Chatterbox, a GPU-backed voice-cloning engine";

      image = lib.mkOption {
        type = lib.types.str;
        description = ''
          Container image for Chatterbox. **You must supply this**, and no default
          would be honest: upstream Chatterbox publishes no container image, so
          every deployment runs somebody's own build.

          On AMD that build has to be a ROCm one — the published Python packages
          assume CUDA, so a stock image fails at import on an AMD card rather than
          falling back to CPU. Build it yourself, pin what you built by digest,
          and treat the pin as part of the deployment: this model server changes
          behaviour between builds and a floating tag hides that entirely.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8004;
        description = "Port the Chatterbox API listens on.";
      };

      imagePullSecretName = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Name of an existing Secret in this namespace for pulling a private
          Chatterbox image from a registry (e.g., GitHub Container Registry,
          if the image is private).

          Leave empty if the image is public or already available in the
          cluster. The Secret itself is not created by this recipe; you must
          create it separately (e.g., with kubectl create secret docker-registry).
        '';
      };

      hsaOverrideGfxVersion = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          AMD ROCm only: the GFX version to report instead of the one probed from
          the card, e.g. "10.3.0" for RDNA2 consumer parts. ROCm ships kernels for
          a short list of officially supported GFX targets and refuses a card that
          is architecturally compatible but absent from that list; overriding the
          reported version is what makes those cards work at all.

          Null on NVIDIA and on any AMD card ROCm supports directly — the variable
          is then not set at all, which is not the same as setting it empty.
        '';
      };

      # ── The hardware arbiter's contract (CONTRACT.md R9) ──────────────────
      # Chatterbox holds the device while it synthesizes. It declares what it
      # needs and nothing else: it never reads device state, never sets a
      # threshold, never evicts anything. The arbiter is not in this repo.

      deviceResource = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Scheduler resource name your device plugin advertises for the GPU —
          "amd.com/gpu", "nvidia.com/gpu", or whatever yours registers.

          Null when the cluster grants device access some other way. Null on a
          cluster that *does* run a device plugin means this pod schedules and
          then finds no GPU, so if you have a plugin, set this.
        '';
      };

      deviceCount = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = ''
          How many devices to request. One: a single synthesis run occupies the
          card, and asking for more does not make it faster.
        '';
      };

      priorityClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          PriorityClass deciding who yields the device when several workloads want
          it and they do not fit together — relevant here precisely because this
          engine shares a card with other consumers. Only your cluster knows what
          its priority ladder is called, so there is nothing portable to default
          to. Null runs unprioritized.
        '';
      };

      arbiterLabels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "example.com/gpu-managed" = "true";
          "example.com/gpu-engine" = "compute";
        };
        description = ''
          Pod labels by which your GPU arbiter discovers this workload.

          An arbiter that evicts by priority enumerates the pods holding the card
          with a label selector, so a pod carrying none of its labels is invisible
          to it — and a priority class without these is the common
          half-configuration: the scheduler knows the ordering, and the thing that
          acts on it never sees you.

          Empty by default, because the keys belong to the arbiter and not to this
          app. Empty is correct when nothing arbitrates the card.
        '';
      };

      modelsCachePath = lib.mkOption {
        type = lib.types.str;
        description = ''
          Host directory where Chatterbox caches Hugging Face model downloads
          (transformers, voice encoders, synthesis models). This directory is
          large (several GB) and worth placing on fast storage.

          Mounted at /app/hf_cache inside the container.
        '';
      };

      voicesPath = lib.mkOption {
        type = lib.types.str;
        description = ''
          Host directory where voice clones (synthesized speaker profiles) are
          stored. These are generated from reference audio and allow Chatterbox
          to speak in custom voices.

          Mounted at /app/voices inside the container. Directory will be created
          if it does not exist.
        '';
      };

      referenceAudioPath = lib.mkOption {
        type = lib.types.str;
        description = ''
          Host directory where reference audio samples are stored. These are
          the 5-10 second audio clips you provide to train Chatterbox on a
          specific speaker's voice before cloning it.

          Mounted at /app/reference_audio inside the container. Directory will
          be created if it does not exist.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    applications.tts = {
      namespace = ttsNamespace;
      inherit (cfg) createNamespace;
      project = "advanced";

      resources = {
        deployments = lib.mkMerge [
          (lib.mkIf cfg.kokoro.enable {
            kokoro.spec = {
              strategy.type = "Recreate";
              selector.matchLabels.app = "kokoro";
              template = {
                metadata.labels.app = "kokoro";
                spec = {
                  containers.kokoro = {
                    name = "kokoro";
                    image = cfg.kokoro.image;
                    ports.http = {
                      name = "http";
                      containerPort = cfg.kokoro.port;
                    };
                    readinessProbe = {
                      httpGet = {
                        path = "/health";
                        port = cfg.kokoro.port;
                      };
                      periodSeconds = 3;
                      failureThreshold = 60;
                    };
                    volumeMounts.models = {
                      name = "models";
                      mountPath = "/app/api/src/models/extra";
                    };
                  };
                  volumes.models = {
                    name = "models";
                    hostPath = {
                      path = cfg.kokoro.modelsPath;
                      type = "Directory";
                    };
                  };
                };
              };
            };
          })
          (lib.mkIf cfg.chatterbox.enable {
            chatterbox.spec = {
              # Recreate, not rolling: a rolling update would briefly run both old
              # and new pod together, both with GPU access, which breaks the single-writer
              # assumption (the GPU device is exclusive to one pod at a time).
              strategy.type = "Recreate";
              selector.matchLabels.app = "chatterbox";
              template = {
                # The selector stays minimal on purpose — it is immutable after
                # creation, so the arbiter's labels go on the pod only, where they
                # can still be changed.
                metadata.labels = { app = "chatterbox"; } // cfg.chatterbox.arbiterLabels;
                spec = {
                  imagePullSecrets = lib.optional (cfg.chatterbox.imagePullSecretName != "") {
                    name = cfg.chatterbox.imagePullSecretName;
                  };
                  # Half the arbiter contract: the order in which holders yield.
                  # The other half is the device request on the container below.
                  priorityClassName = cfg.chatterbox.priorityClassName;
                  containers.chatterbox = {
                    name = "chatterbox";
                    image = cfg.chatterbox.image;
                    # Only set on a card that needs it: an empty value is not the
                    # same as an unset one, and ROCm reads it whenever it exists.
                    env = lib.optionalAttrs (cfg.chatterbox.hsaOverrideGfxVersion != null) {
                      HSA_OVERRIDE_GFX_VERSION = {
                        name = "HSA_OVERRIDE_GFX_VERSION";
                        value = cfg.chatterbox.hsaOverrideGfxVersion;
                      };
                    };
                    # The other half of the arbiter contract: ask for the device by
                    # the name the plugin advertises. Not capacity sizing — this is
                    # how the scheduler knows the card is taken (CONTRACT.md R8/R9).
                    resources = lib.optionalAttrs (cfg.chatterbox.deviceResource != null) {
                      limits.${cfg.chatterbox.deviceResource} = cfg.chatterbox.deviceCount;
                    };
                    ports.http = {
                      name = "http";
                      containerPort = cfg.chatterbox.port;
                    };
                    # Chatterbox has no dedicated /health endpoint. The root path serves
                    # the web UI and is live once models are loaded (confirmed by checking
                    # the real deployment: / returns 200, /health returns 404).
                    # Patient probe: cold start includes loading transformer models from
                    # disk (several seconds), plus potential GPU contention with other
                    # advanced workloads. Better to wait than to kill it mid-startup.
                    readinessProbe = {
                      httpGet = {
                        path = "/";
                        port = cfg.chatterbox.port;
                      };
                      periodSeconds = 5;
                      failureThreshold = 120;
                    };
                    securityContext = {
                      capabilities.add = [ "SYS_PTRACE" ];
                      seccompProfile.type = "Unconfined";
                    };
                    volumeMounts.models = {
                      name = "models";
                      mountPath = "/app/hf_cache";
                    };
                    volumeMounts.voices = {
                      name = "voices";
                      mountPath = "/app/voices";
                    };
                    volumeMounts.reference-audio = {
                      name = "reference-audio";
                      mountPath = "/app/reference_audio";
                    };
                  };
                  volumes.models = {
                    name = "models";
                    hostPath = {
                      path = cfg.chatterbox.modelsCachePath;
                      type = "DirectoryOrCreate";
                    };
                  };
                  volumes.voices = {
                    name = "voices";
                    hostPath = {
                      path = cfg.chatterbox.voicesPath;
                      type = "DirectoryOrCreate";
                    };
                  };
                  volumes.reference-audio = {
                    name = "reference-audio";
                    hostPath = {
                      path = cfg.chatterbox.referenceAudioPath;
                      type = "DirectoryOrCreate";
                    };
                  };
                };
              };
            };
          })
        ];

        services = lib.mkMerge [
          (lib.mkIf cfg.kokoro.enable {
            kokoro.spec = {
              selector.app = "kokoro";
              ports.http = {
                port = cfg.kokoro.port;
                targetPort = cfg.kokoro.port;
              };
            };
          })
          (lib.mkIf cfg.chatterbox.enable {
            chatterbox.spec = {
              selector.app = "chatterbox";
              ports.http = {
                port = cfg.chatterbox.port;
                targetPort = cfg.chatterbox.port;
              };
            };
          })
        ];
      };
    };
  };
}
