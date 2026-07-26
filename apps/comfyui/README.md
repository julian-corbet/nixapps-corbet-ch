# comfyui

The flagship **direct-GPU tenant**: a scale-to-zero image-generation app that
holds the whole card while it runs. It declares the three-line
[nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) contract —
`priorityClassName`, `strategy: Recreate`, one device-resource token — and
never has to think about the card again. In return, the platform guarantees
co-residence when VRAM allows it, a clean priority-ordered yield when it
doesn't, decisions made from live measured VRAM, and no card resets (nixgpu
CONTRACT.md B1/B2/B8/B9).

The GPU *device* infrastructure this tenant depends on (a device-resource
token, a priority-class ladder, VRAM pressure eviction) is a separate concern
shipped by the sibling **nixgpu** project — this module only *consumes* that
contract, it does not provide it.

## Wake-front: consumer, not provider

This module can carry the opt-in labels (`sablier.enable`/`sablier.group`)
that let a scale-to-zero waiting-page front recognize and manage this
Deployment — but it does not bundle [Sablier](https://github.com/sablierapp/sablier)
or Caddy itself. That wiring already exists as its own module: nixgpu's
[`ondemand-front`](https://github.com/julian-corbet/nixgpu-corbet-ch/tree/main/modules/ondemand-front)
(Sablier + a themed Caddy front, the honest "starting up / GPU busy / waiting"
page). Enable `wake.enable` here, and add a matching
`nixgpu.ondemandFront.apps.<name>` entry on the front side whose `group`
equals `wake.sablierGroupLabelValue`.

Enabling `wake.enable` also changes how `replicas` is rendered: it is
**omitted from the Deployment spec entirely**, deliberately. The wake-front
owns the replica count out-of-band once it exists (scaling the Deployment
0↔1 on traffic); if GitOps also declared a fixed replica count, every sync
would fight the wake-front's own scaling and flap the pod between the two. A
Deployment resting at 0/0 replicas between requests is the *expected steady
state* of a wake-front consumer, not a failure. Leave `wake.enable = false`
only for a tenant that runs unscaled at a fixed replica count of 1.

## Reusable pattern: a custom pre-start hook, on a read-only-ConfigMap-hostile image

Several ROCm/CUDA base images source an optional startup hook script IF
present (`preStartHookPath`), and unconditionally `chmod +x` it before
sourcing. Mounting a ConfigMap directly at that path fails startup **every
single time**: ConfigMap volumes are always projected read-only with no
override, and the entrypoint's own `chmod` — under its own `set -e` — aborts
before the app ever runs.

The fix generalizes past ComfyUI: an init container copies the ConfigMap's
content onto an already-writable volume the main container also mounts (here,
the state volume), and chmods the **copy**, never the ConfigMap-backed
original. Any custom-node/plugin-loading GPU app that needs to inject a
startup hook into someone else's entrypoint will need this same trick again.

`preStartScript`'s own example carries the second lesson this pattern was
built to solve: `onnxruntime-gpu` is CUDA-only, and several popular ComfyUI
custom nodes (face/ID-swap nodes among them) list it unconditionally in their
`requirements.txt` for any x86_64 Linux host — no ROCm/CUDA marker at all. On
a non-CUDA GPU host it silently clobbers a working plain `onnxruntime` install
and breaks every node that imports it. This module does **not** hardcode that
fixup — `preStartScript` defaults to `null` (no hook at all); the example
shows the general shape so any adopter with the same class of problem doesn't
have to rediscover it.

## Options

Top-level:

| Option | Type | Default | Description |
|---|---|---|---|
| `nixapps.comfyui.enable` | bool | `false` | Enable the module. |
| `nixapps.comfyui.namespace` | str | `"comfyui"` | Namespace for the Deployment and Service. |
| `nixapps.comfyui.appName` | str | `"comfyui"` | Name of the generated nixidy/Argo application; override to adopt an existing app name in-place during migration. |
| `nixapps.comfyui.createNamespace` | bool | `true` | Whether this application creates its namespace. |
| `nixapps.comfyui.project` | str | `"apps"` | nixidy AppProject. Map to whatever tier your scheme uses for apps that touch the GPU directly — not the plain CPU-only tier, and not nixgpu's own device-infra tier. |
| `nixapps.comfyui.modelStoreHostPath` | str | **required** | Host path to ComfyUI's whole `models/` tree (checkpoints/loras/controlnet/… as siblings) — ONE mount, unlike nixllm's per-subdirectory scheme, because ComfyUI itself expects the full conventional layout under one root. No default — every deployment's storage differs. |
| `nixapps.comfyui.modelMountPath` | str | `"/root/ComfyUI/models"` | In-pod mount path for the above — ComfyUI's own convention. |
| `nixapps.comfyui.stateHostPath` | str | **required** | Host path for the pod's persistent working directory (venv, `custom_nodes/`, cache). No default. |
| `nixapps.comfyui.stateMountPath` | str | `"/root"` | In-pod mount path for the above; also the base `preStartHookPath`/`modelMountPath` are relative to. |
| `nixapps.comfyui.outputHostPath` | str | **required** | Host path rendered images are written to. No default. Written as root — see the option's own doc on the resulting (harmless) ownership gap on a non-root-owned host directory. |
| `nixapps.comfyui.outputMountPath` | str | `"/output"` | In-pod mount path for the above; also becomes the `--output-directory` CLI value. |
| `nixapps.comfyui.httpPort` | port | `8188` | ComfyUI's listen port; also the Service's port. |
| `nixapps.comfyui.extraCliArgs` | listOf str | `[]` | Extra native CLI flags, appended after the always-present `--listen`/`--output-directory`. |
| `nixapps.comfyui.preStartHookPath` | str | `"/root/user-scripts/pre-start.sh"` | In-pod path the base image sources on every start, if present — `yanwk/comfyui-boot`'s own convention. |
| `nixapps.comfyui.preStartScript` | nullOr str | `null` | Optional startup hook content (see above); `null` renders no ConfigMap/init container at all. |
| `nixapps.comfyui.clusterIP` | nullOr str | `null` | Optional fixed ClusterIP. Leave `null` unless your routing needs a stable, pre-known VIP. |

Readiness (`nixapps.comfyui.readiness.*`):

| Option | Type | Default | Description |
|---|---|---|---|
| `periodSeconds` | int | `5` | Readiness probe poll interval. |
| `failureThreshold` | int | `180` | Consecutive failures tolerated (15 min of grace at the default interval) — sized for the *slowest* cold start (a `preStartScript` install from scratch plus first model load), not the average one. A wake-front holds callers on its waiting page until this probe passes, so too short a value here shows up as spurious mid-load restarts, not an occasional flake. |

Resources (`nixapps.comfyui.resources.*`):

| Option | Type | Default | Description |
|---|---|---|---|
| `memoryLimit` | str | `"24Gi"` | Pod memory limit — ordinary system RAM, separate from the VRAM the device token gates. Image-generation pipelines commonly stage tensors through system RAM around the VRAM-bound steps. |
| `memoryRequest` | str | `"4Gi"` | Pod memory request. |

GPU contract surface (`nixapps.comfyui.gpu.*`):

| Option | Type | Default | Description |
|---|---|---|---|
| `priorityClassName` | str | `"gpu-besteffort"` | Best-effort by default — a throwaway render nobody is actively waiting on, first to yield under VRAM pressure. Raise it per-run, not per-app, when an operator is actively waiting. |
| `nodeSelector` | attrsOf str | `{ gpu = "amd"; }` | Restricts the pod to GPU-bearing node(s). |
| `deviceResourceName` | str | `"devic.es/rocm-compute"` | Extended-resource requested; matches nixgpu's device-tokens default compute lane. |
| `deviceResourceCount` | int | `1` | Device-resource slots requested. |
| `managedLabelKey` | str | `"example.com/managed"` | Pod label key marking this pod as nixgpu-managed. Placeholder domain — rename to match your nixgpu deployment's own label domain. |
| `engineLabelKey` | str | `"example.com/engine"` | Pod label key naming which GPU engine this pod uses. Placeholder domain — rename to match your nixgpu deployment's own label domain. |
| `engineLabelValue` | str | `"compute"` | The compute engine (not the separate-silicon media engine). |
| `hsaOverrideGfxVersion` | str | `"10.3.0"` | `HSA_OVERRIDE_GFX_VERSION` for ROCm. `"10.3.0"` is an RDNA2 **example** — look up your own card's value; empty string omits the env var. |

Wake-front consumer surface (`nixapps.comfyui.wake.*`):

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Carry the `sablier.enable`/`sablier.group` Deployment labels, and omit `replicas` (see above). Does not deploy Sablier or Caddy. |
| `sablierGroupLabelKey` | str | `"sablier.group"` | Sablier's own discovery label key — fixed by Sablier, not this project's convention. |
| `sablierGroupLabelValue` | str | `appName` | Must match the `group` field of the corresponding `nixgpu.ondemandFront.apps.<name>` entry. |

Images (`nixapps.comfyui.images.*`):

| Option | Default |
|---|---|
| `comfyui` | `yanwk/comfyui-boot@sha256:7c64b...` — digest-pinned, not a floating tag |
| `preStartInstaller` | `busybox:stable@sha256:b7f3d...` |

## Consumer example

```nix
{
  imports = [ inputs.nixapps.nixidyModules.comfyui ];

  nixapps.comfyui.enable = true;
  nixapps.comfyui.modelStoreHostPath = "/srv/comfyui/models"; # required — your real store root
  nixapps.comfyui.stateHostPath = "/srv/comfyui/state";       # required
  nixapps.comfyui.outputHostPath = "/srv/comfyui/output";     # required

  # Optional: scale to zero behind a wake-front (bring your own nixgpu.ondemandFront entry).
  nixapps.comfyui.wake.enable = true;

  # Optional: a custom-node dependency bootstrap hook (see preStartScript's `example` for the
  # ROCm/onnxruntime-gpu lesson this generalizes).
  nixapps.comfyui.preStartScript = ''
    #!/bin/bash
    set -eu
    for req in /root/ComfyUI/custom_nodes/*/requirements.txt; do
      [ -f "$req" ] || continue
      pip install --no-cache-dir -r "$req" || echo "WARN: failed installing $req"
    done
  '';
}
```

Pair this with, on the wake-front side:

```nix
{
  nixgpu.ondemandFront.apps.comfyui = {
    host = "your-image-gen.example.com";
    group = "comfyui"; # must match nixapps.comfyui.wake.sablierGroupLabelValue
    upstream = "comfyui.comfyui.svc.cluster.local"; # <namespace> matches nixapps.comfyui.namespace
    port = 8188; # matches nixapps.comfyui.httpPort
  };
}
```

## Status

Extracted from a production system where this exact shape runs live,
scale-to-zero fronted, consuming a single shared GPU alongside a serving lane
and other direct-GPU tenants. This generalized module has not yet been
re-verified live in a fresh cluster — re-verify before trusting it there.

Source lineage: generalized from a production single-GPU cluster.
