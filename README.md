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

Three tenant modules have landed (`nixidyModules.*`):

- **`comfyui`** ([apps/comfyui](apps/comfyui)) — the flagship direct-GPU
  tenant: a scale-to-zero image-generation app that holds the whole card
  while it runs, declaring the nixgpu contract (`priorityClassName`,
  `strategy: Recreate`, a device-resource token). Optional wake-front
  consumer labels for nixgpu's `ondemand-front`; a reusable pattern for
  injecting a custom pre-start hook into a read-only-ConfigMap-hostile image.
- **`tts`** ([apps/tts](apps/tts)) — two independently enabled Deployments
  sharing one namespace: `kokoro` (stock CPU-only narration, always
  schedulable) and `chatterbox` (GPU-backed voice cloning, also declaring the
  nixgpu contract). Neither is wake-fronted — both scale 0↔1 via an external
  operator/workflow script, the third scale-to-zero pattern in this project
  family alongside comfyui's Sablier front and `scale-to-zero-web`'s KEDA
  front.
- **`scale-to-zero-web`** ([apps/scale-to-zero-web](apps/scale-to-zero-web))
  — a generic, CPU-only, list-shaped tenant module for stateless (or lightly
  stateful) web apps that rest at zero replicas and wake on first request via
  the KEDA HTTP add-on. Covers any number of unrelated apps with one shared
  Deployment/Service/HTTPScaledObject shape; each list entry renders as its
  own independent Argo application.

The LLM serving lane started here and **graduated to its own project**:
[nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) — self-hosted
LLM serving where the model store IS the registry.

## Status

**Pre-alpha.** All three modules above are generalized from a single
production shared-GPU cluster and render-check clean (`nix eval` on
`nixidyModules`, plus standalone `lib.evalModules` harness runs per module),
but — unlike the sibling `nixgpu`/`nixllm` projects — **none of them has been
adopted back into a live cluster yet**; treat them as render-checked, not
live-verified, until that happens.

Pending:

- `tts` has no standalone `README.md` yet (comfyui and scale-to-zero-web do);
  its options are documented inline in `apps/tts/default.nix` only.
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
