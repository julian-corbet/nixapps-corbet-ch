# Placeholder values for every recipe in this repository — the file that makes
# CONTRACT.md R11 real ("a recipe renders from this repository alone, or it does
# not exist"). The root flake's `nix flake check` renders all of it, so a recipe
# that cannot render, or that quietly grows a required value nobody supplies,
# fails CI rather than failing in somebody's cluster.
#
# Every value here is exactly the kind of thing a recipe refuses to guess: a
# namespace, a host directory, the name of a Secret or ConfigMap it will not
# create, a public URL, or an identity-provider coordinate. Nothing here is real
# and no credential appears in any form. Enabling every recipe at once is not a
# deployment anyone would want; it is a proof that each one still renders.
{
  # Required by the nixidy environment itself, not by any recipe here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixapps.apps.naming = {
    enable = true;
    namespace = "example-naming";
    siteConfigMapName = "example-naming-site";
    nginxConfigMapName = "example-naming-nginx";
  };
}
