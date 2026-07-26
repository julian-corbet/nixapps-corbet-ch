# The "values" half of the split CONTRACT.md describes (R1/R2): every field
# below is a FACT ABOUT ONE SITE, never knowledge about the app — which is why
# the recipes carry no default for any of them.
#
# Everything here is a generic placeholder. No real hostname, no private
# address, no host path from anybody's cluster. Swap them for your own site's
# facts and this renders your own apps.
#
# Shared by two consumers so there is exactly one copy of "what this example
# renders": examples/minimal/flake.nix (a self-contained flake anyone can build
# standalone) and the root flake's `checks` output, so `nix flake check` at the
# repo root does the same real rendering work.
{
  # Required by the nixidy ENVIRONMENT, not by any recipe here — a nixidy env
  # cannot render without knowing where it would commit to.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  # The reference recipe. These are exactly the facts it refuses to guess;
  # remove any one of them and the render fails naming what is missing.
  nixapps.media.castopod = {
    enable = true;
    namespace = "podcast";
    secretName = "castopod-env";
    mediaPath = "/var/lib/example/castopod/media";
  };
}
