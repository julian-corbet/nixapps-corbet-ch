# lib/gpu-contract.nix — the consumer half of a hardware arbiter's contract.
#
# CONTRACT.md R9: an app holding scarce shared hardware DECLARES against the
# arbiter and manages nothing. The arbiter — which decides who gets the hardware,
# in what order, and what happens to whoever loses — is not in this repository
# and must not be reimplemented in fragments here.
#
# This file exists because that declaration is identical for every such app.
# Before it, the same eight options were copy-pasted verbatim between two
# recipes, which is the duplication R5 forbids: two copies of a cross-project
# contract drift, and the drift shows up as a pod that never schedules.
#
# Note what is NOT offered as an option: the update strategy. A rolling update
# briefly wants the old and new pod both running, and two holders of a
# single-slot device cannot coexist — the new pod stays Pending until the old one
# dies, which never happens, so the deployment wedges. That is a property of
# exclusive hardware, not a preference, so the fragment emits it and the recipe
# does not get a vote.
{ lib, options }:
let
  inherit (options) knowledge value optionalValue;
in
rec {
  contractOptions = {
    priorityClassName = value {
      type = lib.types.str;
      description = ''
        Priority class this app's pods run under, naming a rung of the arbiter's
        ladder.

        Site-specific and deliberately without a default: the rung names belong
        to whichever arbiter you run, and a wrong or absent priority is not a
        cosmetic mistake — it decides who gets evicted when the hardware fills
        up. Better to fail here than to schedule at an unintended priority and
        starve something that matters more.
      '';
    };

    nodeSelector = value {
      type = lib.types.attrsOf lib.types.str;
      description = ''
        Labels selecting the nodes that actually have the hardware.

        Site-specific: only you know which of your nodes carries the device, and
        what you label it.
      '';
    };

    deviceResourceName = value {
      type = lib.types.str;
      description = ''
        Extended-resource name the arbiter's device plugin advertises, requested
        as a limit so the scheduler accounts for one holder per slot.

        Site-specific: the name is the arbiter's, not this recipe's.
      '';
    };

    deviceResourceCount = knowledge {
      type = lib.types.ints.positive;
      default = 1;
      description = ''
        How many device slots this app holds while it runs.

        One, for almost everything: an app that holds more than a single slot is
        claiming it can usefully parallelise across them, which is a strong claim
        about the app rather than about the cluster.
      '';
    };

    labelDomain = value {
      type = lib.types.str;
      description = ''
        Label-key prefix the arbiter uses to recognise its tenants — this recipe
        renders `<domain>/managed` and `<domain>/engine` on the pod.

        One option rather than one per label, so there is a single string that
        has to agree with the arbiter instead of several that can each drift
        independently. Site-specific: the domain belongs to your arbiter
        deployment.
      '';
    };

    engineLabelValue = knowledge {
      type = lib.types.str;
      default = "compute";
      description = ''
        Which engine of the device this app occupies.

        Hardware typically exposes independent engines — general-purpose compute
        versus fixed-function media, for instance — and work on one does not
        block the other. Declaring it truthfully is what lets the arbiter let an
        app on a different engine run in parallel instead of evicting it.
      '';
    };

    runtimeEnv = optionalValue {
      type = lib.types.attrsOf lib.types.str;
      description = ''
        Extra environment variables the runtime needs to talk to your specific
        hardware — architecture overrides, visible-device masks, and similar.

        Site-specific by nature: these encode the exact card, not the app. Null
        means the runtime detects everything it needs.
      '';
    };
  };

  # What a declaring pod carries. Everything here is derived from the options
  # above — a recipe never assembles these fields itself.
  podLabels = cfg: {
    "${cfg.labelDomain}/managed" = "true";
    "${cfg.labelDomain}/engine" = cfg.engineLabelValue;
  };

  podSpec = cfg: {
    priorityClassName = cfg.priorityClassName;
    nodeSelector = cfg.nodeSelector;
  };

  containerLimits = cfg: { "${cfg.deviceResourceName}" = cfg.deviceResourceCount; };

  containerEnv = cfg: lib.optionalAttrs (cfg.runtimeEnv != null) cfg.runtimeEnv;

  # Non-negotiable, see the file header.
  strategy = { type = "Recreate"; };
}
