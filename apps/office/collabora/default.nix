# nixapps.office.collabora — Collabora Online / CODE, a WOPI office backend.
#
# What this recipe knows about Collabora:
#
#   - It is a WOPI office editor for Nextcloud (richdocuments app) and also
#     works as a standalone office suite. A WOPI host sends a document URL and
#     access token; Collabora fetches and edits it, writing changes back via
#     WOPI callback.
#   - It is stateless: no persistent data. Documents and user state live in the
#     WOPI host. The only state is transient session/editing metadata, kept in
#     memory.
#   - Configuration is environment-based: the WOPI host's URL (as a regex) and
#     Collabora's own public hostname must be supplied. No static volumes needed.
#   - It listens on port 9980 (non-standard, intentional). TLS termination
#     happens upstream (Cloudflare, nginx, etc.); the in-container server runs
#     in insecure mode (no self-signed cert generation) and sets ssl.termination=true
#     to declare upstream HTTPS.
#   - The readiness probe is quick (no initial delay): Collabora starts in
#     seconds and has no migrations to run.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.office.collabora;
  name = "collabora";
in
{
  options.nixapps.office.collabora = {
    enable = lib.mkEnableOption "Collabora Online / CODE, a WOPI office backend";

    namespace = lib.mkOption {
      type = lib.types.str;
      description = "Namespace to deploy into.";
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this application creates its own namespace. Set false if
        something else in your cluster owns it already. Collabora typically
        shares the office namespace with EuroOffice or similar editors.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "collabora/code:26.04.2.4@sha256:1f864ce3f0c49e867787b6dd303bd6ba989542d3023f6809df558eafd04c1b97";
      description = ''
        Container image, pinned to 26.04.2.4 by digest.

        A floating tag can change behavior between deploys with nothing to review
        beforehand. The image is pinned by digest; to update it, edit this option
        and move the pin deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9980;
      description = "Port Collabora's WOPI server listens on inside the container.";
    };

    nextcloudAliasgroup = lib.mkOption {
      type = lib.types.str;
      description = ''
        Regular expression matching the WOPI host (Nextcloud, etc.) that this
        Collabora instance accepts connections from. Used to validate incoming
        WOPI_SRC URLs. The regex must NOT include a port; COOLWSD parses it as
        a URI and rejects (:443)? suffixes. WOPI_SRC is portless (https default).

        Example: "https://nextcloud\\.example\\.com"
      '';
    };

    serverName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Public hostname of this Collabora instance. Used to set server_name
        and must match the URL the WOPI host calls back to for callbacks.

        Example: "collabora.example.com"
      '';
    };

    dictionaries = lib.mkOption {
      type = lib.types.str;
      default = "en_US de_DE de_CH";
      description = ''
        Space-separated list of spell-check language tags to load.
        Example: "en_US de_DE fr_FR pt_BR"
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "office";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. Collabora is stateless, but simultaneous
          # pods with different configurations could confuse clients that cache
          # capability discovery.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;

                env = {
                  aliasgroup1 = {
                    name = "aliasgroup1";
                    value = cfg.nextcloudAliasgroup;
                  };
                  server_name = {
                    name = "server_name";
                    value = cfg.serverName;
                  };
                  extra_params = {
                    name = "extra_params";
                    value = "--o:ssl.enable=false --o:ssl.termination=true";
                  };
                  DONT_GEN_SSL_CERT = {
                    name = "DONT_GEN_SSL_CERT";
                    value = "true";
                  };
                  dictionaries = {
                    name = "dictionaries";
                    value = cfg.dictionaries;
                  };
                };

                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };

                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 10;
                  failureThreshold = 12;
                };
              };
            };
          };
        };

        services.${name}.spec = {
          type = "ClusterIP";
          selector.app = name;
          ports.http = {
            name = "http";
            port = cfg.port;
            targetPort = cfg.port;
          };
        };
      };
    };
  };
}
