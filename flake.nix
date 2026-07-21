{
  description = "nixapps - curated self-hosted application modules for a nixidy + Argo CD cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
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
      nixidyModules = { };

      lib = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
