# Recipes

One directory per recipe, filed under the category it belongs to:
`apps/<category>/<app>/`. That path is also the option path — a recipe at
`apps/media/castopod/` declares `nixapps.media.castopod` and sets its delivery
project to `media`, so the two cannot drift apart
(see [CONTRACT.md](../CONTRACT.md) R4).

There is no list of categories anywhere in this repository, including in this
file's headings — each recipe simply states where it files itself, and the flake
discovers the rest by reading the directory. Adding a category means adding a
directory.

Every recipe is plain nixidy: one file, ordinary `lib.mkOption`, no shared
library to learn first (R5). Read [media/castopod](media/castopod) before the
others — it is the reference, and it is deliberately short.

## advanced

Direct consumers of scarce shared hardware. Both declare a hardware arbiter's
contract — a priority class and a device request — and neither implements any
part of it (R9).

- **[comfyui](advanced/comfyui)** — node-based image generation; holds the whole
  card for the duration of a render. Carries the reusable trick for injecting a
  pre-start hook into an image that `chmod +x`es its hook script, which fails on
  a directly-mounted ConfigMap because Kubernetes projects those read-only.
- **[tts](advanced/tts)** — two independently enabled engines in one namespace: a
  CPU-only narration engine, and a GPU-backed voice-cloning engine whose image
  you must build yourself because upstream publishes none.

## chat

- **[mattermost](chat/mattermost)** — team chat on an external Postgres.
- **[tuwunel](chat/tuwunel)** — Matrix homeserver; the server name is permanent
  once federated, which is the one value worth getting right first.

## data

- **[directus](data/directus)** — headless data platform over SQLite or Postgres.

## dev

- **[bytestash](dev/bytestash)** — code-snippet store with OIDC login.
- **[chartdb](dev/chartdb)** — database-schema visualizer; entirely stateless.

## documents

- **[bookstack](documents/bookstack)** — wiki with a shelf/book/page hierarchy.
- **[overleaf](documents/overleaf)** — collaborative LaTeX; needs Redis.
- **[paperless](documents/paperless)** — document archive with OCR; the OCR
  language list is knowledge worth setting deliberately.
- **[papra](documents/papra)** — minimal document store, rootless image.

## files

- **[nextcloud](files/nextcloud)** — the big one: php-fpm, nginx and a realtime
  push service in one pod, external Postgres, sibling Redis, and a crypto
  identity that must survive or SSO and encrypted files break.
- **[opencloud](files/opencloud)** — single-binary successor stack; external OIDC
  required, and its POSIX driver keeps file IDs in extended attributes.
- **[pingvin](files/pingvin)** — file sharing; all configuration lives in its
  SQLite database rather than in the environment.
- **[syncthing](files/syncthing)** — peer sync; its device identity lives in the
  config volume, and losing that volume makes it a different peer.
- **[versitygw](files/versitygw)** — S3 gateway fronting a plain POSIX tree.

## home

- **[grocy](home/grocy)** — household and grocery management.
- **[homarr](home/homarr)** — dashboard with OIDC login.
- **[homebox](home/homebox)** — home inventory.

## media

- **[castopod](media/castopod)** — podcast host. **The reference recipe:** one
  Deployment, one Service, three values, everything else knowledge. Read it first.
- **[ontime](media/ontime)** — event rundown timer; readable JSON state on disk,
  and `fsGroup` must never be set or it rechowns the host directory.
- **[tubearchivist](media/tubearchivist)** — video archive over Elasticsearch and
  Redis; Elasticsearch refuses to start unless the node's `vm.max_map_count` is
  raised, which is the kind of thing worth learning from a file rather than a
  crash loop.

## notes

- **[archivebox](notes/archivebox)** — web-page archiver.
- **[linkwarden](notes/linkwarden)** — bookmark manager with page snapshots.
- **[memos](notes/memos)** — lightweight note stream.
- **[silverbullet](notes/silverbullet)** — Markdown-on-disk notebook.

## office

- **[collabora](office/collabora)** — document-editing back end for a file host.
- **[eurooffice](office/eurooffice)** — document server; runs a schema init before
  the app starts.

## productivity

- **[calcom](productivity/calcom)** — scheduling; wants a large environment, all
  of it site-specific, so the recipe documents the keys and renders none of them.
- **[donetick](productivity/donetick)** — recurring chores and tasks.
- **[leantime](productivity/leantime)** — project management.
- **[planka](productivity/planka)** — kanban on external Postgres.
- **[vikunja](productivity/vikunja)** — tasks; the public URL is load-bearing
  because links in notifications are built from it.

## utility

- **[assets](utility/assets)** — small asset/inventory tracker.
- **[cyberchef](utility/cyberchef)** — data-transformation workbench, stateless.
- **[quickchart](utility/quickchart)** — chart-rendering service, stateless.
- **[rclone](utility/rclone)** — cloud-storage bridge driven by its config file.

## Not here

The LLM serving lane started in this repository and graduated to its own project
once it developed a mechanism worth having independently of the app (R12). Its
place in a deployment's namespace did not change — only where its code lives.

Two apps were deliberately **not** turned into recipes: one whose only container
image is a private build nobody else can pull, and one that exists to serve a
single person's data. A recipe a stranger cannot run is not a recipe.
