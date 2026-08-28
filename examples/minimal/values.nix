{
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixk3s.tenancy.projects.apps.destinationNamespaces = [ "example-naming" ];
  nixk3s.appPlatform.hostPathNodeSelector."kubernetes.io/hostname" = "example-node";
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
    databaseImage = "registry.example.com/postgres:17@sha256:3333333333333333333333333333333333333333333333333333333333333333";
    databasePath = "/example/data/naming";
    databaseSecretName = "example-naming-database";
    webSlot = 161;
    apiSlot = 162;
    databaseSlot = 163;
    llmBaseUrl = "http://llm.example-naming.svc.cluster.local:4000";
  };
}
