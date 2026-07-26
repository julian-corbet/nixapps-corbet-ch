# lib/default.nix — the shared shape, exported as this flake's `lib`.
#
# Recipes under apps/ are thin on purpose: they hold what is true of one app and
# call into here for everything true of more than one (CONTRACT.md R5). If you
# find yourself writing a rendering in a recipe, it belongs in this directory.
#
# Read CONTRACT.md before adding anything here. In particular R2 — the
# knowledge/value split — is enforced by construction in options.nix rather than
# checked after the fact: a knowledge option that ships no default, or a value
# option that ships one, fails to evaluate.
{ lib }:
let
  options = import ./options.nix { inherit lib; };
  storage = import ./storage.nix { inherit lib options; };
  runtime = import ./runtime.nix { inherit lib options; };
  gpuContract = import ./gpu-contract.nix { inherit lib options; };
  web = import ./web.nix { inherit lib storage; };
in
{
  # R2/R4 — the two option constructors and the delivery envelope.
  inherit (options)
    knowledge
    value
    optionalValue
    envelope
    ;

  # R7 — a mount is knowledge, a backing is a value.
  inherit storage;

  # R8 — lifecycle as intent; probes and sizing as knowledge.
  inherit runtime;

  # R9 — the consumer half of a hardware arbiter's contract, declared once.
  gpu = gpuContract;

  # R5 — the shape 35 of 43 real applications have.
  inherit web;
}
