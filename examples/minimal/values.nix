# The "values" half of the recipe/values split this repo's CONTRACT.md
# describes (R1/R2): every field below is a FACT ABOUT ONE SITE, not
# knowledge about the app — which is why the recipe itself
# (../../apps/generic/web/default.nix) carries no default for any of them.
# Everything here is a generic placeholder — no real hostname, no private
# IP, no corbet.ch — swap them for your own site's facts and this renders
# your own app.
#
# Shared by two consumers so there is exactly one copy of "what this example
# renders" (CONTRACT.md R5): examples/minimal/flake.nix (a self-contained
# flake anyone can build standalone) and the root flake's `checks` output
# (so `nix flake check` at the repo root does real rendering work too).
{
  # nixidy.target.{repository,branch} have no default in nixidy itself (see
  # nixidy's modules/nixidy/default.nix) — required by the ENVIRONMENT, not
  # by this recipe, but a real nixidy env can't render without them either.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixapps.generic.web.enable = true;
  nixapps.generic.web.apps = [
    {
      # The five REQUIRED fields (apps/generic/web/default.nix has no
      # default for any of them) — everything else this module renders
      # (namespace, project, probes, replicas, ...) is knowledge with a
      # neutral default, supplied by the recipe, not by this file.
      name = "example-web";
      image = "ghcr.io/example-org/example-web:1.0.0"; # R10: pinned, never `latest`.
      port = 8080;
      healthPath = "/healthz";
      host = "example-web.example.com";
    }
  ];

  # The reference recipe from apps/media/castopod, with the five facts about
  # one site that it refuses to guess (CONTRACT.md R1/R2). Enable it with
  # anything less than this and the render fails naming what is missing.
  nixapps.media.castopod = {
    enable = true;
    namespace = "podcast";
    secretName = "castopod-env";
    storage.media.source.hostPath = "/var/lib/example/castopod/media";
  };
}
