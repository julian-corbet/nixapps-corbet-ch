# naming — interactive name-space exploration with a private web front,
# control API, and private queue consumers for searches, immutable snapshot
# publication, and fresh verification. PostgreSQL is supplied by the deployment;
# this recipe deliberately does not create a database server.
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
  githubSecret = {
    secret = cfg.githubTokenSecretName;
    env.NAMING_GITHUB_TOKEN = cfg.githubTokenKey;
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
      description = "Digest-pinned image shared by the private Rust queue roles.";
    };

    snapshotClaimName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Existing claim holding content-addressed registry indexes. The search worker mounts it
        read-only; only the indexer publishes new immutable files.
      '';
    };

    githubTokenSecretName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional existing Secret containing a least-privilege GitHub token. When present, network
        workers can observe private owner resources and the indexer can publish a complete,
        authenticated owner-repository snapshot. Its presence also enables that snapshot schedule;
        the API sees only the capability flag, never the token content.
      '';
    };

    githubTokenKey = lib.mkOption {
      type = lib.types.str;
      default = "token";
      description = "Key in githubTokenSecretName containing the GitHub token.";
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
      description = ''
        Deadline for one claimed background work item. Evidence collection and model judging are
        separate durable work items, so a judging retry cannot consume the registry-check budget.
      '';
    };

    maxActiveRuns = lib.mkOption {
      type = lib.types.ints.between 1 1000;
      description = "Maximum number of queued or running search-evidence jobs accepted by the control plane.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixk3s.apps = {
      naming = {
        namespace = cfg.namespace;
        createNamespace = true;
        origin = "nixapps";
        identity = "naming-web";
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
        identity = "naming-runtime";
        slot = cfg.apiSlot;
        image = cfg.apiImage;
        exposure = "internal";
        ports.http.number = 8000;
        env = databaseEnv // {
          NAMING_MAINTENANCE_INTERVAL_SECONDS = "3600";
          NAMING_GITHUB_INVENTORY_ENABLED = if cfg.githubTokenSecretName != null then "true" else "false";
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
        identity = "naming-runtime";
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
          NAMING_SNAPSHOT_ROOT = "/var/lib/naming/indexes";
        };
        secrets = {
          database = databaseSecret;
          llm = llmSecret;
        }
        // lib.optionalAttrs (cfg.githubTokenSecretName != null) {
          github = githubSecret;
        };
        security = {
          runAsNonRoot = true;
          seccomp = "RuntimeDefault";
          allowPrivilegeEscalation = false;
          readOnlyRootFilesystem = true;
          capabilitiesDrop = [ "ALL" ];
        };
        state = {
          indexes = {
            claim = cfg.snapshotClaimName;
            mountPath = "/var/lib/naming/indexes";
            readOnly = true;
          };
          runtime = {
            emptyDir = true;
            mountPath = "/tmp";
          };
        };
      };

      naming-indexer = {
        namespace = cfg.namespace;
        origin = "nixapps";
        identity = "naming-runtime";
        image = cfg.workerImage;
        command = [ "/usr/local/bin/index-worker" ];
        scaling = "scale-to-zero";
        env = databaseEnv // {
          NAMING_INDEXER_POLL_SECONDS = "10";
          NAMING_INDEXER_LEASE_SECONDS = "300";
          NAMING_INDEXER_MAX_ATTEMPTS = "3";
          NAMING_INDEXER_TIMEOUT_SECONDS = "3600";
          NAMING_SNAPSHOT_ROOT = "/var/lib/naming/indexes";
          TMPDIR = "/tmp";
        };
        secrets = {
          database = databaseSecret;
        }
        // lib.optionalAttrs (cfg.githubTokenSecretName != null) {
          github = githubSecret;
        };
        security = {
          runAsNonRoot = true;
          seccomp = "RuntimeDefault";
          allowPrivilegeEscalation = false;
          readOnlyRootFilesystem = true;
          capabilitiesDrop = [ "ALL" ];
        };
        state = {
          indexes = {
            claim = cfg.snapshotClaimName;
            mountPath = "/var/lib/naming/indexes";
          };
          runtime = {
            emptyDir = true;
            mountPath = "/tmp";
          };
        };
      };

      naming-verifier = {
        namespace = cfg.namespace;
        origin = "nixapps";
        identity = "naming-runtime";
        image = cfg.workerImage;
        command = [ "/usr/local/bin/verification-worker" ];
        scaling = "scale-to-zero";
        env = databaseEnv // {
          NAMING_VERIFIER_POLL_SECONDS = "5";
          NAMING_VERIFIER_LEASE_SECONDS = "60";
          NAMING_VERIFIER_MAX_ATTEMPTS = "4";
          NAMING_VERIFIER_TIMEOUT_SECONDS = "90";
        };
        secrets = {
          database = databaseSecret;
        }
        // lib.optionalAttrs (cfg.githubTokenSecretName != null) {
          github = githubSecret;
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
