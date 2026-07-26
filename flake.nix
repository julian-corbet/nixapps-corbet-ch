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
      checks = forAllSystems (system:
        let
          allRecipes = lib.concatMap
            (c: lib.attrValues self.nixidyModules.${c})
            categories;
          env = nixidy.lib.mkEnv {
            pkgs = nixpkgs.legacyPackages.${system};
            modules = allRecipes ++ [ ./examples/all/values.nix ];
          };
        in
        {
          # Building the environment package forces the whole manifest tree.
          all-recipes-render = env.environmentPackage;
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
