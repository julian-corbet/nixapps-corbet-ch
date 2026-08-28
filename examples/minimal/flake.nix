{
  description = "nixapps minimal example — renders the reference recipe through nixidy, unmodified, using only generic placeholder values";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The repository this example lives in, unmodified — proving the recipe
    # renders from nixapps alone (CONTRACT.md R11).
    nixapps = {
      url = "path:../..";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixidy.follows = "nixidy";
      inputs.nixk3s.follows = "nixk3s";
    };

    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixk3s = {
      url = "github:julian-corbet/nixk3s-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixidy.follows = "nixidy";
    };
  };

  outputs = { self, nixpkgs, nixapps, nixidy, nixk3s }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      # `nix run .#nixidy -- build .#example` (the nixidy CLI resolves
      # `<flake>#nixidyEnvs.<system>.<env>`), or plain
      # `nix build .#nixidyEnvs.<system>.example.environmentPackage` /
      # `.#checks.<system>.default` / `.#packages.<system>.default` below —
      # all four build the exact same rendered manifest tree.
      nixidyEnvs = forAllSystems (system: nixidy.lib.mkEnvs {
        pkgs = nixpkgs.legacyPackages.${system};
        envs.example.modules = [
          nixk3s.nixidyModules.tenancy
          nixk3s.nixidyModules.apps
          nixk3s.nixidyModules.addressing
          # The existing recipe, imported unchanged, through a nested
          # `nixidyModules.<category>.<app>` attribute path that mirrors
          # `apps/apps/naming` (see the root flake's comment on
          # `nixidyModules` for why this nests one level).
          nixapps.nixidyModules.apps.naming
          ./values.nix
        ];
      });

      packages = forAllSystems (system: {
        default = self.nixidyEnvs.${system}.example.environmentPackage;
      });

      checks = forAllSystems (system: {
        default = self.nixidyEnvs.${system}.example.environmentPackage;
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
