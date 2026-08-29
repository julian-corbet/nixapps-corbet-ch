# naming — interactive name-space exploration with a private web front,
# control API, and private queue consumer. PostgreSQL is supplied by the
# deployment; this recipe deliberately does not create a database server.
#
# This module declares application needs through nixk3s.apps. It renders no
# Kubernetes resources itself. Addresses, paths, images, credentials, sizing,
# and placement remain values supplied by the private deployment.
{ config, lib, ... }:
let
  cfg = config.nixapps.apps.naming;
  databaseEnv = {
    NAMING_DATABASE_HOST = cfg.databaseHost;
    NAMING_DATABASE_PORT = "5432";
    NAMING_DATABASE_NAME = cfg.databaseName;
    NAMING_DATABASE_USER = cfg.databaseUser;
  };
  databaseSecret = {
    secret = cfg.databaseSecretName;
    env.NAMING_DATABASE_PASSWORD = cfg.databasePasswordKey;
  };
  llmSecret = {
    secret = cfg.llmSecretName;
    env.NAMING_LLM_API_KEY = cfg.llmApiKeyKey;
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

    databaseHost = lib.mkOption {
      type = lib.types.str;
      description = "DNS name of an existing PostgreSQL service.";
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

    llmBaseUrl = lib.mkOption {
      type = lib.types.str;
      description = "Internal OpenAI-compatible endpoint used for local LLM enrichment.";
    };

    llmModel = lib.mkOption {
      type = lib.types.str;
      description = "Model ID exposed by the internal LLM serving door for structured planning.";
    };

    llmSecretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Existing Secret containing an application-scoped LLM API key. Never point this at a
        cluster-wide proxy master key.
      '';
    };

    llmApiKeyKey = lib.mkOption {
      type = lib.types.str;
      default = "api-key";
      description = "Key in llmSecretName containing the application-scoped LLM API key.";
    };

    llmTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.between 1 1800;
      default = 180;
      description = ''
        End-to-end client deadline for the required planner. Keep it above measured cold-load plus
        generation time, but bounded so one inference cannot hold the queue indefinitely. The
        serving gateway must separately propagate cancellation or enforce its own shorter deadline;
        this client timeout is not an inference reaper.
      '';
    };

    maxNetworkChecks = lib.mkOption {
      type = lib.types.ints.between 1 5000;
      description = ''
        Hard per-run ceiling for exact external registry requests after database and snapshot
        resolution. Requests for one candidate may run concurrently, but this budget is global.
      '';
    };

    runTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.between 60 7200;
      default = 900;
      description = "Whole-run deadline including planning, registry checks, and judging.";
    };

    maxActiveRuns = lib.mkOption {
      type = lib.types.ints.between 1 1000;
      description = "Maximum number of queued or running searches accepted by the control plane.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixk3s.apps = {
      naming = {
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
          NAMING_MAX_ACTIVE_RUNS = toString cfg.maxActiveRuns;
          NAMING_LLM_BASE_URL = cfg.llmBaseUrl;
          NAMING_LLM_MODEL = cfg.llmModel;
          NAMING_LLM_TIMEOUT_SECONDS = toString cfg.llmTimeoutSeconds;
        };
        secrets = {
          database = databaseSecret;
          llm = llmSecret;
        };
        probes.readiness = {
          port = "http";
          path = "/readyz";
        };
        probes.liveness = {
          port = "http";
          path = "/livez";
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
        scaling = "scale-to-zero";
        env = databaseEnv // {
          NAMING_LLM_BASE_URL = cfg.llmBaseUrl;
          NAMING_LLM_MODEL = cfg.llmModel;
          NAMING_LLM_TIMEOUT_SECONDS = toString cfg.llmTimeoutSeconds;
          NAMING_WORKER_POLL_SECONDS = "10";
          NAMING_WORKER_LEASE_SECONDS = "300";
          NAMING_WORKER_MAX_ATTEMPTS = "3";
          NAMING_MAX_NETWORK_CHECKS = toString cfg.maxNetworkChecks;
          NAMING_RUN_TIMEOUT_SECONDS = toString cfg.runTimeoutSeconds;
        };
        secrets = {
          database = databaseSecret;
          llm = llmSecret;
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
    };
  };
}
