# nixapps

**A curated library of self-hosted application modules for a nixidy + Argo CD
cluster — apps as typed Nix, not copy-pasted YAML.**

The tenant layer of an interoperating project set: application modules that
render through [nixidy](https://github.com/arnarg/nixidy) and deploy onto the
spine shipped by [nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch).
GPU-consuming apps declare the three-line contract from
[nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) and never think
about the card again.

## The pitch

Self-hosting collections exist for docker-compose and Helm. This one is for
people who want the whole cluster in git as typed Nix: every app a module with
neutral defaults, every deployment a rendered, auditable manifest tree, every
upgrade a diff.

LLM consumers point at the
[nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) front door with a
key and a model name, and request no GPU of their own.

## What ships

Three tenant modules have landed (`nixidyModules.<category>.<app>`; see
[apps/README.md](apps/README.md) for the category layout):

- **`comfyui`** ([apps/advanced/comfyui](apps/advanced/comfyui)) — the
  flagship direct-GPU tenant: a scale-to-zero image-generation app that holds
  the whole card while it runs, declaring the nixgpu contract
  (`priorityClassName`, `strategy: Recreate`, a device-resource token).
  Optional wake-front consumer labels for nixgpu's `ondemand-front`; a
  reusable pattern for injecting a custom pre-start hook into a
  read-only-ConfigMap-hostile image.
- **`tts`** ([apps/advanced/tts](apps/advanced/tts)) — two independently
  enabled Deployments sharing one namespace: `kokoro` (stock CPU-only
  narration, always schedulable) and `chatterbox` (GPU-backed voice cloning,
  also declaring the nixgpu contract). Neither is wake-fronted — both scale
  0↔1 via an external operator/workflow script, the third scale-to-zero
  pattern in this project family alongside comfyui's Sablier front and
  `web`'s KEDA front.
- **`web`** ([apps/generic/web](apps/generic/web)) — a generic, CPU-only,
  list-shaped tenant module for stateless (or lightly stateful) web apps that
  rest at zero replicas and wake on first request via the KEDA HTTP add-on.
  Covers any number of unrelated apps with one shared
  Deployment/Service/HTTPScaledObject shape; each list entry renders as its
  own independent Argo application.

The LLM serving lane started here and **graduated to its own project**:
[nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) — self-hosted
LLM serving where the model store IS the registry.

## Status

**Pre-alpha.** All three modules above are generalized from a single
production shared-GPU cluster and evaluate on their own — but — unlike the
sibling `nixgpu`/`nixllm` projects — **none of them has been adopted back
into a live cluster yet**; treat them as evaluated, not live-verified, until
that happens.

A reorganization onto the recipe contract fixed in [CONTRACT.md](CONTRACT.md)
is in progress: modules are moving onto the `apps/<category>/<app>` layout
that mirrors each module's own `nixapps.<category>.<app>` option path
(CONTRACT.md R4), and a shared `lib` is absorbing the renderings that
duplicate across recipes (R5). What is actually checked in CI today is
render checks landing with the reorganization: `nix flake check` renders
`examples/minimal`, a real self-contained consumer flake, through the
`generic.web` module against the real nixidy module system it targets
(R11). `comfyui` and `tts` are not yet wired into that check. **CONTRACT.md
is the design authority** — it states the target this repository is being
moved onto; this section states only what is true of the code today, and the
two are not always the same yet.

Pending:

- Wire `comfyui` and `tts` into the `nix flake check` render check alongside
  `generic.web`.
- Live re-verification of all three modules against a real cluster.
- Further tenants land here as they are generalized from the originating
  production cluster.

## Related projects

- [nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) — the cluster
  spine these modules deploy onto.
- [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) — the GPU
  sharing substrate GPU apps declare their contract against.
- [nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) — the shared
  LLM serving lane (graduated from this repo).
- [nixvibe](https://github.com/julian-corbet/nixvibe-corbet-ch) — a coding
  agent in a real browser terminal; substantial enough to graduate straight
  to its own repo rather than landing here.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
