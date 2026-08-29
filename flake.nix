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

    nixk3s = {
      url = "github:julian-corbet/nixk3s-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixidy.follows = "nixidy";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixidy,
      nixk3s,
    }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems f;

      subdirs = path: lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir path));

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
      nixidyModules = lib.genAttrs categories (
        category: lib.genAttrs (subdirs (./apps + "/${category}")) (app: ./apps + "/${category}/${app}")
      );

      # R11, enforced. Renders EVERY recipe in the repository against the real
      # module system, from the placeholder values in `examples/all`. A recipe
      # that stops evaluating — or that grows a new required value without the
      # example supplying it — fails here instead of in somebody's cluster.
      #
      # `examples/minimal` is the same mechanism narrowed to one recipe, kept as
      # a self-contained flake a stranger can build standalone to see the
      # smallest real usage.
      #
      # `recipe-count` states both sides out loud so a green render cannot hide a
      # recipe that discovery skipped or an unexpected application directory.
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          allRecipes = lib.concatMap (c: lib.attrValues self.nixidyModules.${c}) categories;
          env = nixidy.lib.mkEnv {
            inherit pkgs;
            modules = [
              nixk3s.nixidyModules.tenancy
              nixk3s.nixidyModules.apps
              nixk3s.nixidyModules.addressing
            ]
            ++ allRecipes
            ++ [ ./examples/all/values.nix ];
          };
          count = lib.length allRecipes;
        in
        {
          # Building the environment package forces the whole manifest tree.
          all-recipes-render = env.environmentPackage;

          # Every discovered recipe must render at least one workload. A recipe
          # may deliberately expand into several applications, as naming does.
          recipe-count = pkgs.runCommand "nixapps-recipe-count" { rendered = env.environmentPackage; } ''
            set -euo pipefail
            declared=${toString count}
            rendered=$(find -L "$rendered" -mindepth 1 -maxdepth 1 -type d ! -name apps | wc -l)
            echo "recipes declared: $declared"
            echo "workloads rendered: $rendered"
            if [ "$rendered" -lt "$declared" ]; then
              echo "the repository declares $declared recipes but renders only $rendered workloads" >&2
              exit 1
            fi
            touch $out
          '';

          # Naming carries private ideas and credentials. Prove from the rendered
          # objects—not from module intent—that only the web and API have ClusterIP
          # Services, no public route exists, and every queue consumer is portless.
          naming-private-exposure =
            pkgs.runCommand "nixapps-naming-private-exposure"
              {
                rendered = env.environmentPackage;
                nativeBuildInputs = [ pkgs.yq-go ];
              }
              ''
                set -euo pipefail

                service_count=$(find -L "$rendered" -type f -name 'Service-*.yaml' | wc -l)
                if [ "$service_count" -ne 2 ]; then
                  echo "naming must render exactly two Services, found $service_count" >&2
                  exit 1
                fi

                while IFS= read -r manifest; do
                  kind=$(yq -r '.kind // ""' "$manifest")
                  case "$kind" in
                    Ingress|Gateway|HTTPRoute|GRPCRoute|TCPRoute|TLSRoute)
                      echo "naming rendered forbidden route kind $kind" >&2
                      exit 1
                      ;;
                  esac
                done < <(find -L "$rendered" -type f -name '*.yaml')

                for service in "$rendered/naming/Service-naming.yaml" \
                               "$rendered/naming-api/Service-naming-api.yaml"; do
                  test -f "$service"
                  test "$(yq -r '.spec.type' "$service")" = ClusterIP
                done
                test "$(yq -r '.metadata.labels."nixk3s.dev/exposure"' \
                  "$rendered/naming/Service-naming.yaml")" = nb
                test "$(yq -r '.metadata.labels."nixk3s.dev/exposure"' \
                  "$rendered/naming-api/Service-naming-api.yaml")" = internal

                for role in naming-worker naming-indexer naming-verifier; do
                  deployment="$rendered/$role/Deployment-$role.yaml"
                  test -f "$deployment"
                  test ! -e "$rendered/$role/Service-$role.yaml"
                  test "$(yq -r '.metadata.labels."nixk3s.dev/exposure"' "$deployment")" = internal
                  test "$(yq -r '[.spec.template.spec.containers[].ports[]?] | length' "$deployment")" = 0
                done

                touch $out
              '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
