# tts

Two independently enabled Deployments sharing one namespace and one Argo
application — a deliberately different shape from `comfyui`'s single
direct-GPU tenant:

- **`kokoro`** — stock narrator-voice text-to-speech. CPU-only, with no GPU
  option surface at all (not even an unused one), enabled by default. Small
  and fast enough to run in real time on CPU per upstream's own benchmarks,
  so it never needs the shared card.
- **`chatterbox`** — voice-**cloning** text-to-speech (a short reference clip
  in, a cloned voice out). GPU-backed and off by default. It carries the
  identical three-line [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch)
  contract as `comfyui` (`priorityClassName`, `strategy: Recreate`, a
  device-resource token) and never has to think about the card again. In
  return, the platform guarantees co-residence when VRAM allows it, a clean
  priority-ordered yield when it doesn't, decisions made from live measured
  VRAM, and no card resets (nixgpu CONTRACT.md B1/B2/B8).

The GPU *device* infrastructure `chatterbox` depends on (a device-resource
token, a priority-class ladder, VRAM pressure eviction) is a separate concern
shipped by the sibling **nixgpu** project — this module only *consumes* that
contract, it does not provide it.

## A third scale-to-zero pattern, not a variant of the other two

`comfyui` is Sablier-fronted (a waiting page in front of a public URL); a
KEDA `HTTPScaledObject` front is the other common shape elsewhere in this
project family (`web`). Neither applies here. Both Deployments in this
module simply default to `replicas: 0` and are scaled 1↔0 by an **external**
operator or workflow script issuing a plain `kubectl scale` — no interceptor,
no waiting page, no front of any kind. That is a deliberate design choice,
not a missing feature: these are backend tools an internal pipeline calls
into (generate narration, clone a voice), never a public URL a browser lands
on cold. With no anonymous browser caller in the loop, there is no one to
show a "warming up" page to.

**GitOps prerequisite.** Unlike a Sablier-fronted tenant (where `replicas` is
omitted from the manifest entirely so the front can own it out-of-band),
`replicas` here is an ordinary, git-tracked field defaulting to `0`. An
external `kubectl scale --replicas=1` is live drift against the declared
desired state the instant it runs. If your GitOps controller self-heals this
Application with nothing telling it to ignore `spec.replicas` on these
Deployments, the very next reconcile silently scales the pod straight back to
`0` — with no crash, no sync failure, no obvious signal anywhere in this
module's own manifests. Get the ignore-diff (or sync-mode) story straight on
your own cluster before pointing any automation at `kubectl scale` here.

## Reusable lesson: probing an image with no dedicated health endpoint

The reference `chatterbox` image ships with **no** dedicated health
endpoint. Its root path (`/`) serves the web UI, and that UI only starts
responding once the model has actually finished loading — so this module
probes `/`, not an assumed `/health` (confirmed against the real server:
`/health` 404s the whole time, `/` 200s only once truly ready). Guessing
wrong here fails in two different, equally unpleasant directions: assume a
health path that always 404s and the pod never goes Ready at all; assume one
that 200s unconditionally (a liveness-only stub, a static file, a proxy
default page) and the pod goes "Ready" the instant the process starts, long
before the model is actually usable. Check what your own image really serves
at rest before trusting a path name alone.

## Reusable lesson: not every mounted path is equally disposable

`chatterbox`'s three required host paths (`hfCacheHostPath` /
`voicesHostPath` / `referenceAudioHostPath`) are not interchangeable and must
not be merged into one mount just because the container happens to read all
three. `hfCacheHostPath` is a **derived, disposable** download cache — wipe
it and the container simply re-downloads on next start. The other two hold
**irreplaceable user data**: saved voice presets and the reference audio
clips fed to a cloning request. Treating the cache path with the same
caution given to the other two costs nothing; treating the other two with the
"it's just a cache, it'll come back" carelessness that's fine for the first
one loses real recordings that do not come back.

## Options

Top-level:

| Option | Type | Default | Description |
|---|---|---|---|
| `nixapps.advanced.tts.enable` | bool | `false` | Enable the module. |
| `nixapps.advanced.tts.namespace` | str | `"tts"` | Namespace both Deployments (whichever are enabled) and their Services run in. |
| `nixapps.advanced.tts.appName` | str | `"tts"` | Name of the generated nixidy/Argo application; override to adopt an existing app name in-place during migration. |
| `nixapps.advanced.tts.createNamespace` | bool | `true` | Whether this application creates its namespace. |
| `nixapps.advanced.tts.project` | str | `"apps"` | nixidy AppProject. `kokoro` alone needs no GPU-tier permissions, but `chatterbox` (if enabled) is a direct GPU consumer sharing one application with it — map this to whatever tier your scheme uses for apps that touch the GPU directly, not the plain CPU-only tier. |

