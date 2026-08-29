{
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixk3s.tenancy.projects.apps.destinationNamespaces = [ "example-naming" ];
  nixk3s.appPlatform.hostPathNodeSelector."kubernetes.io/hostname" = "example-node";
  nixk3s.appPlatform.identities = {
    naming-web = {
      uid = 101;
      gid = 101;
      fsGroup = 101;
    };
    naming-runtime = {
      uid = 10001;
      gid = 10001;
      fsGroup = 10001;
    };
  };
  nixk3s.addressing = {
    enable = true;
    bands.apps = {
      base = 160;
      size = 16;
      description = "ordinary applications";
    };
    bindings.nixapps = "apps";
  };

  nixapps.apps.naming = {
    enable = true;
    namespace = "example-naming";
    webImage = "registry.example.com/naming-web:1@sha256:0000000000000000000000000000000000000000000000000000000000000000";
    apiImage = "registry.example.com/naming-api:1@sha256:1111111111111111111111111111111111111111111111111111111111111111";
    workerImage = "registry.example.com/naming-worker:1@sha256:2222222222222222222222222222222222222222222222222222222222222222";
    snapshotClaimName = "example-naming-indexes";
    databaseHost = "postgres.database.svc.cluster.local";
    databaseSecretName = "example-naming-database";
    webSlot = 161;
    apiSlot = 162;
    llmBaseUrl = "http://llm.example-naming.svc.cluster.local:4000";
    llmModel = "example-chat-model";
    llmSecretName = "example-naming-llm";
    maxActiveRuns = 10;
    maxNetworkChecks = 100;
  };
}
