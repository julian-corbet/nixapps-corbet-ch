# Recipes

One directory per recipe, filed under the category it belongs to:
`apps/<category>/<app>/`. That path is also the option path — a recipe at
`apps/media/castopod/` declares `nixapps.media.castopod`, and its category
supplies the default for the delivery project so the two cannot drift apart
(see [CONTRACT.md](../CONTRACT.md) R4).

There is no list of categories anywhere in this repository. Each recipe simply
states where it files itself.

## media

- **[castopod](media/castopod)** — self-hosted podcast host. The reference
  recipe: one Deployment, one Service, five values the operator supplies, and
  everything else rendered by `lib`. Read this one first.

## advanced

Direct consumers of scarce shared hardware. Both declare a hardware arbiter's
contract (CONTRACT.md R9) and neither implements any part of it.

- **[comfyui](advanced/comfyui)** — image generation; holds the whole device
  while it runs, and carries optional wake-front discovery labels so an external
  front can rest it at zero between uses.
- **[tts](advanced/tts)** — two independently enabled workloads in one
  namespace: a CPU-only narration engine and a hardware-backed voice-cloning
  engine.

## generic

- **[web](generic/web)** — the escape hatch: a list-shaped recipe for
  single-container web applications too ordinary to deserve their own file.
  Anything here that grows app-specific knowledge worth writing down should
  become its own recipe under a real category instead.

## Not here

The LLM serving lane started in this repository and graduated to its own
project once it developed a mechanism worth having independently of the app
(CONTRACT.md R12). Its place in a deployment's namespace did not change — only
where its code lives.