Kokoro (`nixapps.advanced.tts.kokoro.*`) — enabled by default, CPU-only, no GPU surface at all:

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `true` | Render the Kokoro Deployment and Service. Genuinely different from `chatterbox`: needs no GPU, no private image, no pull secret — the only required option is `modelStoreHostPath`. |
| `image` | str | `"ghcr.io/remsky/kokoro-fastapi-cpu:v0.6.0"` | Pinned to a version tag, never `:latest`. Upstream benchmarks this model as real-time even on CPU (82M parameters), the reason this tenant needs no GPU option surface. |
| `port` | port | `8880` | Port Kokoro listens on, and the Service targets. |
| `replicas` | int | `0` | Desired replica count. Defaults to `0` — see the scale-to-zero pattern above, and its GitOps prerequisite. |
| `modelStoreHostPath` | str | **required** | Host path to a directory of extra voice models. No default — every deployment's storage layout differs. Additive to, not a replacement for, the stock voice pack baked into the image: point it at an empty directory if you have nothing to add, rather than skipping the mount. |
| `resources.requests.cpu` | str | `"500m"` | Pod CPU request. |
| `resources.requests.memory` | str | `"1Gi"` | Pod memory request. |
| `resources.limits.memory` | str | `"2Gi"` | Pod memory limit. |
| `readinessProbe.path` | str | `"/health"` | Kokoro's reference image ships a real dedicated health endpoint at this path — no root-path workaround needed here, unlike `chatterbox`. |
| `readinessProbe.periodSeconds` | int | `3` | Poll interval once startup begins. |
| `readinessProbe.failureThreshold` | int | `60` | Failures tolerated before the pod is considered failed — 3 minutes of grace at the default interval, generous even for a "real-time on CPU" model because that benchmark describes steady-state inference, not cold weight-loading right after a scale-up from `0`. |

Chatterbox (`nixapps.advanced.tts.chatterbox.*`) — opt-in, GPU-backed:

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Render the Chatterbox Deployment and Service. Off by default, unlike `kokoro`: this tenant needs the shared GPU, a private image, and three required host paths with no defaults. |
| `image` | str | *(none — you must set it)* | No default: upstream's Dockerfile hardcodes CUDA, so running this elsewhere means a rebuild, and which rebuild is yours. A maintainer's personal registry namespace is not a portable default (CONTRACT.md R2) and a floating tag would be worse (R10). Pin a digest of a build you have validated. |
| `port` | port | `8004` | Port Chatterbox listens on, and the Service targets. |
| `replicas` | int | `0` | Desired replica count, identically to `kokoro.replicas`. Never set above `1`: a device-resource limit of `gpu.deviceResourceCount` per pod means a second replica simply fails to schedule once the first holds the card's only slot for this tenant. |
| `existingImagePullSecretName` | nullOr str | `null` | Name of an existing `dockerconfigjson` Secret granting pull access to `image`. This module does not create the Secret. Needed because the reference image is a private ghcr package; leave `null` for a public image. |
| `hfCacheHostPath` | str | **required** | Host path for Chatterbox's own HuggingFace download cache. Derived and disposable — see the lesson above. Created on first use if missing. |
| `voicesHostPath` | str | **required** | Host path for saved voice presets used for cloning. Irreplaceable user data — see the lesson above. |
| `referenceAudioHostPath` | str | **required** | Host path for user-supplied reference audio clips fed to a cloning request. Irreplaceable user data, kept separate from `voicesHostPath` because upstream's own container layout expects two distinct mount points. |
| `resources.requests.memory` | str | `"2Gi"` | Pod memory request — ordinary system RAM, separate from the VRAM the device-resource token gates. |
| `resources.limits.memory` | str | `"12Gi"` | Pod memory limit. Voice cloning stages the HuggingFace model and audio buffers through system RAM around the VRAM-bound steps, so a too-tight limit OOM-kills the pod even when the GPU had headroom. |
| `readinessProbe.path` | str | `"/"` | See the health-endpoint lesson above: this reference image has no dedicated health endpoint, and root is the path confirmed live to 200 only once the model has actually finished loading. |
| `readinessProbe.periodSeconds` | int | `5` | Poll interval once startup begins. |
| `readinessProbe.failureThreshold` | int | `120` | Failures tolerated before the pod is considered failed — 10 minutes of grace at the default interval, sized for a genuinely cold model load (no page-cache warmth) right after a scale-up from `0`, the common case for this tenant, not the exception. |

GPU contract surface (`nixapps.advanced.tts.chatterbox.gpu.*`):

| Option | Type | Default | Description |
|---|---|---|---|
| `priorityClassName` | str | `"gpu-besteffort"` | Same rung as `comfyui`, and for the same reason: an on-demand backend tool nobody is actively waiting on with low-latency expectations is exactly what best-effort is for. |
| `nodeSelector` | attrsOf str | `{ gpu = "amd"; }` | Restricts the pod to the node(s) that carry the shared GPU. |
| `deviceResourceName` | str | `"devic.es/rocm-compute"` | Extended-resource requested; matches nixgpu's device-tokens default compute lane. |
| `deviceResourceCount` | int | `1` | Device-resource slots requested. |
| `managedLabelKey` | str | `"example.com/managed"` | Pod label key marking this pod as nixgpu-managed. Placeholder domain — rename to match your nixgpu deployment's own label domain. |
| `engineLabelKey` | str | `"example.com/engine"` | Pod label key naming which GPU engine this pod uses. Placeholder domain — rename to match your nixgpu deployment's own label domain. |
| `engineLabelValue` | str | `"compute"` | Voice cloning uses the compute engine, as opposed to a separate media/video-codec engine unaffected by compute-side pressure. |
| `hsaOverrideGfxVersion` | str | `""` (empty) | `HSA_OVERRIDE_GFX_VERSION` for ROCm. Empty omits the env var entirely — correct for any card ROCm supports natively. Deliberately not defaulted to a real architecture: a concrete default is only ever right for the one card its author happened to own. Look your own card up in ROCm's supported-GPU list if it needs an override — e.g. an RDNA2 consumer card wants `"10.3.0"`. |

## Status

Extracted from a production system where this exact shape runs live: two
independently scaled-to-zero Deployments, one CPU-only and always on
standby, one GPU-backed and driven by the same external workflow tooling
that also drives `comfyui` and the shared LLM broker on the same card. This
generalized module has not yet been re-verified live in a fresh cluster —
re-verify before trusting it there.

Source lineage: generalized from a production single-GPU cluster.
