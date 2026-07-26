# nixapps.files.opencloud — OpenCloud, a Nextcloud alternative for file sync and collaboration.
#
# What this recipe knows about OpenCloud:
#
#   - It is a single-binary microservices platform (opencloudeu/opencloud-rolling),
#     ~20 services bundled into one container. The WOPI collaboration service runs
#     in-process (no separate pod needed). The only external service is EuroOffice
#     for document editing.
#   - Two initContainers run before the main service: `init` generates the internal
#     secret config (idempotent — only runs once), and `seed-config` overlays the
#     declarative role-mapping (proxy.yaml) and CSP policy (csp.yaml) into the
#     config directory each startup. The main container reads those configs and the
#     generated secrets.
#   - Two persistent host paths: the state directory (config, idm boltdb, NATS
#     id-cache, search index, thumbnails) and the userfiles directory (plain POSIX
#     readable files). Both are mounted with xattr=sa (load-bearing for file-ID
#     tracking). The container runs as uid 3036 (opencloud); both directories must
#     be owned 3036:3036. fsGroup is omitted because hostPath mounts would rechown
#     them.
#   - It requires OIDC for authentication. pocket-id is configured by default; swap
#     OC_OIDC_ISSUER and WEB_OIDC_METADATA_URL for your provider.
#   - Collaborative mode (WATCH_FS=true) watches the POSIX storage directory with
#     inotifywait, so writes from SMB or direct filesystem access show up live. This
#     requires inotify ulimits on the host and the node's sysctl already configured
#     (handled separately by your cluster infrastructure).
#   - It runs with Recreate strategy: two pods on the same POSIX tree (shared NATS,
#     boltdb, inotify) would corrupt state.
#   - The image is pinned to a specific tag (7.2.0 is current stable; rolling is an
#     alternative stable channel). Never use "latest".
#
{ lib, config, ... }:
let
  cfg = config.nixapps.files.opencloud;
  name = "opencloud";
