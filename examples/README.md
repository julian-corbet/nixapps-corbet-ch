# Examples

Two examples, both proving the same thing per `CONTRACT.md` R11 — that a
recipe renders from this repository alone — at different scales.

[`minimal/`](minimal) is a self-contained flake that renders one recipe,
[`apps/media/castopod`](../apps/media/castopod), through
[nixidy](https://github.com/arnarg/nixidy), unmodified, with only generic
placeholder values (`example.com`, no real hostnames, IPs, or filesystem
paths). It is the smallest real usage, buildable on its own:

```console
cd examples/minimal
nix build
```

[`all/`](all) holds placeholder values for **every** recipe in the
repository, in [`all/values.nix`](all/values.nix). The root flake's own
`nix flake check` renders all 38 recipes against these values in one pass,
which is what makes R11 real for the whole repository rather than just one
recipe: a recipe that stops evaluating, or that quietly grows a required
value nobody supplies, fails CI instead of failing in somebody's cluster.

`all/values.nix` was generated from the recipes' own option surface: every
option with no default got a placeholder derived from its name. Adding a
recipe means regenerating this file, and the check fails until you do.
