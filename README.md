# nixapps

**The recipe contract plus one current ordinary-app recipe: `apps.naming`.**

It was a cookbook of 37 recipes for ordinary self-hosted applications, rendered
to Argo CD manifests by [nixidy](https://github.com/arnarg/nixidy). Those original
recipes have since been handed to the repository that owns each application: the wiki
and the document managers to the office repository, the notebooks to the notes
one, the archives to the vault, and so on. An app is declared by the repository
whose subject it is, and a second description here was a duplicate nobody read.

What stays is the part that was never about any one app: [CONTRACT.md](CONTRACT.md),
the twelve rules stating what a recipe IS and where the line between knowledge and
values falls. Those rules now govern a dozen catalogues in a dozen repositories
instead of one directory here.

## The idea

Its value is *knowing the recipe*. That this app serves HTTP on 8080 with a web
server already in the image. That it migrates its own database on boot, so the
readiness probe has to be patient or a restart lands mid-migration. That its
documented Redis dependency is only a cache and can be pointed at a file handler
instead, removing a whole service. That it writes exactly one directory and
everything else is in the database. That setting `fsGroup` will silently rechown
your host directory.

That knowledge is expensive to acquire and cheap to copy, which is the entire
reason to publish it. The cooking happens elsewhere.

## The split

```nix
# Yours — the values a recipe refuses to guess.
nixapps.media.castopod = {
  enable     = true;
  namespace  = "podcast";
  secretName = "castopod-env";
  mediaPath  = "/srv/castopod/media";
};
```

Three lines of site facts. The image digest, the port, `Recreate`, the
three-minute readiness probe, the path it writes inside the container, and the
reasons for each all come from the recipe, because they are true wherever you run
Castopod.

The rule underneath it:

| | has a default | lives in |
|---|---|---|
| **knowledge** — true for anyone running this app | yes | here |
| **value** — true only for your site | **no** | your repo |

A value with a default would be a lie about portability: your deploy would build
fine and break at runtime, instead of failing at evaluation naming what it
needs — which is the one place it was cheap to catch.

```
error: The option `nixapps.media.castopod.secretName' was accessed
       but has no value defined. Try setting the option.
```

## What is deliberately not here

Recipes render no replicas, no resource limits, no node selectors, no Ingress, no
fixed cluster addresses, and no autoscalers. Those are decisions about one site's
hardware and network, and a cookbook has no opinion about your hardware.

Nothing is lost by leaving them out. These are NixOS-style modules, so your own
file merges your own tuning into the same attribute path:

```nix
# Your repo, not this one.
applications.castopod.resources.deployments.castopod.spec = {
  replicas = 2;
  template.spec.containers.castopod.resources.limits.memory = "2Gi";
};
```

There is also no shared helper library, on purpose. Each recipe is one file you
can read top to bottom; two recipes that look similar are two independent
statements about two different apps. A helper that saves a few lines but makes
you open a second file to understand the first is a net loss here.

## Layout

```
apps/<category>/<app>/default.nix     →  nixapps.<category>.<app>
```

The path is the option path, and the category is the Argo project, so the three
cannot drift. **No central list of categories exists** — the flake discovers them
by reading the directory, so adding a category means adding a directory.

`apps/apps/naming/` is the current recipe. It declares the portable web/API plus
portless search, snapshot-indexing, and fresh-verification workers for the Naming
product; deployment values and every private address remain in the consuming
repository. Consumers resolve its `naming-web` and `naming-runtime` identity roles
to the numeric users carried by the images.

## Rules

[CONTRACT.md](CONTRACT.md) is the design authority — twelve rules stating what a
recipe is, which of them CI checks and which are reviewed by a human. When a
recipe and the contract disagree, the contract wins.

## What is proven, and what is not

`nix flake check` renders every recipe in the repository against real nixidy from
the placeholder values in `examples/all/values.nix`.

**A green check means the discovered recipe count and real nixidy render agree.**
`recipe-count` states the number out loud and fails if discovery and rendering
ever disagree. The same check proves a recipe that stops evaluating, or grows a
required value nobody supplied, fails here instead of in a cluster.
Both directions are checked: the render passes, and removing a required value
fails by name. `examples/minimal` is the same mechanism narrowed to one recipe,
as a flake you can build standalone.

`apps.naming` is adopted in the production cluster through the private infra
consumer. The check remains a render proof; live verification is still a separate
deployment claim made by that consumer.

## Related projects

- [nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) — the cluster
  spine these recipes deploy onto. It holds the mechanism and knows nothing about
  what kind of apps you run.
- [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) — the GPU arbiter.
  It decides who gets a scarce card and in what order; it never uses one. The two
  recipes here that hold a card declare its contract and implement none of it.
- [nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) — the shared LLM
  serving lane. It started in this repository and graduated once it developed a
  mechanism worth having independently of the app.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
