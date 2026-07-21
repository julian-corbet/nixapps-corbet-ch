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
      # Extraction in progress: this repo is being pulled out of a private
      # production configuration. Planned app attrset:
      #
      #   kubernetesModules.llm-serving - the shared LLM lane (flagship, first):
      #                                   llama-swap + llama.cpp broker, LiteLLM
      #                                   front, store-scan config generator
      #
      # Further tenants (image generation, TTS, ...) follow as they are
      # generalized. GPU apps declare the nixgpu contract (priority class,
      # Recreate strategy, device token) and nothing else.
      kubernetesModules = { };

      lib = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
