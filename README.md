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

The flagship — and first extraction — is the **LLM serving lane**:

- **One shared LLM server owns all models.** llama-swap + llama.cpp behind a
  LiteLLM front door: one OpenAI-compatible endpoint, many models, loaded on
  demand, idle-unloaded.
- **The store IS the registry.** Drop a GGUF in the right subdirectory and it
  is servable by name — serving mode from the path, context and chat template
  from GGUF metadata, MoE expert-offload detected, oversized dense models
  refused. The engine config is *generated* from the store; there is no
  hand-maintained model catalog.
- **Apps integrate with a key and a model name.** A new LLM-consuming app
  requests no GPU of its own — it points at the front door.

The lane implements behaviors B4/B10/B14/B15 of the
[nixgpu contract](https://github.com/julian-corbet/nixgpu-corbet-ch/blob/main/CONTRACT.md).

## Planned app modules

- **`llm-serving`** *(flagship, first)* — the shared broker: llama-swap +
  llama.cpp, LiteLLM front, store-scan config generator.
- Image generation, TTS, and further tenants follow as they are generalized
  from the originating production cluster.

## Status

**Pre-alpha, extraction not started.** Every app listed runs in production on
a single shared-GPU cluster; this repo will carry their generalized modules.
Nothing has been extracted yet.

## Related projects

- [nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) — the cluster
  spine these modules deploy onto.
- [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) — the GPU
  sharing substrate GPU apps declare their contract against.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
