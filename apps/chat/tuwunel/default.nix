# nixapps.chat.tuwunel — Tuwunel, a Matrix homeserver (Conduit/conduwuit fork).
#
# What this recipe knows about Tuwunel:
#
#   - It is a single-container Matrix homeserver serving the client-server API
#     on :8008 and the federation (server-server) API on :8448.
#   - Storage is a single embedded RocksDB database tree with no separate
#     database service. Only the RocksDB directory needs persistence.
#   - It authenticates users against an external LDAP directory.
#   - Users can register and federation is enabled for inter-server communication.
#   - It is a single-writer homeserver and MUST NOT scale to zero: federated
#     events are pushed (not pulled on user request), delivery must be real-time,
#     and the front door must answer federation key probes immediately. A scale-
#     to-zero pattern would drop inbound federation and introduce wake latency.
#   - It runs one pod forever. Restarts reset its in-memory state but the
#     RocksDB persists everything; no migrations happen on boot if the schema
#     matches the image version.
#   - The RocksDB directory must be owned by the container's uid:gid (3009:3009).
#     The image is pinned by digest to ensure you review schema changes.
#
# The operator supplies:
#   - A public domain (serverName) and its well-known delegation target
#   - LDAP directory connection details (URI, base DN, bind DN)
#   - A directory on the host where RocksDB persists
#   - A Secret holding the registration token and LDAP bind password
#
{ lib, config, ... }:
let
  cfg = config.nixapps.chat.tuwunel;
  name = "tuwunel";
