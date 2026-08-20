# Placeholder values for EVERY recipe in this repository — the file that makes
# CONTRACT.md R11 real ("a recipe renders from this repository alone, or it does
# not exist"). The root flake's `nix flake check` renders all of it, so a recipe
# that cannot render, or that quietly grows a required value nobody supplies,
# fails CI rather than failing in somebody's cluster.
#
# Every value here is exactly the kind of thing a recipe refuses to guess: a
# namespace, a host directory, the name of a Secret it will not create, a public
# URL, an identity-provider coordinate. Nothing here is real — the hostnames are
# under example.com, the paths are under /var/lib/example, and no credential
# appears in any form. Enabling all 38 apps at once is not a deployment anyone
# would want; it is a proof that each one still renders.
#
# This file was generated from the recipes' own option surface: every option
# with no default got a placeholder derived from its name. Regenerating after
# adding a recipe is mechanical, and the check fails until you do.
{
  # Required by the nixidy environment itself, not by any recipe here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";





































}
