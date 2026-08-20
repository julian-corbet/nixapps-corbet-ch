# nixapps — the recipe contract

This file is the fixed target: *what a recipe is*, and what this repository will
and will not contain. When a module and this contract disagree, the contract
wins — and if a rule itself is wrong, fix it here, not in a commit message.

## What this repository is

**A cookbook for ordinary self-hosted applications.** Each recipe describes one
app completely enough that a stranger can deploy it, and configures nothing
about any particular site.

Its value is *knowing the recipe*: that this app serves HTTP on 8080 with a web
server already in the image, that it migrates its own database on boot so the
readiness probe must be patient, that its documented Redis dependency is only a
cache and can be pointed at a file handler instead, that it writes exactly one
directory and everything else is in the database. That knowledge is expensive to
acquire and cheap to copy, which is the whole reason to publish it.

The cooking happens elsewhere. An operator pairs each recipe with a short values
file naming the handful of things true only of their cluster.

## What this repository is not

- **The operating system.** Not here.
- **The delivery mechanism.** How manifests are rendered, committed, synced,
  grouped into projects and anchored into namespaces is a separate layer. This
  repo produces application definitions and hands them over.
- **Hardware arbitration.** Deciding who gets scarce shared hardware, in what
  order, and what happens to whoever loses is a separate layer. Recipes here
  *declare* against that arbiter (R9); none implements any part of it.
- **Theses.** An app whose implementation becomes interesting independently of
  the app leaves (R12). What stays is the run-of-the-mill.

Plainly: this repo will never grow an autoscaler, an ingress controller, a
storage provisioner, a device plugin, a project renderer, or a generic
render-any-app module. It consumes all of them and implements none.

## The namespace this repo renders into

A deployed application has **one identity with several renderings**: a name, a
category, an address, the namespace it runs in, and a decision about who may
reach it. Those renderings belong to the *site*, not to this repository. The
site's own map is the authority, and it lists apps sourced from here alongside
apps sourced from anywhere else in one uniform form. Nothing in that map records
which repository an app's code came from, because it does not matter.

This repo touches exactly one rendering: a recipe declares itself at
`nixapps.<category>.<app>`, mirroring the site's categories so that reading
either teaches you the other. Mirroring is not ownership — see R4.

## Rules

**R1 — A recipe describes one app completely, and configures nothing.**
It renders every workload, service, mount and probe the app needs to run, and
supplies no site-specific value. Enabling a recipe and nothing else must **fail
loudly**, naming what the operator still owes — never start something
half-configured.

**R2 — Every option is either knowledge or a value, and its default says which.**
*Knowledge* — upstream image, container port, internal mount path, probe timing,
update strategy, the environment keys the app requires — carries a default, so a
stranger gets a working app. A *value* — where state lives, which secret holds
the credentials, the public URL — carries **no default** and fails evaluation
when unset.

A knowledge option with no default is a trap. A value option with a default is a
lie about portability: the stranger's deploy builds fine and then breaks at
runtime instead of at evaluation, which is the one place it was cheap to catch.

**R3 — The reason travels with the setting.**
Any non-obvious choice states *why*, in the option description or a comment
beside it: this app cannot run two replicas because one writer owns its media
directory; this probe grants three minutes because the app migrates on first
boot. A recipe without its reasons is a manifest with extra syntax. **The
reasons are the reason to publish.**

**R4 — The category is a path segment, not an enumeration.**
A recipe declares itself at `nixapps.<category>.<app>`, mirroring its own path
under `apps/`, and sets its delivery project to the same string so the two
cannot drift. **No central list of categories exists anywhere in this
repository** — each recipe simply states where it files itself. Adding a
category means adding a directory.

**R5 — Recipes are plain and standalone.**
Each recipe is a single file of ordinary nixidy options and resources, readable
top to bottom with no indirection. There is **no shared library**, and
duplication between recipes is accepted deliberately: two recipes that look
similar are two independent statements about two different apps, and a reader
learning one app should not have to learn a framework first. A helper that saves
a few lines but requires a second file to understand the first is a net loss
here.

**R6 — Exposure is not published.**
A recipe renders a plain ClusterIP Service and stops. Ingress, tunnels,
overlays, fixed cluster addresses, external IPs, hostnames, DNS — all are
properties of the site, and none appear in this repository in any form.

**R7 — Storage is a mount, not a backing.**
A recipe declares that the app needs state at a path *inside its container*, and
takes the host location as a value. A recipe that can only be backed one way is
not portable.

**R8 — Capacity is not published.**
Replica counts, resource requests and limits, node selectors, tolerations,
affinity, and whether the app runs always or is woken on demand are all
decisions about one site's hardware. Recipes omit them entirely.

They are not lost. These are NixOS-style modules, so a consumer merges its own
tuning into the same attribute path from its own file, with no help needed from
this repo.

Two things that look like capacity but are not, and therefore stay:

- An update strategy that exists for **correctness** — `Recreate` where two
  overlapping pods would corrupt shared state. That is app knowledge (R2).
- A **priority class and a device request** on an app that holds scarce shared
  hardware. Those are not sizing; they are the arbiter's contract, and how the
  arbiter decides who loses (R9). The recipe declares that it needs them and
  takes their names as values, because only the site knows what its arbiter
  calls them.

**R9 — Hardware consumers declare; they never manage.**
An app holding scarce shared hardware declares what it needs and nothing more.
It never reads device state, never sets thresholds, never evicts anything. The
arbiter is not in this repo and recipes must not reimplement fragments of it.

**R10 — Images are pinned. `latest` is never a default.**
A moving tag changes behavior between deploys with nothing to review beforehand.
Digest pins preferred, release tags accepted, floating tags never — including
for companion containers.

**R11 — A recipe renders from this repository alone, or it does not exist.**
Every recipe is evaluated in CI against the real module system it targets, from
a minimal example configuration living here. A recipe that can only be proven
inside somebody's private cluster is unproven.

**R12 — Graduation moves code, never the app.**
When an app develops a mechanism others would want independently of the app, its
implementation leaves for its own project. Its identity in the site's namespace
does **not** change: same name, same category, same address, same exposure, same
row in the site's map. Graduation is a fact about this repository, not about the
deployment. Recipes that never develop a mechanism stay here permanently, and
that is the normal outcome.

**SUPERSEDED for the whole catalogue, 2026-08.** That last sentence described a
repository that was the only home an ordinary app had. It is not any more: every
application is now assigned to the repository whose SUBJECT it is, and each of
those declares its own. So the normal outcome became the opposite of the one
stated here — all 37 recipes left, none because it developed a mechanism.

The rule above is not wrong and is kept: graduation still moves CODE and never the
app, and an app's identity — its name, its category, its address, its exposure —
still survives the move unchanged. That is exactly what happened. What changed is
which repository is the destination, and the answer is no longer "a cookbook" but
"the one that owns the subject".

## Which rules are checked vs. reviewed

**Mechanically checked** (`nix flake check`):

- **R1** — every recipe fails with a useful message when enabled with no values.
- **R4** — each recipe's project equals its own category path segment.
- **R6/R8** — no recipe renders an Ingress, a fixed cluster address, replicas,
  resource limits, or placement constraints.
- **R10** — no image default is a floating tag.
- **R11** — every recipe renders, and every example evaluates.

**Reviewed, not automated:**

- **R2** — whether each default is genuinely portable knowledge.
- **R3** — whether a reason is present, and whether it is the real reason.
- **R5** — whether a recipe reads standalone.
- **R7** — whether a mount's backing is truly the operator's choice.
- **R9** — whether a declaration is genuinely a declaration.
- **R12** — whether something has earned graduation.
