{
  description = "nixapps minimal example — renders apps/generic/web through nixidy, unmodified, using only generic placeholder values";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The repository this example lives in, unmodified — proving
    # apps/generic/web renders from nixapps alone (CONTRACT.md R11).
    nixapps.url = "path:../..";

    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixapps, nixidy }:
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
          # The EXISTING module, imported unchanged, through a nested
          # `nixidyModules.<category>.<app>` attribute path (mirrors
          # `apps/generic/web`; see the root flake's comment on
          # `nixidyModules` for why this nests one level).
          nixapps.nixidyModules.generic.web
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
