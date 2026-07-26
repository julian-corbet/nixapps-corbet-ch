# Examples

[`minimal/`](minimal) is a self-contained flake that renders
[`apps/generic/web`](../apps/generic/web) through
[nixidy](https://github.com/arnarg/nixidy), unmodified, with only generic
placeholder values (`example.com`, no real hostnames or IPs). It is this
repo's proof, per `CONTRACT.md` R11, that a recipe here renders from this
repository alone:

```console
cd examples/minimal
nix build .#checks.x86_64-linux.default   # or .#packages.<system>.default
```

The root flake's own `nix flake check` renders the identical env from
[`minimal/values.nix`](minimal/values.nix) as well, so CI catches a broken
module without needing this directory built separately.
