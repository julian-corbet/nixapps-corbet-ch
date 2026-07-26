# scale-to-zero-web

The **other platform opinion** in this project family besides GPU sharing (see
[nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch)): a generic tenant
module for CPU-only web apps that rest at zero replicas between uses and wake
on the first request via the [KEDA HTTP add-on](https://github.com/kedacore/http-add-on).

Unlike [comfyui](../comfyui) or [tts](../tts) — each a single, bespoke,
opinionated tenant — this module renders a **list** of tenants. That shape is
deliberate: a chart-rendering API, a snippet manager, a small CRUD tool and a
dashboard have nothing to do with each other, but they render to the *same
three objects* — a Deployment, a Service, an HTTPScaledObject — with no PVC,
no Secret creation, and no hostPath in the common case. One option shape
covers all of them with zero redesign; a small handful need only the optional
`dataHostPath`/`existingSecretName` fields for a local data directory or a
client secret. Each list entry renders as its **own** nixidy Argo application
— never bundled together — so one tenant's sync/prune/rollback can never
touch another's.

## The substrate this module consumes, and does not provide

The KEDA core controller, the KEDA HTTP add-on (its CRDs and its interceptor
Service/proxy), and whatever routes public traffic to the cluster's HTTP
entrypoint are cluster-wide infrastructure, installed **once**, out of band
from any tenant — the same substrate/tenant split as nixgpu/nixllm. This
module only emits objects that *consume* that substrate; it has no option
surface for installing KEDA itself. Wire the substrate in with
[nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) (or a sibling of
it) before pointing this module at a cluster.

GPU-consuming tenants are explicitly **out of scope** here — this module has
no GPU option surface at all, not even an unused one. A GPU-backed
scale-to-zero tenant belongs in a module like comfyui/tts instead, declaring
the nixgpu contract (`priorityClassName`, `strategy: Recreate`, a
device-resource token) rather than reinventing card handling.

## Why the HTTPScaledObject is raw YAML, not a typed option

It's a CRD (`http.keda.sh/v1alpha1`), and nixidy only ships typed options for
the core Kubernetes API out of the box — a typed option for a third-party CRD
exists only after the *consuming* environment has already run nixidy's
`generators.fromCRDModule` against that CRD and imported the result. That's
substrate-level wiring a portable tenant module can't assume has happened, so
the HTTPScaledObject is emitted as a YAML string through nixidy's `yamls`
escape hatch (a list of raw manifests, parsed and merged into the
application's rendered objects), while the Deployment and Service — both core
kinds, always available — use the typed `resources.*` path exactly like
nixllm and comfyui/tts do.

## The replicas lesson

This module **never** sets `spec.replicas` on the rendered Deployment —
unconditionally, no toggle, no exception. Once the HTTPScaledObject exists,
KEDA's own HPA is the sole owner of this Deployment's live replica count (0 at
rest, up to `replicas.max` once woken) on *every* reconcile, not just the
first one. Declaring a fixed `replicas` in git as well would put Argo CD's
self-heal in a standing fight with KEDA over the same field, flapping the
Deployment between whatever git says and whatever KEDA just scaled it to.
Kubernetes defaults an absent `replicas` to 1 server-side, which doesn't
matter here since KEDA overwrites it on its own schedule regardless. **A
Deployment resting at 0/0 between requests is this module's normal steady
state**, not a sign anything is broken or missing.

## The health-path lesson

`healthPath` has **no default**, deliberately — it is not safely guessable.
The two reference tenants this module was generalized from *disagree with
each other*: one serves a real dedicated health endpoint at a non-root path;
the other has none, and only its root path (`/`) answers correctly, and only
once the app has actually finished starting. Guessing wrong fails in two
different, equally unpleasant directions: assume a path that 404s forever and
the pod never goes Ready; assume one that 200s unconditionally (a static
file, a proxy default page) and the pod goes "Ready" before the app can
actually serve a real request. Check what your own image serves, at rest,
before setting this.

## The namespace-anchor lesson

`createNamespace` defaults to `true` on every app entry, which is correct
*only* as long as each distinct effective namespace among your `apps` is used
by exactly one app. Point several apps at the **same** namespace — the
shared-namespace pattern this tenant class commonly uses in production,
several small apps anchored under one namespace — and leaving every one of
them at the default means several independent Argo applications all try to
create and own the same Namespace object. Set `createNamespace = false` on
every app but one "anchor" sharing that namespace. This is enforced at build
time (a nixidy assertion), not just documented: more than one app sharing an
effective namespace with `createNamespace = true` fails the build instead of
silently double-creating the object. The same mechanism enforces that
`dataMountPath` is set whenever `dataHostPath` is.

## The data-ownership lesson

`fsGroup` is never set by this module, under any option combination. It
recursively chowns every file under every mounted volume on each pod start,
including a bind-mounted `dataHostPath` dataset that already has its own
ownership from outside Kubernetes entirely — fighting (and on a large
directory, badly slowing down) that ownership on every single pod start or
restart. If a data volume needs to be writable by a specific uid, make that
uid the volume's *actual* on-disk owner and set `runAsUser`/`runAsGroup` to
match, rather than reaching for `fsGroup` to paper over a mismatch. Setting
`runAsUser` at all is also the signal that gates a small hardening bundle
(`runAsNonRoot`, dropped capabilities, `RuntimeDefault` seccomp) — left unset,
no `securityContext` is rendered at all, which is the only safe default for an
unmodified upstream image of unknown expected uid.

## Options

Top-level:

| Option | Type | Default | Description |
|---|---|---|---|
| `nixapps.scaleToZeroWeb.enable` | bool | `false` | Enable the module. |
| `nixapps.scaleToZeroWeb.namespace` | str | `"apps"` | Default namespace for apps that don't set their own `namespace`. |
| `nixapps.scaleToZeroWeb.project` | str | `"apps"` | Default nixidy AppProject for apps that don't set their own `project` — the plain CPU-only tier, unlike comfyui/tts's GPU tier. |
| `nixapps.scaleToZeroWeb.apps` | listOf submodule | `[]` | The tenants to render, one Argo application each. See below. |

Per-app (`nixapps.scaleToZeroWeb.apps.*`) — `name`, `image`, `port`, `healthPath`, `host` are the only **required** fields:

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `true` | Render this tenant at all. |
| `name` | str | **required** | Shared name for the Deployment/Service/HTTPScaledObject/Argo application. Set to an existing app's name to adopt it in place. |
| `namespace` | nullOr str | `null` | Falls back to the module-level default when unset. |
| `createNamespace` | bool | `true` | See the namespace-anchor lesson above. |
| `project` | nullOr str | `null` | Falls back to the module-level default when unset. |
| `image` | str | **required** | Container image. |
| `port` | port | **required** | Reused for the container port, the Service port/targetPort, and `scaleTargetRef.port`. |
| `healthPath` | str | **required** | See the health-path lesson above. |
| `scaledownPeriod` | int | `300` | Idle seconds before KEDA scales back to `replicas.min`. Fleet-wide production convention. |
| `replicas.min` | int | `0` | Scale-to-**zero** floor. |
| `replicas.max` | int | `1` | Scale-up ceiling; raise only if the app tolerates concurrent replicas. |
| `nodeSelector` | attrsOf str | `{}` | Empty = no pinning. Becomes important once `dataHostPath` is set on a multi-node cluster (hostPath is node-local). |
| `dataHostPath` | nullOr str | `null` | Host path for a stateful sibling's data directory. `null` = fully stateless (the reference tenant). No PVC option — hostPath or nothing. |
| `dataMountPath` | nullOr str | `null` | In-pod mount path for `dataHostPath`. Required whenever `dataHostPath` is set — no universal default. |
| `runAsUser` / `runAsGroup` | nullOr int | `null` | See the data-ownership lesson above. |
| `env` | attrsOf str | `{}` | Plain environment variables. |
| `existingSecretName` | nullOr str | `null` | An existing Secret `secretEnv` reads from. Never created by this module. |
| `secretEnv` | attrsOf str | `{}` | Env var name → key within `existingSecretName`. |
| `clusterIP` | nullOr str | `null` | Optional fixed ClusterIP; leave `null` unless your routing needs a stable, pre-known VIP. |
| `host` | str | **required** | Public FQDN the HTTPScaledObject wakes this app for. One host per tenant. |

Probes (`nixapps.scaleToZeroWeb.apps.*.probes.*`):

| Option | Type | Default | Description |
|---|---|---|---|
| `readiness.periodSeconds` | int | `5` | Readiness poll interval. |
| `readiness.failureThreshold` | int | `24` | ~2 min grace — this module's default for a fast-booting tenant with no `startupProbe`. |
| `readiness.timeoutSeconds` | nullOr int | `null` | `null` omits the field (k8s default 1s). |
| `liveness.periodSeconds` | int | `15` | Liveness poll interval. |
| `liveness.failureThreshold` | int | `6` | ~90s grace — liveness only needs to catch a genuine hang once the app is already running. |
| `liveness.timeoutSeconds` | nullOr int | `null` | `null` omits the field. |
| `startup.enable` | bool | `false` | Off by default (reference tenant boots fast enough without one). Turn on for a slow-booting sibling — see the module comment on why this beats stretching readiness/liveness. |
| `startup.periodSeconds` | int | `5` | Startup poll interval, once enabled. |
| `startup.failureThreshold` | int | `60` | ~5 min grace — size for the slowest realistic cold wake, not the average one. |
| `startup.timeoutSeconds` | nullOr int | `5` | Probe timeout, once enabled. |

## Consumer example

Using [QuickChart](https://github.com/typpo/quickchart) — a stateless
Chart.js-to-PNG/PDF render API, and the reference tenant this module was
generalized from — as the first entry:

```nix
{
  imports = [ inputs.nixapps.nixidyModules.scaleToZeroWeb ];

  nixapps.scaleToZeroWeb.enable = true;

  nixapps.scaleToZeroWeb.apps = [
    {
      name = "quickchart";
      image = "ianw/quickchart";
      port = 3400;
      healthPath = "/healthcheck";
      host = "charts.example.com";
      # scaledownPeriod / replicas.min / replicas.max all keep their defaults (300 / 0 / 1).
    }

    # A stateful sibling in the same shared namespace, anchored by the entry above:
    {
      name = "my-snippet-manager";
      namespace = "apps"; # same as quickchart's effective namespace
      createNamespace = false; # quickchart already anchors this namespace — see the anchor lesson
      image = "ghcr.io/example/snippet-manager:latest";
      port = 5000;
      healthPath = "/";
      host = "snippets.example.com";
      dataHostPath = "/srv/apps/snippet-manager/data";
      dataMountPath = "/data/snippets";
      runAsUser = 3021;
      existingSecretName = "snippet-manager-secrets";
      secretEnv.JWT_SECRET = "JWT_SECRET";
    }
  ];
}
```

## Status

Generalized from a production cluster where this exact 3-object shape is live
today across more than a dozen independent tenants of very different purpose
— most needing nothing but the plain options above, a handful needing the
optional `dataHostPath`/`existingSecretName` fields. Render-checked, not yet
re-verified live in a fresh cluster — re-verify before trusting it there.

Source lineage: generalized from a production single-GPU cluster.
