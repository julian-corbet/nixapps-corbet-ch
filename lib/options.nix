# lib/options.nix — the two kinds of option, made unwritable-wrong.
#
# CONTRACT.md R2: every option is either KNOWLEDGE (true of the app everywhere,
# therefore carries a default so a stranger gets a working app) or a VALUE (true
# of one site only, therefore carries NO default and fails evaluation when
# unset). Rather than police that with a linter, these two constructors make the
# wrong shape impossible to write: `knowledge` refuses to build without a
# default, `value` refuses to build with one.
#
# The failure mode for an unset value is the module system's own "option is used
# but not defined" — which names the option path, and is exactly the loud
# failure R1 asks for. We deliberately do not wrap it in a prettier throw: a
# custom `apply` that throws would fire during *evaluation of a default
# elsewhere* in some configurations, turning a clear "you owe me this value"
# into a confusing trace from an unrelated option.
{ lib }:
let
  # Guard messages name the option's own description so the failure points at
  # the offending declaration rather than at this file.
  describe = args: if args ? description then lib.head (lib.splitString "\n" args.description) else "<no description>";
in
rec {
  # An option the RECIPE knows the answer to. Must ship a default.
  knowledge =
    args:
    assert lib.assertMsg (args ? default)
      "nixapps.lib.knowledge: a knowledge option must ship a default (CONTRACT R2) — ${describe args}";
    assert lib.assertMsg (args ? description)
      "nixapps.lib.knowledge: a knowledge option must carry its reason (CONTRACT R3) — every default a stranger inherits needs to say why";
    lib.mkOption args;

  # An option only the OPERATOR can answer. Must not ship a default, so that
  # enabling a recipe with no values fails and names what is owed (R1).
  value =
    args:
    assert lib.assertMsg (!(args ? default))
      "nixapps.lib.value: a value option must not ship a default (CONTRACT R2) — a default here is a lie about portability — ${describe args}";
    assert lib.assertMsg (args ? description)
      "nixapps.lib.value: a value option must say why it is site-specific (CONTRACT R3) — ${describe args}";
    lib.mkOption args;

  # A value the operator may legitimately decline to set, where "unset" is a
  # meaningful third state rather than an omission (an optional fixed address,
  # an optional pull secret). Still no default beyond null — null must MEAN
  # "the site does not use this", never "we guessed for you".
  # `type` is wrapped in nullOr here rather than at each call site: an optional
  # value is nullable by definition, and requiring every caller to remember the
  # wrapper produced exactly one bug — a str-typed option with a null default,
  # which type-checks fine until someone actually declines to set it.
  optionalValue =
    args:
    assert lib.assertMsg (!(args ? default) || args.default == null)
      "nixapps.lib.optionalValue: default must be null or absent (CONTRACT R2) — ${describe args}";
    assert lib.assertMsg (args ? type)
      "nixapps.lib.optionalValue: needs an explicit type to make nullable — ${describe args}";
    lib.mkOption (
      args
      // {
        type = lib.types.nullOr args.type;
        default = null;
      }
    );

  # ── The delivery envelope ────────────────────────────────────────────────
  # Identity every recipe needs, declared once. `category` is passed in by the
  # recipe from its own option path, which is how R4 makes the delivery project
  # and the path segment unable to drift apart: the default IS the path.
  envelope =
    {
      app,
      category,
      defaultNamespace ? app,
    }:
    {
      enable = lib.mkEnableOption "the ${app} recipe";

      appName = knowledge {
        type = lib.types.str;
        default = app;
        description = ''
          Name of the generated application, and of the workloads it renders.

          Overriding this is how an existing deployment is adopted in place: the
          delivery layer tracks applications by name, so rendering under the
          name already live retracks the existing objects instead of pruning and
          recreating them. That also keeps this recipe liftable — if the app ever
          graduates to its own project (CONTRACT R12), consumers change an import,
          not a workload name.
        '';
      };

      namespace = value {
        type = lib.types.str;
        description = ''
          Kubernetes namespace this app runs in. Site-specific: namespaces
          encode one operator's grouping, and two operators running this app
          will not agree on it. A conventional choice is "${defaultNamespace}".
        '';
      };

      createNamespace = knowledge {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this app's own application object creates the namespace it
          runs in.

          True is correct when this app is the only occupant. When several apps
          share one namespace, exactly one of them must anchor it — more than
          one anchor makes two applications claim the same object and they fight
          over it; none at all means nothing creates it unless the delivery
          layer already anchored it out of band.
        '';
      };

      project = knowledge {
        type = lib.types.str;
        default = category;
        description = ''
          Delivery project (grouping) this app belongs to.

          Defaults to this recipe's own category path segment, so the two cannot
          disagree (CONTRACT R4). Override only if your taxonomy files this app
          somewhere else — this repository mirrors a taxonomy, it does not
          enforce one.
        '';
      };
    };
}
