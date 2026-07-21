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

## App modules

- Image generation, TTS, and further tenants land here as they are
  generalized from the originating production cluster.
- The LLM serving lane started here and **graduated to its own project**:
  [nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) — self-hosted
  LLM serving where the model store IS the registry.

## Status

**Pre-alpha, first tenants pending.** Every app planned here runs in
production on a single shared-GPU cluster; the generalized modules have not
been extracted yet.

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
