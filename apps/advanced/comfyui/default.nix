# nixapps.advanced.comfyui — ComfyUI, a node-based UI for Stable Diffusion and other image models.
#
# What this recipe knows about ComfyUI:
#
#   - It is a GPU-direct consumer (direct GPU access, single-instance workload).
#     There is no sense in running two replicas: they share the one GPU.
#   - It runs on container startup a pre-start hook that installs Python dependencies
#     for all custom nodes (their requirements.txt files), so you can git-clone
#     custom nodes into custom_nodes/ and they Just Work.
#   - The pre-start hook also handles a ROCm-specific gotcha: several popular custom
#     nodes (PuLID, InstantID, etc.) unconditionally declare onnxruntime-gpu in
#     their requirements.txt, which is CUDA-only. On ROCm hardware, this breaks their
#     imports. The hook detects and removes it, replacing with the CPU fallback.
#   - It serves HTTP on port 8188 by default. It mounts three directories:
#     - Models (for Stable Diffusion checkpoints and embeddings)
#     - Root (for ComfyUI's own data: histories, custom nodes, node configs)
#     - Output (where rendered images land)
#   - The readiness probe is patient. It needs time to load models on startup and
#     may be blocked by GPU contention with other advanced tenants. Cold startup
#     with model load takes a few seconds; contention means waiting for another app
#     to release the GPU.
#   - The strategy is Recreate: a rolling update would briefly run old and new pods
#     together, both with the GPU card open, which breaks the single-writer assumption.
#
# This recipe exposes per-app configuration. ComfyUI's CLI args, GPU-specific
# environment tuning, and data paths are all options you customize at deploy time.
{ lib, config, ... }:
let
  cfg = config.nixapps.advanced.comfyui;
  name = "comfyui";
