# lib/storage.nix — a mount is knowledge, a backing is a value.
#
# CONTRACT.md R7: a recipe declares that the app needs state at a path INSIDE
# its container — that path comes from upstream and is the same for everyone, so
# it is knowledge. What sits behind that path is a property of one cluster, so it
# is a value, and it is pluggable: a host directory, a claim, or nothing that
# survives a restart. A recipe that can only be backed one way is not portable.
{ lib, options }:
let
  inherit (options) knowledge value optionalValue;

  backing = lib.types.submodule {
    options = {
      hostPath = optionalValue {
        type = lib.types.str;
        description = ''
          Absolute path on the node backing this mount.

          Site-specific: only the operator knows their layout. Note that a host
          directory is node-local — on a cluster with more than one schedulable
          node, pin the workload or the pod may land somewhere the directory was
          never populated and start from empty state instead of failing loudly.
        '';
      };

      claim = optionalValue {
        type = lib.types.str;
        description = ''
          Name of an existing PersistentVolumeClaim, in this app's namespace,
          backing this mount. Site-specific: the claim, its class and its
          provisioner are the operator's.
        '';
      };

      ephemeral = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Back this mount with scratch space that does not survive the pod.

          Only correct where the app treats the path as a cache it can rebuild.
          Set deliberately — silently ephemeral state is the worst of the three
          options, because it looks like it works.
        '';
      };
    };
  };

  # Exactly one backing. Validated EAGERLY, in one pass over the whole mount set
  # before any volume is built (see `toVolumes`): the obvious implementation —
  # throwing from inside the per-mount mapping — is lazy, so the error would not
  # surface until something deep in manifest serialisation happened to force that
  # list element, and the trace would point there instead of at the mount.
  chosenBackings =
    mount:
    lib.filter (set: set) [
      (mount.source.hostPath != null)
      (mount.source.claim != null)
      mount.source.ephemeral
    ];

  checkMount =
    name: mount:
    let
      n = lib.length (chosenBackings mount);
    in
    lib.optional (n != 1) ''
      nixapps storage "${name}": set exactly one backing — hostPath, claim, or ephemeral — found ${toString n}.
      A mount with none has nowhere to put state; a mount with two is ambiguous.
    '';

  volumeFor =
    name: mount:
    if mount.source.hostPath != null then
      { inherit name; hostPath = { path = mount.source.hostPath; type = mount.hostPathType; }; }
    else if mount.source.claim != null then
      { inherit name; persistentVolumeClaim.claimName = mount.source.claim; }
    else
      { inherit name; emptyDir = { }; };
in
rec {
  # Declare one mount. `mountPath` is knowledge (upstream decides it), `source`
  # is a value the operator owes. Returns a nested option tree, so a recipe
  # writes:  storage.media = lib.storage.mount { mountPath = "..."; reason = "..."; };
  mount =
    {
      mountPath,
      reason,
      hostPathType ? "Directory",
    }:
    {
      mountPath = knowledge {
        type = lib.types.str;
        default = mountPath;
        description = ''
          Path inside the container. ${reason}

          Upstream decides this, so it is a default rather than something you
          supply — override only if you have rebuilt the image differently.
        '';
      };

      hostPathType = knowledge {
        type = lib.types.enum [ "Directory" "DirectoryOrCreate" ];
        default = hostPathType;
        description = ''
          Whether a host-directory backing must already exist ("Directory") or
          may be created empty on first use ("DirectoryOrCreate").

          "Directory" is the safer default for anything holding real state: it
          fails visibly when a path is wrong, where DirectoryOrCreate would
          silently start the app against a fresh empty directory. Ignored for
          claim and ephemeral backings.
        '';
      };

      source = lib.mkOption {
        type = backing;
        description = ''
          What backs this mount on your cluster. Exactly one of hostPath, claim
          or ephemeral. No default: the recipe cannot know your storage.
        '';
      };
    };

  # Render a set of declared mounts into the two halves Kubernetes wants.
  # `errors != [ ]` forces each mount's check — enough to know whether it yielded
  # a message — so a bad backing fails here rather than somewhere downstream.
  toVolumes =
    mounts:
    let
      errors = lib.concatLists (lib.mapAttrsToList checkMount mounts);
    in
    if errors != [ ] then
      throw (lib.concatStringsSep "\n" errors)
    else
      lib.mapAttrsToList volumeFor mounts;
  toVolumeMounts = mounts: lib.mapAttrsToList (name: m: { inherit name; mountPath = m.mountPath; }) mounts;
}
