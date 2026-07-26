{
  description = "nixapps - curated self-hosted application modules for a nixidy + Argo CD cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixidy — renders these modules to Argo CD application manifests (the
    # rendered-manifests pattern). Pinned to the same rev the private
    # consumer cluster runs, so R11 ("every recipe renders from this
    # repository alone") is checked against the real module system, not a
    # moving target.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixidy }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      # nixidy modules (github:arnarg/nixidy) — imported into a nixidy env's
      # `modules` list. Tenants land here as they are generalized from the
      # originating production cluster (image generation, TTS, ...). The LLM
      # serving lane graduated to its own sibling project, nixllm. GPU apps
      # declare the nixgpu contract (priority class, Recreate strategy,
      # device token) and nothing else.
      #
      # Nested one level by category, mirroring `apps/<category>/<app>` and
      # each module's own `options.nixapps.<category>.<app>` (CONTRACT.md
      # R4 — "the category is a path segment, not an enumeration"; no
      # central list of categories exists anywhere else in this repo
      # either). Verified empirically (examples/minimal renders through
      # `nixidyModules.generic.web`, a two-level attribute path) that a
      # consumer doing `modules = [ nixapps.nixidyModules.<category>.<app> ]`
      # works exactly like a flat key — nixidy's `modules` list only needs
      # each entry to resolve to a path/attrset/function; the nesting is
      # plain Nix attribute lookup on OUR OWN output, not anything nixidy
      # itself has to support.
      nixidyModules = {
        advanced = {
          comfyui = ./apps/advanced/comfyui;
          tts = ./apps/advanced/tts;
        };
        generic = {
          web = ./apps/generic/web;
        };
        media = {
          castopod = ./apps/media/castopod;
        };
      };

      # The shared shape every recipe renders through (CONTRACT.md R5), exported
      # so a consumer writing their own recipe against this repo's conventions
      # gets the same option constructors and helpers rather than reinventing
      # them. `knowledge` and `value` are the interesting pair: they make R2's
      # split unwritable-wrong rather than merely documented — a knowledge option
      # with no default, or a value option with one, fails to evaluate.
      lib = import ./lib { inherit (nixpkgs) lib; };

      # R11 — "every recipe renders from this repository alone, or it does
      # not exist. Every recipe is evaluated in CI against the real module
      # system it targets, from a minimal example configuration living in
      # this repo." `examples/minimal/flake.nix` is that minimal example, a
      # fully self-contained flake anyone can build standalone
      # (`cd examples/minimal && nix build`). This check renders the
      # IDENTICAL env — same module, same values.nix, imported directly
      # rather than through a nested flake fetch (which would need
      # import-from-derivation) — so `nix flake check` here does the same
      # real rendering work: it forces nixidy to actually build the
      # manifest tree, and throws (assertion failure or eval error) if
      # `generic.web`, or any future module wired in beside it, is broken.
      checks = forAllSystems (system:
        let
          env = nixidy.lib.mkEnv {
            pkgs = nixpkgs.legacyPackages.${system};
            modules = [
              self.nixidyModules.generic.web
              self.nixidyModules.media.castopod
              ./examples/minimal/values.nix
            ];
          };
        in
        {
          examples-minimal = env.environmentPackage;
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
