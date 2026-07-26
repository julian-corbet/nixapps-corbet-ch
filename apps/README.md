# Apps

Tenant modules, generalized from the originating production cluster:

1. [comfyui](comfyui) — image-generation tenant, GPU-backed, scale-to-zero
   wake-front consumer. Declares the nixgpu contract.
2. [tts](tts) — two independent text-to-speech tenants sharing one namespace:
   `kokoro` (CPU-only, always on) and `chatterbox` (GPU-backed voice cloning,
   also declaring the nixgpu contract). No standalone README yet — options
   are documented inline in `default.nix`.
3. [scale-to-zero-web](scale-to-zero-web) — generic CPU-only web tenant list,
   KEDA HTTP add-on fronted; covers any number of unrelated stateless (or
   lightly stateful) apps with one shared shape.

The LLM serving lane started here and graduated to its own sibling project,
[nixllm](https://github.com/julian-corbet/nixllm-corbet-ch).
