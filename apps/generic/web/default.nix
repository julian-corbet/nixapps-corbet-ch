# generic/web — a recipe for web apps too ordinary to deserve their own file. The OTHER platform opinion in this project family besides GPU sharing (see
# nixgpu): a generic tenant module for CPU-only web apps that rest at zero replicas between uses and
# wake on the first request via the KEDA HTTP add-on. `apps` is a LIST, not a single-tenant option
# tree like comfyui/tts — deliberately, because the shape underneath is uniform enough to cover many
# unrelated tenants with zero redesign: a Deployment, a Service, and an HTTPScaledObject, nothing
# else. No PVC, no Secret creation, no hostPath by default. Each list entry renders as its OWN nixidy
# Argo application (never bundled together), so one tenant's sync/prune/rollback can never touch
# another's, matching how independent self-hosted apps actually behave in production: unrelated
# lifecycles that only happen to share a manifest shape.
#
# THE SUBSTRATE THIS MODULE CONSUMES, AND DOES NOT PROVIDE: the KEDA core controller, the KEDA HTTP
# add-on (its CRDs and its interceptor Service/proxy), and whatever routes public traffic to the
# cluster's HTTP entrypoint are cluster-wide infrastructure, installed ONCE, out of band from any
# tenant — the same substrate/tenant split as nixgpu/nixllm. This module only emits objects that
# CONSUME that substrate; it never installs KEDA itself, and has no option surface for doing so. Wire
# the substrate in with nixk3s (or a sibling of it) before pointing this module at a cluster.
#
# GPU-consuming tenants are explicitly OUT of scope here — a stateless render/CRUD/dashboard app is
# the purest member of this class (zero PVC, zero Secret, zero hostPath in the common case). A
# GPU-backed scale-to-zero tenant belongs in a module like comfyui/tts instead, declaring the nixgpu
# contract (priorityClassName, `strategy: Recreate`, a device-resource token) rather than reinventing
# card handling — this module has no GPU option surface at all, not even an unused one.
#
# WHY THE HTTPSCALEDOBJECT IS RENDERED VIA `yamls`, NOT A TYPED `resources.*` PATH: it is a CRD
# (`http.keda.sh/v1alpha1`), and nixidy only ships typed options for the core Kubernetes API out of
# the box — a typed option for a third-party CRD exists only after the CONSUMING environment has run
# nixidy's own `generators.fromCRDModule` against that CRD and imported the result. That is
# substrate-level wiring this portable tenant module cannot assume has happened, so the
# HTTPScaledObject is emitted as a YAML string through nixidy's `yamls` escape hatch (a list of raw
# manifests, parsed and merged into the application's rendered objects) while the Deployment and
# Service — both core kinds, always available — use the typed `resources.*` path exactly like
# nixllm and comfyui/tts do.
#
# THE REPLICAS LESSON (read before "fixing" a missing `replicas` field): this module NEVER sets
# `spec.replicas` on the rendered Deployment, unconditionally, no toggle. Once the HTTPScaledObject
# exists, KEDA's own HPA is the sole owner of this Deployment's live replica count (0 at rest, up to
# `replicas.max` once woken) — every reconcile, not just the first one. Declaring a fixed `replicas`
# in git as well would put Argo CD's self-heal in a standing fight with KEDA over the same field,
# flapping the Deployment between whatever git says and whatever KEDA just scaled it to. Kubernetes
# defaults an absent `replicas` to 1 server-side, which is irrelevant here since KEDA overwrites it on
# its own schedule regardless. A Deployment resting at 0/0 between requests is this module's normal
# steady state, not a sign anything is broken or missing.
#
# Status: generalized from a production cluster where this exact 3-object shape is live today across
# more than a dozen independent tenants of very different purpose (a chart/render API, a snippet
# manager, small CRUD tools, dashboards, ...) — most needing nothing but the plain options below, a
# handful needing the optional `dataHostPath`/`existingSecretName` fields for a small local data
# directory or a client secret. Render-checked, not yet re-verified live in a fresh cluster.
{ lib, config, ... }:
let
  cfg = config.nixapps.generic.web;

  enabledApps = builtins.filter (app: app.enable) cfg.apps;

  effectiveNamespace = app: if app.namespace != null then app.namespace else cfg.namespace;
  effectiveProject = app: if app.project != null then app.project else cfg.project;

  # Every OTHER enabled app that would also try to create the same effective namespace as `app` —
  # feeds the namespace-anchor assertion below. See `createNamespace`'s option doc for the full
  # lesson this catches: several independent Argo applications all creating/owning the same
  # Namespace object because every app sharing it was left at its default.
  createNamespaceAnchors = app: builtins.filter
    (a: a.createNamespace && effectiveNamespace a == effectiveNamespace app)
    enabledApps;

  # A "hardened" pod/container securityContext bundle is only ever added when `runAsUser` is set on
  # an app entry. An explicit uid is the operator's own signal that they have checked the image
  # tolerates running as a fixed non-root user; forcing `runAsNonRoot` on an unmodified upstream
  # image whose expected uid is unknown (several images in this exact tenant class only work as
  # root) would break it outright. The safe, neutral default — matching the reference tenant, which
  # sets none of this — is to add NO securityContext at all until an operator opts in with a uid.
  podSecurityContext = app: lib.optionalAttrs (app.runAsUser != null) {
    runAsUser = app.runAsUser;
    runAsGroup = if app.runAsGroup != null then app.runAsGroup else app.runAsUser;
    runAsNonRoot = true;
    seccompProfile.type = "RuntimeDefault";
    # fsGroup is deliberately NEVER set here, for any app, under any option combination: fsGroup
    # recursively chowns every file under every mounted volume on each pod start, including a
    # bind-mounted `dataHostPath` dataset that already has its own ownership from outside
    # Kubernetes entirely — fighting (and on a large directory, badly slowing down) that ownership
    # on every single pod start or restart. If a data volume needs to be writable by a specific
    # uid, make that uid the volume's ACTUAL on-disk owner and set `runAsUser`/`runAsGroup` to
    # match, rather than reaching for fsGroup to paper over a mismatch.
  };

  containerSecurityContext = app: lib.optionalAttrs (app.runAsUser != null) {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
  };

  plainEnvEntries = app: lib.mapAttrsToList (name: value: { inherit name value; }) app.env;

  # Only meaningful once `existingSecretName` is set — see that option's doc. `secretEnv` maps an
  # env var name to a key WITHIN that one existing Secret; this module never creates the Secret
  # itself, mirroring nixllm's `litellm.existingSecretName` convention.
  secretEnvEntries = app: lib.mapAttrsToList
    (envName: secretKey: {
      name = envName;
      valueFrom.secretKeyRef = { name = app.existingSecretName; key = secretKey; };
    })
    app.secretEnv;

  mkProbe = app: p: {
    httpGet = { path = app.healthPath; port = app.port; };
    periodSeconds = p.periodSeconds;
    failureThreshold = p.failureThreshold;
  } // lib.optionalAttrs (p.timeoutSeconds != null) { timeoutSeconds = p.timeoutSeconds; };

  # A hand-written heredoc, not `lib.generators.toYAML` (which nixpkgs implements as compact
  # single-line JSON — technically valid YAML, since JSON is a YAML subset, but it would render
  # this one object as an unreadable blob in the rendered manifest tree every other object in that
  # same tree is plain indented YAML for, defeating the "every deployment a rendered, auditable
  # manifest tree, every upgrade a diff" pitch this whole project family makes). nixllm's own
  # `litellmConfigYaml` sets the same precedent for the same reason.
  httpScaledObjectYaml = app: ''
    apiVersion: http.keda.sh/v1alpha1
    kind: HTTPScaledObject
    metadata: { name: ${app.name}, namespace: ${effectiveNamespace app} }
    spec:
      hosts: ["${app.host}"]
      replicas: { min: ${toString app.replicas.min}, max: ${toString app.replicas.max} }
      scaleTargetRef:
        apiVersion: apps/v1
        kind: Deployment
        name: ${app.name}
        service: ${app.name}
        port: ${toString app.port}
      scaledownPeriod: ${toString app.scaledownPeriod}
  '';

  mkApplication = app:
    let
      container = {
        name = app.name;
        image = app.image;
        env = plainEnvEntries app ++ secretEnvEntries app;
        ports = [{ name = "http"; containerPort = app.port; }];
        readinessProbe = mkProbe app app.probes.readiness;
        livenessProbe = mkProbe app app.probes.liveness;
        volumeMounts = lib.optionals (app.dataHostPath != null)
          [{ name = "data"; mountPath = app.dataMountPath; }];
      }
      // lib.optionalAttrs app.probes.startup.enable { startupProbe = mkProbe app app.probes.startup; }
      // lib.optionalAttrs (containerSecurityContext app != { }) { securityContext = containerSecurityContext app; };
    in
    {
      namespace = effectiveNamespace app;
      createNamespace = app.createNamespace;
      project = effectiveProject app;

      resources.deployments.${app.name} = {
        metadata.labels.app = app.name;
        spec = {
          # strategy: Recreate. Not primarily for the device-token reason nixllm/comfyui use it for
          # (this class of tenant holds no GPU slot) — here it is because `replicas.max` is
          # typically 1 for a tenant in this class, and a surging RollingUpdate pod would then
          # transiently exceed the very replica ceiling the HTTPScaledObject declares. Recreate
          # keeps "at most `replicas.max` pods, and at most one during a rollout" true regardless of
          # whether a change comes from an image bump or from KEDA's own 0<->N scaling. It also
          # happens to be required outright for any stateful sibling with `dataHostPath` set (a
          # single-writer data directory two pods must never touch at once).
          strategy.type = "Recreate";
          selector.matchLabels.app = app.name;
          # `replicas` is intentionally absent — see the module-level REPLICAS LESSON comment above.
          template = {
            metadata.labels.app = app.name;
            spec = {
              containers = [ container ];
            }
            // lib.optionalAttrs (app.nodeSelector != { }) { nodeSelector = app.nodeSelector; }
            // lib.optionalAttrs (podSecurityContext app != { }) { securityContext = podSecurityContext app; }
            // lib.optionalAttrs (app.dataHostPath != null) {
              volumes = [{ name = "data"; hostPath = { path = app.dataHostPath; type = "Directory"; }; }];
            };
          };
        };
      };

      resources.services.${app.name}.spec = {
        selector.app = app.name;
        ports = [{ name = "http"; port = app.port; targetPort = app.port; }];
      } // lib.optionalAttrs (app.clusterIP != null) { clusterIP = app.clusterIP; };

      yamls = [ (httpScaledObjectYaml app) ];

      assertions =
        lib.optional (app.dataHostPath != null && app.dataMountPath == null)
          {
            assertion = false;
            message = ''
              nixapps.generic.web.apps: "${app.name}" sets dataHostPath but not dataMountPath — there is no universal default (every app's own expected data directory differs); set dataMountPath to the in-pod path this app actually expects its data at.'';
          }
        ++ lib.optional (app.createNamespace && lib.length (createNamespaceAnchors app) > 1) {
          assertion = false;
          message = ''
            nixapps.generic.web: namespace "${effectiveNamespace app}" has createNamespace = true on ${toString (lib.length (createNamespaceAnchors app))} apps (${lib.concatMapStringsSep ", " (a: a.name) (createNamespaceAnchors app)}) — exactly one app sharing a namespace should anchor it; set createNamespace = false on all but one.'';
        };
    };

  appSubmodule = lib.types.submodule ({ ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to render this tenant at all. Default on — this exists so an app can be kept
          declared (and its options preserved) while temporarily dropped from the rendered manifest
          tree, the same ergonomic `enable` toggle tts gives each of its two tenants, just per list
          entry instead of per named option group.
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        description = ''
          Name shared by the Deployment, the Service, the HTTPScaledObject, and the generated
          nixidy/Argo application (`applications.<name>`). Set this to an EXISTING app's name to
          adopt it in place (no prune/recreate across two applications) instead of a fresh deploy
          under a new name. REQUIRED, no default — this is this tenant's identity, not a detail a
          default could stand in for.
        '';
      };

      namespace = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Namespace this app's Deployment/Service/HTTPScaledObject run in. `null` (the default)
          falls back to the module-level `nixapps.generic.web.namespace`. Override per app only
          when this particular tenant needs a namespace of its own rather than the shared default.
        '';
      };

      createNamespace = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this app's own generated Argo application creates the namespace it runs in.
          Defaults to true, which is correct as long as each distinct effective namespace among your
          `apps` entries is used by exactly one app — but if you point SEVERAL apps at the SAME
          namespace (the shared-namespace pattern this class of tenant commonly uses in production,
          several small apps anchored under one namespace), leaving every one of them at the default
          means several independent Argo applications all try to create and own the same Namespace
          object. Set this to `false` on every app but ONE "anchor" sharing that namespace — which
          one is arbitrary, but there must be exactly one, or none if the namespace already exists
          out of band. Enforced at build time: more than one app sharing an effective namespace with
          `createNamespace = true` fails an assertion instead of silently double-creating it.
        '';
      };

      project = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          nixidy AppProject this app's application is filed under. `null` (the default) falls back
          to the module-level `nixapps.generic.web.project`. Override per app only if one
          particular tenant needs a different Argo CD AppProject tier than the rest.
        '';
      };

      image = lib.mkOption {
        type = lib.types.str;
        description = "Container image. REQUIRED, no default — every tenant in this class runs a different app.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = ''
          Port the app listens on inside the container. Reused as-is for the container port, the
          Service port and targetPort, and the HTTPScaledObject's `scaleTargetRef.port` — every
          tenant this module has been generalized from uses one identical port on all three, and a
          fourth, independently configurable port option would be surface with no known use.
          REQUIRED, no default.
        '';
      };

      healthPath = lib.mkOption {
        type = lib.types.str;
        description = ''
          HTTP path polled by the readiness/liveness (and, if enabled, startup) probes. REQUIRED, no
          default, deliberately: this is NOT safely guessable. The two reference tenants this module
          was generalized from disagree with each other — one serves a real dedicated health
          endpoint at a non-root path, the other has none and only its root path ("/") answers
          correctly, and only once the app has actually finished starting. Guessing wrong fails in
          two different, equally unpleasant directions: assume a path that 404s forever and the pod
          never goes Ready; assume one that 200s unconditionally (a static file, a proxy default
          page) and the pod goes "Ready" before the app can actually serve a real request. Check what
          your own image serves, at rest, before setting this.
        '';
      };

      scaledownPeriod = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = ''
          Seconds of no inbound traffic the KEDA HTTP add-on waits before scaling this app back down
          to `replicas.min`. 300s (5 minutes) is this module's carried-over production default,
          uniform across every tenant it was generalized from — short enough that an idle tenant
          does not sit warm for hours after its last real use, long enough that ordinary gaps
          between requests within one user session do not repeatedly pay the cold-start cost. Too
          short thrashes the app up and down under perfectly normal usage; too long mostly just
          gives up the memory/CPU-reservation benefit scale-to-zero exists for.
        '';
      };

      replicas = {
        min = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 0;
          description = ''
            Floor the HTTPScaledObject scales this app down to when idle. 0 is what makes this
            scale-to-ZERO rather than merely elastic — leave it there unless you deliberately want at
            least one replica always warm (at which point, consider whether this tenant belongs in
            this module at all, versus an always-on Deployment with no HTTPScaledObject).
          '';
        };

        max = lib.mkOption {
          type = lib.types.ints.positive;
          default = 1;
          description = ''
            Ceiling the HTTPScaledObject scales this app up to under load. 1 is this module's
            carried-over production default for every tenant it was generalized from — none of them
            are horizontally scaled web farms, just one instance woken on demand. Raising this above
            1 is meaningful only if the app tolerates concurrent replicas sharing one identity (no
            single-writer local state, e.g. `dataHostPath` unset or a store the app itself already
            handles safely under concurrent writers).
          '';
        };
      };

      nodeSelector = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Node selector restricting this app's pod to specific node(s). Empty by default — no
          pinning, fine for most clusters. Becomes closer to REQUIRED once `dataHostPath` is set on
          a multi-node cluster: a hostPath volume resolves on whatever node the pod actually lands
          on, so an unpinned stateful tenant risks the scheduler placing it on a node that never had
          that directory populated in the first place — silently starting from empty state rather
          than failing loudly.
        '';
      };

      dataHostPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/srv/apps/my-app/data";
        description = ''
          Absolute host filesystem path bind-mounted into this app's pod, for a stateful sibling of
          the (stateless-by-default) reference tenant — e.g. an app persisting its own SQLite
          database or on-disk config beneath one directory. `null` (the default) means fully
          stateless: no volume, no hostPath, no `securityContext` identity is rendered at all,
          matching the purest member of this tenant class exactly. There is deliberately no PVC
          option anywhere in this module — every tenant it was generalized from uses a plain
          hostPath bind or nothing; add a PVC-based variant yourself if your cluster's storage class
          story needs one. When set, also set `dataMountPath` and, on a multi-node cluster,
          `nodeSelector` (see that option's doc for why).
        '';
      };

      dataMountPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          In-pod path `dataHostPath` is mounted at. REQUIRED whenever `dataHostPath` is set — there
          is no universal default, because every app's own expected data directory differs (one
          reference sibling in this class mounts its data at a specific named subdirectory of its
          own choosing, not a generic top-level path). Unused, and safe to leave `null`, while
          `dataHostPath` itself is `null`. Enforced at build time: setting `dataHostPath` without
          this fails an assertion instead of rendering a volume mount with no path.
        '';
      };

      runAsUser = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = ''
          Pod- and container-level user id. `null` (the default) renders NO `securityContext` at all
          — the safe choice for an unmodified upstream image of unknown default uid, matching the
          stateless reference tenant exactly. Set this (typically to whatever uid owns
          `dataHostPath` on disk) to also turn on a small hardening bundle: `runAsNonRoot`,
          `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, and a `RuntimeDefault`
          seccomp profile. `fsGroup` is never set by this module regardless — see the code comment
          on `podSecurityContext` for the on-disk-ownership trap that avoids.
        '';
      };

      runAsGroup = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = ''
          Pod- and container-level group id. Only meaningful when `runAsUser` is also set; defaults
          to the same value as `runAsUser` when left `null`, which is correct for the common
          single-uid-owns-its-own-data-directory case and only needs overriding when the data
          directory's group differs from its owning user.
        '';
      };

      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Plain (non-secret) environment variables for the container. Empty by default.";
      };

      existingSecretName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Name of an EXISTING Kubernetes Secret, in this app's namespace, that `secretEnv` reads
          from. This module never creates the Secret — bring your own via whatever mechanism your
          cluster uses (sealed-secrets, external-secrets, a plain manually-applied Secret), mirroring
          nixllm's `litellm.existingSecretName` convention. `null` (the default) is correct for the
          stateless reference tenant, which needs no secret at all; a stateful sibling authenticating
          against an external identity provider (an OIDC client secret, a signed-session key) is the
          usual reason to set this.
        '';
      };

      secretEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = { OIDC_CLIENT_SECRET = "OIDC_CLIENT_SECRET"; };
        description = ''
          Maps an environment variable name to a key WITHIN `existingSecretName`. Empty by default,
          and meaningless while `existingSecretName` is `null` — set both together.
        '';
      };

      clusterIP = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional fixed ClusterIP for this app's Service. Leave `null` for a normal,
          cluster-assigned ClusterIP (the right choice for almost everyone). Only set this if your
          cluster's own CNI/routing convention needs another in-cluster consumer to reach a stable,
          pre-known VIP rather than resolving the Service by DNS — the same escape hatch nixllm's
          `litellm.clusterIP` and comfyui's `clusterIP` provide.
        '';
      };

      host = lib.mkOption {
        type = lib.types.str;
        description = ''
          Public FQDN the HTTPScaledObject wakes this app for (its `spec.hosts`, a single-entry
          list). REQUIRED, no default. This module supports exactly one host per tenant, matching
          every reference tenant it was generalized from; an app that legitimately needs more than
          one hostname routed to the same Deployment is not yet covered here.
        '';
      };

      probes = {
        readiness = {
          periodSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 5;
            description = "How often the readiness probe polls.";
          };
          failureThreshold = lib.mkOption {
            type = lib.types.ints.positive;
            default = 24;
            description = ''
              Consecutive probe failures tolerated before the pod is considered not-ready. At the
              default `periodSeconds` this is 2 minutes of grace — this module's carried-over
              default for a tenant with a genuinely fast cold start and no dedicated `startupProbe`.
              If your app's cold boot is slower than that (see `probes.startup` below), raise this
              or, better, enable `probes.startup` instead of stretching readiness/liveness to cover a
              slow first start.
            '';
          };
          timeoutSeconds = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "Probe timeout in seconds. `null` (the default) omits the field, leaving Kubernetes' own default (1s).";
          };
        };

        liveness = {
          periodSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 15;
            description = "How often the liveness probe polls.";
          };
          failureThreshold = lib.mkOption {
            type = lib.types.ints.positive;
            default = 6;
            description = ''
              Consecutive probe failures tolerated before the pod is restarted. At the default
              `periodSeconds` this is 90 seconds — matching `probes.readiness`'s reasoning: fine for
              a tenant that starts fast or already leans on `probes.startup` for the slow part,
              because liveness only has to catch a genuine hang once the app is already running.
            '';
          };
          timeoutSeconds = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "Probe timeout in seconds. `null` (the default) omits the field, leaving Kubernetes' own default (1s).";
          };
        };

        startup = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Whether to add a `startupProbe`. Off by default, matching the stateless reference
              tenant (fast enough cold boot that plain readiness/liveness alone tolerate it — see
              their `failureThreshold` docs). Turn this ON for a slower-booting sibling instead of
              just stretching `probes.readiness.failureThreshold` further: a `startupProbe` gates
              readiness AND liveness behind its own success first, so a slow wake from zero can never
              be killed by liveness mid-start — a plain, un-gated readiness/liveness pair sized only
              for the FAST case is exactly the trap that kills a slow-booting pod the moment it's
              slower than whoever wrote those two thresholds expected.
            '';
          };
          periodSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 5;
            description = "How often the startup probe polls, once `enable` is true.";
          };
          failureThreshold = lib.mkOption {
            type = lib.types.ints.positive;
            default = 60;
            description = ''
              Consecutive probe failures tolerated before startup itself is considered failed. At the
              default `periodSeconds` this is 5 minutes — this module's carried-over default for a
              stateful sibling's realistic worst-case cold boot from a scale-to-zero wake, not its
              average one. Size this for the SLOWEST cold start you actually see, the same lesson
              nixllm's `generator.healthCheckTimeoutSeconds` encodes for its own cold-load case.
            '';
          };
          timeoutSeconds = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = 5;
            description = "Probe timeout in seconds, once `enable` is true.";
          };
        };
      };
    };
  });
in
{
  options.nixapps.generic.web = {
    enable = lib.mkEnableOption "the scale-to-zero web-app tenant class (KEDA HTTP add-on fronted)";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "apps";
      description = "Default namespace for apps that don't set their own `namespace`.";
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "apps";
      description = ''
        Default nixidy AppProject for apps that don't set their own `project`. Map this to whatever
        your Argo CD AppProject tiering scheme calls the tier for plain CPU-only workloads — every
        tenant in this class touches no GPU and needs no elevated tier, unlike comfyui/tts.
      '';
    };

    apps = lib.mkOption {
      type = lib.types.listOf appSubmodule;
      default = [ ];
      description = ''
        The list of scale-to-zero web tenants to render, one nixidy/Argo application per entry. See
        the per-option docs above (`name`, `image`, `port`, `healthPath`, `host` are the only
        REQUIRED fields — everything else has a neutral or production-carried-over default).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications = lib.listToAttrs
      (map (app: lib.nameValuePair app.name (mkApplication app)) enabledApps);
  };
}
