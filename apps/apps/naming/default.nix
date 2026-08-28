# naming — interactive name-space exploration with a private web front,
# control API, queue consumer, and dedicated PostgreSQL store.
#
# This module declares application needs through nixk3s.apps. It renders no
# Kubernetes resources itself. Addresses, paths, images, credentials, sizing,
# and placement remain values supplied by the private deployment.
{ config, lib, ... }:
let
  cfg = config.nixapps.apps.naming;
  databaseHost = "naming-db.${cfg.namespace}.svc.cluster.local";
  databaseEnv = {
    NAMING_DATABASE_HOST = databaseHost;
    NAMING_DATABASE_PORT = "5432";
    NAMING_DATABASE_NAME = cfg.databaseName;
    NAMING_DATABASE_USER = cfg.databaseUser;
  };
  databaseSecret = {
    secret = cfg.databaseSecretName;
    env.NAMING_DATABASE_PASSWORD = cfg.databasePasswordKey;
  };
in
{
  options.nixapps.apps.naming = {
    enable = lib.mkEnableOption "the naming application shell";

    namespace = lib.mkOption {
      type = lib.types.str;
      description = "Kubernetes namespace for all naming workloads.";
    };

    webImage = lib.mkOption {
      type = lib.types.str;
      description = "Digest-pinned image for the Svelte web front.";
    };

    apiImage = lib.mkOption {
      type = lib.types.str;
      description = "Digest-pinned image for the FastAPI control plane.";
    };

    workerImage = lib.mkOption {
      type = lib.types.str;
      description = "Digest-pinned image for the private Rust worker.";
    };

    databaseImage = lib.mkOption {
      type = lib.types.str;
      description = "Digest-pinned PostgreSQL image.";
    };

    databasePath = lib.mkOption {
      type = lib.types.str;
      description = "Host path backing the dedicated PostgreSQL data directory.";
    };

    databaseSecretName = lib.mkOption {
      type = lib.types.str;
      description = "Existing Secret containing the PostgreSQL password.";
    };

    databasePasswordKey = lib.mkOption {
      type = lib.types.str;
      default = "password";
      description = "Key in databaseSecretName containing the PostgreSQL password.";
    };

    databaseName = lib.mkOption {
      type = lib.types.str;
      default = "naming";
      description = "PostgreSQL database name.";
    };

    databaseUser = lib.mkOption {
      type = lib.types.str;
      default = "naming";
      description = "PostgreSQL role used by the API and worker.";
    };

    webSlot = lib.mkOption {
      type = lib.types.ints.between 1 254;
      description = "Address slot for the NetBird-facing web service.";
    };

    apiSlot = lib.mkOption {
      type = lib.types.ints.between 1 254;
      description = "Address slot for the internal API service.";
    };

    databaseSlot = lib.mkOption {
      type = lib.types.ints.between 1 254;
      description = "Address slot for the internal PostgreSQL service.";
    };

    llmBaseUrl = lib.mkOption {
      type = lib.types.str;
      description = "Internal OpenAI-compatible endpoint used for local LLM enrichment.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixk3s.apps = {
      naming-web = {
        namespace = cfg.namespace;
        createNamespace = true;
        origin = "nixapps";
        slot = cfg.webSlot;
        image = cfg.webImage;
        exposure = "nb";
        ports.http = {
          number = 8080;
          servicePort = 80;
        };
        env.NAMING_API_UPSTREAM = "http://naming-api.${cfg.namespace}.svc.cluster.local:8000";
        probes.readiness = {
          port = "http";
          path = "/healthz";
        };
        probes.liveness = {
          port = "http";
          path = "/healthz";
          periodSeconds = 30;
        };
        security = {
          runAsNonRoot = true;
          seccomp = "RuntimeDefault";
          allowPrivilegeEscalation = false;
          readOnlyRootFilesystem = true;
          capabilitiesDrop = [ "ALL" ];
        };
        state.runtime = {
          emptyDir = true;
          mountPath = "/tmp";
        };
      };

      naming-api = {
        namespace = cfg.namespace;
        origin = "nixapps";
        slot = cfg.apiSlot;
        image = cfg.apiImage;
        exposure = "internal";
        ports.http.number = 8000;
        env = databaseEnv // {
          NAMING_LLM_BASE_URL = cfg.llmBaseUrl;
        };
        secrets.database = databaseSecret;
        probes.readiness = {
          port = "http";
          path = "/healthz";
        };
        probes.liveness = {
          port = "http";
          path = "/healthz";
          periodSeconds = 30;
        };
        security = {
          runAsNonRoot = true;
          seccomp = "RuntimeDefault";
          allowPrivilegeEscalation = false;
          readOnlyRootFilesystem = true;
          capabilitiesDrop = [ "ALL" ];
        };
        state.runtime = {
          emptyDir = true;
          mountPath = "/tmp";
        };
      };

      naming-worker = {
        namespace = cfg.namespace;
        origin = "nixapps";
        image = cfg.workerImage;
        env = databaseEnv // {
          NAMING_LLM_BASE_URL = cfg.llmBaseUrl;
          NAMING_WORKER_POLL_SECONDS = "10";
        };
        secrets.database = databaseSecret;
        security = {
          runAsNonRoot = true;
          seccomp = "RuntimeDefault";
          allowPrivilegeEscalation = false;
          readOnlyRootFilesystem = true;
          capabilitiesDrop = [ "ALL" ];
        };
        state.runtime = {
          emptyDir = true;
          mountPath = "/tmp";
        };
      };

      naming-db = {
        namespace = cfg.namespace;
        origin = "nixapps";
        slot = cfg.databaseSlot;
        image = cfg.databaseImage;
        exposure = "internal";
        singleWriter = true;
        ports.postgresql.number = 5432;
        env = {
          POSTGRES_DB = cfg.databaseName;
          POSTGRES_USER = cfg.databaseUser;
          PGDATA = "/var/lib/postgresql/data/pgdata";
        };
        secrets.database = {
          secret = cfg.databaseSecretName;
          env.POSTGRES_PASSWORD = cfg.databasePasswordKey;
        };
        probes.readiness = {
          port = "postgresql";
          path = null;
          failureThreshold = 12;
        };
        probes.liveness = {
          port = "postgresql";
          path = null;
          periodSeconds = 30;
          failureThreshold = 6;
        };
        state.data = {
          hostPath = cfg.databasePath;
          mountPath = "/var/lib/postgresql/data";
        };
        security = {
          seccomp = "RuntimeDefault";
          allowPrivilegeEscalation = false;
          capabilitiesDrop = [ "ALL" ];
        };
      };
    };
  };
}
