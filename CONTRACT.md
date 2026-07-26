# nixapps — the recipe contract

This file is the **fixed target**: *what a recipe is*, and what this repository
will and will not contain. The rules are the spec; the modules under `apps/`
are one set of instances. When a module and this contract disagree, the
contract wins — and if a rule itself is wrong, fix it *here*, not in a commit
message.

Most rules below are mechanically checkable, and the checkable ones double as
this repo's test suite (see the last section).

## What this repository is

**A recipe book for ordinary applications.** Each recipe describes one app
completely enough that a stranger can deploy it, and configures nothing about
any particular site. The cooking happens elsewhere: an operator pairs each
recipe with a small values file naming the handful of things that are true only
of their cluster.

That division is the whole design. A recipe carries *knowledge* — the port this
app listens on, the path it writes to inside its container, how long it takes
to become ready, why it must not run two replicas. A values file carries
*facts about one site* — where that state actually lives, what the workload is
called here, which secret holds the credentials.

## What this repository is not

Four concerns are deliberately absent, each owned elsewhere:

- **The operating system.** Not here.
- **The delivery mechanism.** How manifests are rendered, committed, synced,
  grouped into projects and anchored into namespaces is a separate layer. This
  repo produces application definitions and hands them over.
- **Hardware arbitration.** Deciding who gets scarce shared hardware, in what
  order, and what happens to whoever loses is a separate layer. Recipes here
  *declare* against that arbiter (R9); none of them implements any part of it.
- **Theses.** An app whose implementation becomes interesting independently of
  the app leaves (R12). What stays here is the run-of-the-mill.

The consequence worth stating plainly: this repo will never grow an
autoscaler, an ingress controller, a storage provisioner, a device plugin, or a
project renderer. It consumes all of them and implements none.

## The namespace this repo renders into

A deployed application has **one identity with several renderings**: a name, a
category, an address, the namespace it runs in, and a decision about who may
reach it. Those renderings belong to the *site*, not to this repository — the
site's own map is the authority on them, and it lists apps sourced from here
alongside apps sourced from anywhere else, in one uniform form. Nothing in that
map records which repository an app's code came from, because it does not
matter.

This repo touches exactly one of those renderings: a recipe declares itself at
`nixapps.<category>.<app>`, which mirrors the site's categories so that reading
either one teaches you the other. Mirroring is not ownership — see R4.

## Rules

**R1 — A recipe describes one app completely, and configures nothing.**
A recipe renders every workload, service, mount, probe and label the app needs
to run. It supplies no site-specific value. Enabling a recipe and nothing else
must **fail loudly**, naming the values the operator still owes — never start
something half-configured.

**R2 — Every option is either knowledge or a value, and its default says which.**
*Knowledge* — upstream image, container port, internal mount path, probe
timing, update strategy, the environment keys the app requires — carries a
default, so a stranger gets a working app. A *value* — where state lives, what
this workload is called on this cluster, which secret holds the credentials,
sizing for this hardware — carries **no default** and fails evaluation when
unset.

This makes the division testable rather than aspirational: evaluate a recipe
with only `enable = true`, and the set of options that fail must equal the set
of values. A knowledge option with no default is a trap; a value option with a
default is a lie about portability. Both are bugs.

**R3 — The reason travels with the setting.**
Any non-obvious choice states *why* in its option description: this app runs a
single replica because one writer owns its media directory; this readiness
probe grants three minutes because the app migrates its database on first boot.
A recipe without its reasons is a manifest with extra syntax — the reasons are
the reason to publish it at all.

**R4 — The category is a path segment, not an enumeration.**
A recipe declares itself at `nixapps.<category>.<app>`. **No central list of
categories exists anywhere in this repository** — each recipe simply states
where it files itself. The category supplies the default for the app's delivery
project, so the two cannot drift apart, and remains overridable for anyone
whose taxonomy differs. This repo mirrors a taxonomy; it does not export one.

**R5 — Shape is shared; identity is not.**
No two recipes duplicate a rendering. Anything true of more than one app — the
web-tenant shape, probe construction, storage attachment, wake labels, the
hardware-arbiter fragment — lives in `lib` and is called. A recipe contains
only what is true of that one app. Duplication between two recipes is a missing
`lib` function.

**R6 — Exposure is intent, never topology.**
A recipe renders a Service and stops. How that Service is reached — an ingress
controller, a tunnel, an overlay, a fixed address, nothing at all — is a
property of the site, supplied as a value. This repository contains no opinion
about ingress and no reference to any particular network.

**R7 — Storage is a mount, not a backing.**
A recipe declares that the app needs state at a path inside its container.
What backs that path — a host directory, a claim, ephemeral space — is a value.
A recipe that can only be backed one way is not portable, and is not finished.

**R8 — Lifecycle is intent, never a mechanism.**
A recipe declares that it runs always, or that it may be woken on demand.
Which front does the waking, and where that front lives, is a value. A recipe
never bundles an autoscaler or a waiting page.

**R9 — Hardware consumers declare; they never manage.**
An app holding scarce shared hardware declares the arbiter's contract — a
priority, a device token, an update strategy that never overlaps two holders —
through the one shared fragment in `lib`, and nothing more. It never reads
device state, never sets thresholds, never evicts anything. The arbiter is not
in this repo and recipes must not reimplement fragments of it.

**R10 — Images are pinned. `latest` is never a default.**
A moving tag changes behavior between deploys with nothing to review
beforehand. Digest pins are preferred, release tags accepted, floating tags
never — including for companion containers.

**R11 — A recipe renders from this repository alone, or it does not exist.**
Every recipe is evaluated in CI against the real module system it targets, from
a minimal example configuration living in this repo. A recipe that can only be
proven inside somebody's private cluster is unproven.

**R12 — Graduation moves code, never the app.**
When an app develops a mechanism that others would want independently of the
app itself, its implementation leaves for its own project. Its identity in the
site's namespace does **not** change: same name, same category, same address,
same exposure, same row in the site's map. Graduation is a fact about this
repository, not about the deployment. Recipes that never develop a mechanism
stay here permanently, and that is the normal outcome.

## Which rules are checked vs. reviewed

**Mechanically checked** (`nix flake check`):

- **R1** — every recipe fails with a useful message when enabled with no values.
- **R2** — the default audit: options with defaults vs. options that fail,
  compared against each recipe's declared value set.
- **R4** — each recipe's default project equals its own category path segment.
- **R5** — no rendering primitive is constructed outside `lib`.
- **R6/R7/R8** — no recipe renders an Ingress, hard-codes a storage backing, or
  emits an autoscaler object.
- **R10** — no image default is a floating tag.
- **R11** — every recipe renders, and every example evaluates.

**Reviewed, not automated:**

- **R3** — whether a reason is present, and whether it is the real reason.
- **R9** — whether a declaration is genuinely a declaration.
- **R12** — whether something has earned graduation.

## Status of this contract

Written before the reorganization it describes, deliberately: the rules are the
target the modules are being moved onto, not a description of where they
already are. Rules already satisfied by the existing modules, rules newly
imposed, and the checks that enforce them are tracked in the README's status
section — which states what is proven and what is merely intended, and never
conflates the two.