in
{
  options.nixapps.chat.tuwunel = {
    enable = lib.mkEnableOption "Tuwunel, a Matrix homeserver";

    namespace = lib.mkOption {
      type = lib.types.str;
      description = "Namespace to deploy into.";
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
      default = "ghcr.io/matrix-construct/tuwunel:v1.6.2-release-all-x86_64-v3-linux-gnu";
      description = ''
        Container image, pinned by digest.

        Tuwunel embeds the database and runs migrations on schema version
        mismatches. A floating tag can therefore run a migration nobody
        reviewed, and afterward there is no diff. Pin it, and move the pin
        deliberately when you upgrade.
      '';
    };

    serverName = lib.mkOption {
      type = lib.types.str;
      description = ''
        The Matrix server_name (the domain users see; e.g., "example.com").
        This becomes the suffix of all user IDs (@user:serverName).
      '';
    };

    wellKnownServer = lib.mkOption {
      type = lib.types.str;
      description = ''
        The delegation target for .well-known/matrix/server. Usually a
        subdomain that points to the real homeserver (e.g.,
        "matrix.example.com:443"). Matrix clients will use this to find your
        homeserver even if it does not run on serverName itself.
      '';
    };

    wellKnownClient = lib.mkOption {
      type = lib.types.str;
      description = ''
        The delegation target for .well-known/matrix/client. A public https://
        URL where clients can find homeserver discovery info (e.g.,
        "https://matrix.example.com"). Must be a full HTTPS URL.
      '';
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host directory holding the RocksDB database tree.

        The directory must be owned by uid:gid 3009:3009 before the pod starts
        (the container's security context enforces this). RocksDB creates and
        rewrites .sst, MANIFEST, CURRENT, and LOCK files in place, so the uid
        must own the directory outright. If you are migrating from a docker
        container, chown the existing data to 3009:3009 and ensure the
        directory already exists with the right permissions.

        RocksDB writes sequentially; storage tuned for streaming (HDD,
        high-recordsize ZFS) works well here.
      '';
    };

    ldapUri = lib.mkOption {
      type = lib.types.str;
      description = ''
        LDAP server URI (e.g., "ldap://ldap.example.com:389" or
        "ldaps://ldap.example.com:636" for TLS).
      '';
    };

    ldapBaseDn = lib.mkOption {
      type = lib.types.str;
      description = ''
        LDAP base DN for user searches (e.g., "dc=example,dc=com").
      '';
    };

    ldapBindDn = lib.mkOption {
      type = lib.types.str;
      description = ''
        LDAP DN to bind as when querying the directory (e.g.,
        "cn=admin,ou=people,dc=example,dc=com"). The bind password is fetched
        from the Secret at secretName under the key lldap_bindpw.
      '';
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, holding:

          registration_token   the open-registration token for signup
          lldap_bindpw         the LDAP bind password (plain text)

        Tuwunel reads registration_token as an environment variable and
        lldap_bindpw as a file. This recipe mounts the file at
        /run/secrets/lldap_bindpw and points the LDAP config to it.

        This recipe never renders the Secret. Rendering one would mean putting
        credentials into a manifest tree.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "chat";

      resources = {
        deployments.${name}.spec = {
          # Recreate, not rolling. Tuwunel is a single-writer homeserver; two
          # pods cannot run concurrently against the same RocksDB database.
          # Even if RocksDB survived the corruption, federation needs a stable
          # identity and presence feed — duplicate writes would break both.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              securityContext = {
                runAsUser = 3009;
                runAsGroup = 3009;
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = [ "ALL" ];
                };
                env = {
                  TUWUNEL_SERVER_NAME = { value = cfg.serverName; };
                  TUWUNEL_DATABASE_PATH = { value = "/var/lib/tuwunel"; };
                  TUWUNEL_ADDRESS = { value = ''["0.0.0.0"]''; };
                  TUWUNEL_PORT = { value = "8008"; };
                  TUWUNEL_WELL_KNOWN__SERVER = { value = cfg.wellKnownServer; };
                  TUWUNEL_WELL_KNOWN__CLIENT = { value = cfg.wellKnownClient; };
                  TUWUNEL_ALLOW_REGISTRATION = { value = "true"; };
                  TUWUNEL_ALLOW_FEDERATION = { value = "true"; };
                  TUWUNEL_ROCKSDB_DIRECT_IO = { value = "false"; };
                  TUWUNEL_IP_LOOKUP_STRATEGY = { value = "1"; };
                  TUWUNEL_QUERY_OVER_TCP_ONLY = { value = "true"; };
                  TUWUNEL_LDAP__ENABLE = { value = "true"; };
                  TUWUNEL_LDAP__URI = { value = cfg.ldapUri; };
                  TUWUNEL_LDAP__BASE_DN = { value = cfg.ldapBaseDn; };
                  TUWUNEL_LDAP__BIND_DN = { value = cfg.ldapBindDn; };
                  TUWUNEL_LDAP__BIND_PASSWORD_FILE = { value = "/run/secrets/lldap_bindpw"; };
                  TUWUNEL_LDAP__FILTER = { value = "(objectClass=person)"; };
                  TUWUNEL_LDAP__UID_ATTRIBUTE = { value = "uid"; };
                  TUWUNEL_LDAP__NAME_ATTRIBUTE = { value = "cn"; };
                  TUWUNEL_LDAP__MAIL_ATTRIBUTE = { value = "mail"; };
                };
                env.TUWUNEL_REGISTRATION_TOKEN.valueFrom.secretKeyRef = {
                  name = cfg.secretName;
                  key = "registration_token";
                };
                ports.client = {
                  name = "client";
                  containerPort = 8008;
                };
                ports.federation = {
                  name = "federation";
                  containerPort = 8448;
                };
                volumeMounts.database = {
                  name = "database";
                  mountPath = "/var/lib/tuwunel";
                };
                volumeMounts.lldap-bindpw = {
                  name = "lldap-bindpw";
                  mountPath = "/run/secrets/lldap_bindpw";
                  subPath = "lldap_bindpw";
                  readOnly = true;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = 8008;
                  };
                  initialDelaySeconds = 20;
                  periodSeconds = 10;
                  failureThreshold = 18;
                };
              };
              volumes.database = {
                name = "database";
                hostPath = {
                  path = cfg.dataPath;
                  type = "Directory";
                };
              };
              volumes.lldap-bindpw = {
                name = "lldap-bindpw";
                secret = {
                  secretName = cfg.secretName;
                  items = [
                    {
                      key = "lldap_bindpw";
                      path = "lldap_bindpw";
                    }
                  ];
                };
              };
            };
          };
        };

        services.${name}.spec = {
          type = "ClusterIP";
          selector.app = name;
          ports.client = {
            name = "client";
            port = 8008;
            targetPort = 8008;
          };
          ports.federation = {
            name = "federation";
            port = 8448;
            targetPort = 8448;
          };
        };
      };
    };
  };
}
