{
  description = "nixapps — a cookbook of self-hosted application recipes for nixidy + Argo CD";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixidy renders these modules to Argo CD application manifests. Pinned so
    # that R11 ("every recipe renders from this repository alone") is checked
    # against a fixed module system rather than a moving target.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixidy }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;

      subdirs = path: lib.attrNames
        (lib.filterAttrs (_: t: t == "directory") (builtins.readDir path));

      # Discovered from the tree, never listed by hand. This is CONTRACT.md R4
      # made structural: the category is a path segment, so adding
      # `apps/<category>/<app>/` is the whole act of adding a recipe — there is
      # no central list of categories to update, here or anywhere else, and no
      # way for such a list to fall out of step with the directories.
      categories = subdirs ./apps;
    in
    {
      # nixidy modules, nested one level by category so the attribute path
      # mirrors both `apps/<category>/<app>` and each recipe's own
      # `options.nixapps.<category>.<app>`. A consumer writes
      # `modules = [ nixapps.nixidyModules.media.castopod ]`; nixidy only needs
      # each entry to resolve to a path, so the nesting is plain attribute
      # lookup on our own output, not something nixidy has to support.
      nixidyModules = lib.genAttrs categories
        (category: lib.genAttrs (subdirs (./apps + "/${category}"))
          (app: ./apps + "/${category}/${app}"));

      # R11, enforced. Renders EVERY recipe in the repository against the real
      # module system, from the placeholder values in `examples/all`. A recipe
      # that stops evaluating — or that grows a new required value without the
      # example supplying it — fails here instead of in somebody's cluster.
      #
      # `examples/minimal` is the same mechanism narrowed to one recipe, kept as
      # a self-contained flake a stranger can build standalone to see the
      # smallest real usage.
      #
      # # ⚠ THIS CHECK IS CURRENTLY VACUOUS, AND SAYING SO IS THE POINT. The
      # repository holds NO recipes: every one was handed to the repository that
      # ASSIGNMENTS §2 names as its owner. So `allRecipes` is empty, the
      # environment renders nothing but its own `apps` directory, and the build
      # succeeds having compared nothing at all.
      #
      # That is a correct result and a worthless one, and the two are easy to
      # confuse from a green tick. `recipe-count` states the number out loud and
      # fails if the count and the render disagree.
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          allRecipes = lib.concatMap
            (c: lib.attrValues self.nixidyModules.${c})
            categories;
          env = nixidy.lib.mkEnv {
            inherit pkgs;
            modules = allRecipes ++ [ ./examples/all/values.nix ];
          };
          count = lib.length allRecipes;
        in
        {
          # Building the environment package forces the whole manifest tree.
          all-recipes-render = env.environmentPackage;

          # The number, stated out loud, so a green tick cannot be mistaken for
          # coverage the repository no longer has.
          recipe-count = pkgs.runCommand "nixapps-recipe-count"
            { rendered = env.environmentPackage; } ''
            set -euo pipefail
            declared=${toString count}
            rendered=$(find -L "$rendered" -mindepth 1 -maxdepth 1 -type d ! -name apps | wc -l)
            echo "recipes declared: $declared"
            echo "recipes rendered: $rendered"
            if [ "$declared" -ne "$rendered" ]; then
              echo "the repository declares $declared recipes and renders $rendered" >&2
              exit 1
            fi
            if [ "$declared" -eq 0 ]; then
              echo
              echo "NOTE: this repository holds no recipes, so the render check above compared"
              echo "nothing. A green suite here means the shell is intact, never that a recipe"
              echo "works. Every recipe now lives with the repository that owns its app."
            fi
            touch $out
          '';
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