in
{
  options.nixapps.files.opencloud = {
    enable = lib.mkEnableOption "OpenCloud, a file sync and collaboration platform";

    namespace = lib.mkOption {
      type = lib.types.str;
      description = "Namespace to deploy into. Shared with other cloud apps (e.g. nextcloud).";
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this application creates its own namespace. Set false if
        something else in your cluster owns it already.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "opencloudeu/opencloud-rolling:7.2.0";
      description = ''
        Container image, pinned by tag. Never use "latest"; always choose a
        specific stable version.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9200;
      description = ''
        Port the OpenCloud server listens on. This port serves the web UI,
        and also handles WOPI endpoints (/wopi, /collaboration) for the
        in-process collaboration service.
      '';
    };

    statePath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory for OpenCloud state (config directory, idm boltdb, NATS
        id-cache, search index, thumbnails). Mounted at /var/lib/opencloud
        and /etc/opencloud (subPath: config).
        Must be owned 3036:3036 (opencloud).
      '';
    };

    userfilesPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory for user files (plain POSIX readable files). Mounted at
        /var/lib/opencloud/storage/users.
        Must be owned 3036:3036 (opencloud).
      '';
    };

    publicUrl = lib.mkOption {
      type = lib.types.str;
      description = ''
        Public HTTPS URL for OpenCloud. Used for OAuth redirect URIs and
        WOPI client callbacks. E.g., https://opencloud.example.com.
      '';
    };

    publicDomain = lib.mkOption {
      type = lib.types.str;
      description = ''
        Public domain name (without https://). Used for cookie domains and
        same-origin policy checks. E.g., opencloud.example.com.
      '';
    };

    oidcIssuer = lib.mkOption {
      type = lib.types.str;
      description = ''
        OIDC issuer URL for authentication. E.g., https://id.example.com.
        OpenCloud will fetch the .well-known/openid-configuration from here.
        Required. If unset or left as a placeholder, OpenCloud will fail to
        authenticate users at startup with metadata fetch errors.
      '';
    };

    oidcMetadataUrl = lib.mkOption {
      type = lib.types.str;
      description = ''
        Full URL to the OIDC metadata endpoint.
        E.g., https://id.example.com/.well-known/openid-configuration.
      '';
    };

    oidcClientId = lib.mkOption {
      type = lib.types.str;
      description = ''
        OAuth2 client ID registered with your OIDC provider. This is the public
        identifier (no secret needed; the web client is public).
      '';
    };

    oidcScope = lib.mkOption {
      type = lib.types.str;
      default = "openid profile email groups";
      description = ''
        Space-separated OIDC scopes to request. Must include "groups" if
        using group-based role assignment.
      '';
    };

    euroofficeUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        URL for EuroOffice (the collaborative document editor). OpenCloud
        points users to this service for WOPI document editing.
        Optional: set to null to disable document editing; users will see
        only read-only previews. If set to a placeholder URL, document
        editing will silently fail to connect.
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "Log level for OpenCloud: debug, info, warn, error.";
    };

    excludeRunServices = lib.mkOption {
      type = lib.types.str;
      default = "idp,search";
      description = ''
        Comma-separated list of services to exclude from startup.
        - idp: internal identity provider (use external OIDC instead)
        - search: full-text search (can be unstable in early 7.x)
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "files";

      resources = {
        deployments.${name}.spec = {
          strategy.type = "Recreate";  # single writer on POSIX tree + embedded NATS/idm
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              securityContext = {
                runAsUser = 3036;
                runAsGroup = 3036;
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
                # fsGroup intentionally omitted (would recursively chown hostPath)
              };
              initContainers = {
                init = {
                  name = "init";
                  image = cfg.image;
                  command = [ "sh" "-c" "test -f /etc/opencloud/opencloud.yaml || opencloud init --insecure yes" ];
                  volumeMounts.state = {
                    name = "state";
                    mountPath = "/etc/opencloud";
                    subPath = "config";
                  };
                };
                seed-config = {
                  name = "seed-config";
                  image = "busybox:1.36";
                  command = [ "sh" "-c" "cp -f /cfgsrc/csp.yaml /cfgsrc/proxy.yaml /etc/opencloud/ && echo seeded csp.yaml+proxy.yaml" ];
                  volumeMounts = {
                    state = {
                      name = "state";
                      mountPath = "/etc/opencloud";
                      subPath = "config";
                    };
                    cfgsrc = {
                      name = "cfgsrc";
                      mountPath = "/cfgsrc";
                    };
                  };
                };
              };
              containers.${name} = {
                name = name;
                image = cfg.image;
                command = [ "opencloud" "server" ];
                env = {
                  OC_URL.value = cfg.publicUrl;
                  OC_DOMAIN.value = cfg.publicDomain;
                  WEB_ASSET_THEMES_PATH.value = "/var/lib/opencloud/web/assets/themes";
                  WEB_UI_THEME_SERVER.value = cfg.publicUrl;
                  PROXY_TLS.value = "false";  # TLS terminates at ingress
                  OC_INSECURE.value = "true";
                  PROXY_HTTP_ADDR.value = "0.0.0.0:${toString cfg.port}";
                  OC_LOG_LEVEL.value = cfg.logLevel;
                  IDM_CREATE_DEMO_USERS.value = "false";
                  OC_OIDC_ISSUER.value = cfg.oidcIssuer;
                  OC_EXCLUDE_RUN_SERVICES.value = cfg.excludeRunServices;
                  PROXY_OIDC_REWRITE_WELLKNOWN.value = "true";
                  PROXY_OIDC_ACCESS_TOKEN_VERIFY_METHOD.value = "none";
                  PROXY_AUTOPROVISION_ACCOUNTS.value = "true";
                  PROXY_USER_OIDC_CLAIM.value = "preferred_username";
                  PROXY_USER_CS3_CLAIM.value = "username";
                  GRAPH_USERNAME_MATCH.value = "none";
                  WEB_OIDC_CLIENT_ID.value = cfg.oidcClientId;
                  WEB_OIDC_METADATA_URL.value = cfg.oidcMetadataUrl;
                  WEB_OIDC_SCOPE.value = cfg.oidcScope;
                  PROXY_ROLE_ASSIGNMENT_DRIVER.value = "oidc";
                  PROXY_ROLE_ASSIGNMENT_OIDC_CLAIM.value = "groups";
                  STORAGE_USERS_DRIVER.value = "posix";
                  STORAGE_USERS_POSIX_ROOT.value = "/var/lib/opencloud/storage/users";
                  STORAGE_USERS_ID_CACHE_STORE.value = "nats-js-kv";
                  STORAGE_USERS_ID_CACHE_STORE_NODES.value = "127.0.0.1:9233";
                  STORAGE_USERS_POSIX_WATCH_FS.value = "true";
                  STORAGE_USERS_POSIX_WATCH_TYPE.value = "inotifywait";
                  STORAGE_USERS_POSIX_WATCH_PATH.value = "/var/lib/opencloud/storage/users";
                  MICRO_REGISTRY_ADDRESS.value = "127.0.0.1:9233";
                  PROXY_CSP_CONFIG_FILE_LOCATION.value = "/etc/opencloud/csp.yaml";
                  OC_ADD_RUN_SERVICES.value = "collaboration";
                  COLLABORATION_APP_NAME.value = "EuroOffice";
                  COLLABORATION_APP_PRODUCT.value = "OnlyOffice";
                  COLLABORATION_APP_INSECURE.value = "true";
                  COLLABORATION_WOPI_SRC.value = cfg.publicUrl;
                } // lib.optionalAttrs (cfg.euroofficeUrl != null) {
                  COLLABORATION_APP_ADDR.value = cfg.euroofficeUrl;
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = [ "ALL" ];
                };
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                readinessProbe = {
                  tcpSocket.port = cfg.port;
                  initialDelaySeconds = 20;
                  periodSeconds = 10;
                  failureThreshold = 30;
                };
                livenessProbe = {
                  tcpSocket.port = cfg.port;
                  initialDelaySeconds = 90;
                  periodSeconds = 30;
                  failureThreshold = 6;
                };
                volumeMounts = {
                  state = {
                    name = "state";
                    mountPath = "/var/lib/opencloud";
                  };
                  state-config = {
                    name = "state";
                    mountPath = "/etc/opencloud";
                    subPath = "config";
                  };
                  userfiles = {
                    name = "userfiles";
                    mountPath = "/var/lib/opencloud/storage/users";
                  };
                  theme = {
                    name = "theme";
                    mountPath = "/var/lib/opencloud/web/assets/themes";
                    readOnly = true;
                  };
                };
              };
              volumes = {
                state = {
                  name = "state";
                  hostPath = {
                    path = cfg.statePath;
                    type = "Directory";
                  };
                };
                userfiles = {
                  name = "userfiles";
                  hostPath = {
                    path = cfg.userfilesPath;
                    type = "Directory";
                  };
                };
                cfgsrc = {
                  name = "cfgsrc";
                  configMap.name = "opencloud-config";
                };
                theme = {
                  name = "theme";
                  configMap = {
                    name = "opencloud-theme";
                    items = [
                      { key = "theme.json"; path = "opencloud/theme.json"; }
                      { key = "logo.svg"; path = "opencloud/assets/logo.svg"; }
                      { key = "logo-mobile.svg"; path = "opencloud/assets/logo-mobile.svg"; }
                      { key = "favicon.svg"; path = "opencloud/assets/favicon.svg"; }
                    ];
                  };
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

        configMaps.opencloud-config.data = {
          "csp.yaml" = ''
            directives:
              child-src:    ["'self'"]
              connect-src:
                - "'self'"
                - "blob:"
                - "https://raw.githubusercontent.com/opencloud-eu/awesome-apps/"
                - "https://update.opencloud.eu/"
              default-src:  ["'none'"]
              frame-ancestors: ["'self'"]
              form-action: ["'self'"]
              img-src:      ["'self'", "data:", "blob:"]
              manifest-src: ["'self'"]
              media-src:    ["'self'"]
              object-src:   ["'self'", "blob:"]
              script-src:   ["'self'", "'unsafe-inline'"]
              style-src:    ["'self'", "'unsafe-inline'"]
          '';
          "proxy.yaml" = ''
            role_assignment:
              driver: oidc
              oidc_role_mapper:
                role_claim: groups
                role_mapping: []
          '';
        };
      };
    };
  };
}
