# nixapps.productivity.calcom — Cal.com, a self-hosted scheduling platform.
#
# What this recipe knows about Cal.com:
#
#   - It is a Next.js application serving a scheduling interface and API (:3000).
#   - It is fully stateless on disk: all state lives in PostgreSQL databases. You
#     point it at two databases (one for app state, one for SAML); this recipe does
#     not run databases for you.
#   - The image is pinned by digest to an exact build whose migrations have been
#     verified against the production schema. The entrypoint runs `prisma migrate deploy`,
#     which is idempotent and safe, but using :latest risks running unapproved migrations
#     against your production database. Always pin by digest.
#   - It has a startup probe for the Next.js cold-start window and a readiness probe
#     for steady-state availability.
#   - PRODUCTION USE: This image runs production workloads handling live Stripe payments
#     and SAML SSO. Pin the digest carefully and test migrations in staging first.
#
{ lib, config, ... }:
let
  cfg = config.nixapps.productivity.calcom;
  name = "calcom";
in
{
  options.nixapps.productivity.calcom = {
    enable = lib.mkEnableOption "Cal.com, a self-hosted scheduling platform";

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
      default = "calcom/cal.com@sha256:ace3bb1219fb7306585ab9f4d94d41af7ee064c343db0498173436bbe857bd49";
      description = ''
        Container image, pinned by digest to an exact build.

        Cal.com is a production scheduling platform handling real Stripe payments
        and SAML SSO. The image is pinned by digest (not tag) so migrations are
        predictable. Before updating: verify the new image's migration status against
        your database schema, test in staging, and then update the digest deliberately.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port the application serves HTTP on.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace, loaded wholesale into the
        container's environment. Cal.com needs approximately 48 environment variables,
        including:

          DATABASE_URL         PostgreSQL connection string for app state
          SAML_DATABASE_URL    PostgreSQL connection string for SAML configuration
          NEXTAUTH_*           OIDC/auth configuration (NEXTAUTH_SECRET, NEXTAUTH_URL, etc.)
          STRIPE_*             Stripe API keys (STRIPE_API_KEY, STRIPE_PUBLIC_KEY, etc.)
          CALENDSO_ENCRYPTION_KEY   encryption key for sensitive data in the database

        Other variables control integrations, webhooks, logging, and more. Refer to
        the Cal.com documentation for the complete list. This recipe never renders
        the Secret. Rendering one would mean putting credentials into a manifest tree.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${name} = {
      inherit (cfg) namespace createNamespace;
      project = "productivity";

      resources = {
        deployments.${name}.spec = {
          # Recreate strategy: the app is single-instance and idempotent migrations
          # are run on startup.
          strategy.type = "Recreate";
          selector.matchLabels.app = name;
          template = {
            metadata.labels.app = name;
            spec = {
              containers.${name} = {
                inherit name;
                inherit (cfg) image;
                envFrom = [ { secretRef.name = cfg.secretName; } ];
                ports.http = {
                  name = "http";
                  containerPort = cfg.port;
                };
                # Startup probe owns the Next.js cold-start window. The image runs
                # `prisma migrate deploy` on entry, which blocks until migrations are
                # applied. Readiness doesn't flap under host I/O load.
                startupProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 10;
                  failureThreshold = 30;
                  timeoutSeconds = 5;
                };
                # Readiness probe: path "/" returns a 307 redirect, which k8s counts
                # as ready (2xx-3xx). This is the standard behavior for unauthenticated
                # users on Cal.com.
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = cfg.port;
                  };
                  periodSeconds = 10;
                  failureThreshold = 30;
                  timeoutSeconds = 5;
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