in
{
  options.nixapps.advanced.comfyui = {
    enable = lib.mkEnableOption "ComfyUI, a node-based image generation UI";

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
      default = "yanwk/comfyui-boot@sha256:7c64b5765f649536887f7cfad5f3b5559d1ec81547974e5ed325834782b04d61";
      description = ''
        Container image, pinned by digest.

        ComfyUI uses compute resources (GPU, CPU, disk) during startup: loading
        models, compiling shaders, discovering extensions. A floating tag can
        hide a breaking upgrade in the history. Pin it, and move the pin
        deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8188;
      description = "Port the ComfyUI web UI listens on.";
    };

    cliArgs = lib.mkOption {
      type = lib.types.str;
      default = "--listen 0.0.0.0 --output-directory /images-out";
      description = ''
        Command-line arguments passed to ComfyUI on startup.

        --listen 0.0.0.0 makes it accessible from the network.
        --output-directory /images-out points rendered images to the mounted
        images volume (which you map to persistent storage).
        Other options: --preview-method auto (for web previews), --cpu-mode
        (force CPU even with GPU present), see ComfyUI --help for full list.
      '';
    };

    hsaOverrideGfxVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        AMD ROCm only: the GFX version to report instead of the one probed from
        the card, e.g. "10.3.0" for RDNA2 consumer parts. ROCm ships kernels for
        a short list of officially supported GFX targets, and a card that is
        architecturally compatible but not on that list is refused outright —
        overriding the reported version is what makes those cards work at all.

        Null on NVIDIA, and on any AMD card ROCm supports directly; the variable
        is then not set. If you need it and guess wrong, the runtime either
        refuses to start or miscompiles kernels, so check your GFX target rather
        than trying values.
      '';
    };

    # ── The hardware arbiter's contract (CONTRACT.md R9) ────────────────────
    # This app holds the whole device while it runs. It declares what it needs
    # and nothing else: it never reads device state, never sets a threshold, and
    # never evicts anything. Whatever arbitrates the device is not in this repo.

    deviceResource = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Scheduler resource name your device plugin advertises for the GPU —
        "amd.com/gpu", "nvidia.com/gpu", or whatever yours registers.

        Null when the cluster grants device access some other way (a host device
        mount, a dedicated node). Note that null on a cluster which *does* run a
        device plugin means this pod schedules successfully and then finds no
        GPU — so if you have a plugin, set this.
      '';
    };

    deviceCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = ''
        How many devices to request. One: ComfyUI takes the whole card for the
        duration of a render, and asking for more does not make it faster.
      '';
    };

    priorityClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        PriorityClass deciding who yields the device when more than one workload
        wants it and they do not fit together. Only your cluster knows what its
        priority ladder is called, so there is nothing portable to default to.

        Null runs unprioritized — fine when this is the only thing on the card,
        wrong the moment it is not.
      '';
    };

    modelsPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory where Stable Diffusion checkpoints, VAEs, embeddings,
        and other models live. This is mounted into the container at
        /root/ComfyUI/models and is the conventional place ComfyUI looks for
        model files.

        Large binary files (checkpoints are typically 2–10 GB each): worth
        putting on storage tuned for sequential access rather than random I/O.
      '';
    };

    rootPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory where ComfyUI stores its state: histories, loaded node
        configs, custom node git clones, and per-session data.

        Mounted at /root inside the container. If this directory does not exist
        on the host, the container creates it on first startup.
      '';
    };

    imagesPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory where ComfyUI writes rendered images (the output of the
        generation graph). Mounted at /images-out inside the container.

        The --output-directory /images-out CLI arg points ComfyUI to this mount.
        Image output is sequential (one file per render); worth putting on storage
        tuned for that (not random I/O).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "advanced";

      resources = {
        configMaps.comfyui-pre-start.data = {
          "pre-start.sh" = ''
            #!/bin/bash
            set -eu
            echo "[INFO] Installing custom node Python requirements..."
            for req in /root/ComfyUI/custom_nodes/*/requirements.txt; do
              [ -f "$req" ] || continue
              echo "[INFO]   $req"
              # Non-fatal per-node: a flaky/optional dependency in one custom node's requirements.txt must
              # not take down ComfyUI startup for every other tenant using this same pod.
              pip install --no-cache-dir -r "$req" || echo "[WARN] failed installing $req"
            done
            # onnxruntime-gpu is CUDA-only (needs libcudart.so.13) and unconditionally listed by several
            # common custom nodes (PuLID_ComfyUI, ComfyUI_InstantID, ...) for any x86_64 Linux box — their
            # requirements.txt markers check platform_machine, never NVIDIA vs AMD. On a ROCm box it
            # silently clobbers a working plain `onnxruntime` install and breaks every node that imports
            # insightface/onnxruntime. Never let it survive the loop above, regardless of
            # which node's requirements.txt pulled it in.
            if pip show onnxruntime-gpu >/dev/null 2>&1; then
              echo "[INFO] Removing incompatible onnxruntime-gpu (CUDA-only, this is ROCm)..."
              pip uninstall -y onnxruntime-gpu
              pip install --no-cache-dir --force-reinstall --no-deps onnxruntime
            fi
          '';
        };

        deployments.${name}.spec = {
          # Recreate, not rolling. A rolling update briefly runs the old and new
          # pod together, both holding the GPU open, and ComfyUI expects to be its
          # single writer (GPU device access is exclusive).
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              # Half the arbiter contract: the order in which holders yield.
              # The other half is the device request on the container below.
              priorityClassName = cfg.priorityClassName;

              initContainers.pre-start-install = {
                name = "pre-start-install";
                image = "busybox:stable@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f";
                command = [ "sh" "-c" "mkdir -p /root/user-scripts && cp /pre-start-src/pre-start.sh /root/user-scripts/pre-start.sh && chmod +x /root/user-scripts/pre-start.sh" ];
                volumeMounts.root = {
                  name = "root";
                  mountPath = "/root";
                };
                volumeMounts.pre-start = {
                  name = "pre-start";
                  mountPath = "/pre-start-src";
                };
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                env = {
                  CLI_ARGS = {
                    name = "CLI_ARGS";
                    value = cfg.cliArgs;
                  };
                }
                # Only set on a card that needs it: an empty value is not the same
                # as an unset one, and ROCm reads the variable whenever it exists.
                // lib.optionalAttrs (cfg.hsaOverrideGfxVersion != null) {
                  HSA_OVERRIDE_GFX_VERSION = {
                    name = "HSA_OVERRIDE_GFX_VERSION";
                    value = cfg.hsaOverrideGfxVersion;
                  };
                };
                # The other half of the arbiter contract: ask for the device by
                # the name the plugin advertises. Not capacity sizing — this is
                # how the scheduler knows the card is taken (CONTRACT.md R8/R9).
                resources = lib.optionalAttrs (cfg.deviceResource != null) {
                  limits.${cfg.deviceResource} = cfg.deviceCount;
                };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                # Patient probe. Needs time to load models (a few seconds from cache),
                # may be blocked by GPU contention with other advanced workloads. Better
                # to wait than to declare the pod dead mid-startup.
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 5;
                  failureThreshold = 180;
                };
                securityContext = {
                  capabilities.add = [ "SYS_PTRACE" ];
                  seccompProfile.type = "Unconfined";
                };
                volumeMounts.models = {
                  name = "models";
                  mountPath = "/root/ComfyUI/models";
                };
                volumeMounts.root = {
                  name = "root";
                  mountPath = "/root";
                };
                volumeMounts.images = {
                  name = "images-generated";
                  mountPath = "/images-out";
                };
              };
              volumes.models = {
                name = "models";
                hostPath = {
                  path = cfg.modelsPath;
                  type = "Directory";
                };
              };
              volumes.root = {
                name = "root";
                hostPath = {
                  path = cfg.rootPath;
                  type = "DirectoryOrCreate";
                };
              };
              volumes.images-generated = {
                name = "images-generated";
                hostPath = {
                  path = cfg.imagesPath;
                  type = "Directory";
                };
              };
              volumes.pre-start = {
                name = "pre-start";
                configMap = {
                  name = "comfyui-pre-start";
                  # 0755 in decimal. Nix has no octal literal, and the Kubernetes
                  # API takes this field as a plain integer — so the familiar
                  # octal spelling has to be converted here, not written directly.
                  defaultMode = 493;
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
