# Placeholder values for EVERY recipe in this repository — the file that makes
# CONTRACT.md R11 real ("a recipe renders from this repository alone, or it does
# not exist"). The root flake's `nix flake check` renders all of it, so a recipe
# that cannot render, or that quietly grows a required value nobody supplies,
# fails CI rather than failing in somebody's cluster.
#
# Every value here is exactly the kind of thing a recipe refuses to guess: a
# namespace, a host directory, the name of a Secret it will not create, a public
# URL, an identity-provider coordinate. Nothing here is real — the hostnames are
# under example.com, the paths are under /var/lib/example, and no credential
# appears in any form. Enabling all 38 apps at once is not a deployment anyone
# would want; it is a proof that each one still renders.
#
# This file was generated from the recipes' own option surface: every option
# with no default got a placeholder derived from its name. Regenerating after
# adding a recipe is mechanical, and the check fails until you do.
{
  # Required by the nixidy environment itself, not by any recipe here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixapps.advanced.comfyui = {
    enable = true;
    # The arbiter contract, set here so the check renders it. An arbiter finds the
    # pods holding the card by label selector, so a workload carrying none of its
    # labels is invisible to it — and the keys belong to the arbiter, not the app.
    arbiterLabels = {
      "example.com/gpu-managed" = "true";
      "example.com/gpu-engine" = "compute";
    };
    deviceResource = "example.com/gpu";
    priorityClassName = "example-gpu-interactive";
    imagesPath = "/var/lib/example/comfyui/images";
    modelsPath = "/var/lib/example/comfyui/models";
    namespace = "comfyui";
    rootPath = "/var/lib/example/comfyui/root";
  };

  nixapps.advanced.tts = {
    enable = true;
    # This recipe holds two independently enabled engines, so enabling the recipe
    # alone renders nothing but a namespace. Both are switched on here on purpose:
    # a check that renders no workload proves nothing about the workload.
    kokoro.enable = true;
    chatterbox.enable = true;
    chatterbox.arbiterLabels = {
      "example.com/gpu-managed" = "true";
      "example.com/gpu-engine" = "compute";
    };
    chatterbox.deviceResource = "example.com/gpu";
    chatterbox.priorityClassName = "example-gpu-besteffort";
    chatterbox.image = "registry.example.com/example/tts:1.0.0";
    chatterbox.modelsCachePath = "/var/lib/example/tts/models-cache";
    chatterbox.referenceAudioPath = "/var/lib/example/tts/reference-audio";
    chatterbox.voicesPath = "/var/lib/example/tts/voices";
    kokoro.modelsPath = "/var/lib/example/tts/models";
    namespace = "tts";
  };

  nixapps.chat.mattermost = {
    enable = true;
    dataPath = "/var/lib/example/mattermost/data";
    dbHost = "mattermost-db.example";
    namespace = "mattermost";
    secretName = "mattermost-env";
  };

  nixapps.chat.tuwunel = {
    enable = true;
    dataPath = "/var/lib/example/tuwunel/data";
    ldapBaseDn = "ou=people,dc=example,dc=com";
    ldapBindDn = "cn=service,dc=example,dc=com";
    ldapUri = "ldap://directory.example:389";
    namespace = "tuwunel";
    secretName = "tuwunel-env";
    serverName = "tuwunel.example.com";
    wellKnownClient = "https://tuwunel.example.com";
    wellKnownServer = "https://tuwunel.example.com";
  };


  nixapps.dev.bytestash = {
    enable = true;
    dataPath = "/var/lib/example/bytestash/data";
    namespace = "bytestash";
    oidcClientId = "example-client-id";
    oidcIssuerUrl = "https://bytestash.example.com";
    secretName = "bytestash-env";
  };






  nixapps.files.nextcloud = {
    enable = true;
    dataPath = "/var/lib/example/nextcloud/data";
    databaseHost = "nextcloud-db.example";
    htmlPath = "/var/lib/example/nextcloud/html";
    namespace = "nextcloud";
    secretName = "nextcloud-env";
  };

  nixapps.files.opencloud = {
    enable = true;
    namespace = "opencloud";
    oidcClientId = "example-client-id";
    oidcIssuer = "https://opencloud.example.com";
    oidcMetadataUrl = "https://opencloud.example.com";
    publicDomain = "opencloud.example.com";
    publicUrl = "https://opencloud.example.com";
    statePath = "/var/lib/example/opencloud/state";
    userfilesPath = "/var/lib/example/opencloud/userfiles";
  };

  nixapps.files.pingvin = {
    enable = true;
    dataPath = "/var/lib/example/pingvin/data";
    namespace = "pingvin";
  };

  nixapps.files.syncthing = {
    enable = true;
    configClaimName = "syncthing-config";
    dataPath = "/var/lib/example/syncthing/data";
    namespace = "syncthing";
  };

  nixapps.files.versitygw = {
    enable = true;
    dataPath = "/var/lib/example/versitygw/data";
    iamPath = "/var/lib/example/versitygw/iam";
    namespace = "versitygw";
    secretName = "versitygw-env";
  };


  nixapps.home.homarr = {
    enable = true;
    adminGroup = "example-admins";
    authOidcClientId = "example-client-id";
    authOidcIssuer = "https://homarr.example.com";
    dataPath = "/var/lib/example/homarr/data";
    namespace = "homarr";
    secretName = "homarr-env";
  };


  nixapps.media.castopod = {
    enable = true;
    mediaPath = "/var/lib/example/castopod/media";
    namespace = "castopod";
    secretName = "castopod-env";
  };

  nixapps.media.ontime = {
    enable = true;
    dataPath = "/var/lib/example/ontime/data";
    namespace = "ontime";
  };

  nixapps.media.tubearchivist = {
    enable = true;
    cachePath = "/var/lib/example/tubearchivist/cache";
    elasticsearchDataPath = "/var/lib/example/tubearchivist/elasticsearch-data";
    mediaPath = "/var/lib/example/tubearchivist/media";
    namespace = "tubearchivist";
    redisDataPath = "/var/lib/example/tubearchivist/redis-data";
    secretName = "tubearchivist-env";
  };

  nixapps.notes.archivebox = {
    enable = true;
    archivePath = "/var/lib/example/archivebox/archive";
    indexPath = "/var/lib/example/archivebox/index";
    namespace = "archivebox";
  };



  nixapps.notes.silverbullet = {
    enable = true;
    namespace = "silverbullet";
    secretName = "silverbullet-env";
    spacePath = "/var/lib/example/silverbullet/space";
  };









  nixapps.utility.cyberchef = {
    enable = true;
    namespace = "cyberchef";
  };


  nixapps.utility.rclone = {
    enable = true;
    configPath = "/var/lib/example/rclone/config";
    namespace = "rclone";
    secretName = "rclone-env";
  };
}
