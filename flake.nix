{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "curtain_robot -- MicroPython curtain opener: stepper motor, VL53L0X time-of-flight sensor and an HTTP API. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose. flake-utils would buy exactly one
  # thing here -- eachDefaultSystem -- and the canonical machinery below already
  # provides it, without a second lock node and without a hardcoded system list
  # this repo cannot edit.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `self` is MANDATORY: the canonical machinery anchors every verb on it, so
    # `nix run /path/to/repo#lint` from an unrelated directory still knows which
    # tree it belongs to. `...` rather than a closed { self, nixpkgs }, so adding
    # a second input later does not fail with "called with unexpected argument".
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # ======================================================================
      # PER-REPO BLOCK 1 -- repoName
      # ======================================================================
      # Cosmetic: it names the interactive dev-shell banner and nothing else.
      # Still has to be right, because it is how a human tells two open shells
      # apart.
      repoName = "curtain_robot";

      # ======================================================================
      # PER-REPO BLOCK 2 -- the toolchain
      # ======================================================================
      # Read this first, because it is the one surprising thing about this repo:
      # most of the code here is MicroPython, not CPython, and is deployed onto
      # a microcontroller rather than executed on the host. Measured with the
      # python313 below (Python 3.13.15): `machine`, `network`, `ntptime`,
      # `ustruct`, `utime`, `micropython` and `requests` all fail to import.
      # Which files need them:
      #   VL53L0X.py    micropython, ustruct, utime, machine
      #   stepper.py    machine
      #   curtain_bot.py machine (and imports VL53L0X.py and stepper.py)
      #   main.py       network, ntptime
      #   test.py       network, machine, requests
      #
      # What IS host-importable, measured the same way: utils.py (stdlib `re`),
      # micropyserver.py (stdlib re/socket/sys/io), test_utils.py, and boot.py --
      # which is a single comment line with no imports at all.
      #
      # test_utils.py runs 9 unittest cases against utils.py and they all pass
      # on this interpreter. That, plus static analysis, is the whole of the
      # desktop surface, and it needs zero third-party packages. Hence: no uv,
      # no venv, no requirements file, and no `setup` verb.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      #
      # Pin language runtimes by MAJOR (python313), never by rolling alias
      # (python3). Measured on this lock: `python3` is already 3.14.7 while
      # `python313` is 3.13.15, so the alias has moved a whole minor version
      # past the interpreter the 9 tests below were last run on.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        pkgs.python313
        pkgs.ruff
        # The official MicroPython remote tool -- this is how source gets onto
        # the board over USB serial. On this pin it is mpremote-1.25.0 and it
        # already carries pyserial: its propagated-build-inputs name
        # python3.14-pyserial-3.5, on its own python3-3.14.7, independent of the
        # python313 above. Do not add a pyserial to this list.
        pkgs.mpremote

        # picotool/esptool are deliberately absent: installing the MicroPython
        # runtime onto a bare board is one-off bringup rather than repo work,
        # and no verb below invokes either of them.

        # ---- general-purpose, for the human and the agent at the prompt ----
        # No verb below invokes these; they are here so an interactive shell is
        # not missing the obvious. The canonical anchor needs no git (it
        # compares flake.nix with bash's own `$(<file)`).
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- libraries that get dlopened, not linked
      # ======================================================================
      # Empty, and that is the honest answer: the host side of this repo touches
      # nothing but the Python standard library, so there is no manylinux wheel
      # and no compiled extension to dlopen a stray libstdc++. The machinery
      # skips the LD_LIBRARY_PATH export entirely for an empty list, so the
      # caller's LD_LIBRARY_PATH is left byte-for-byte untouched.
      #
      # If a host-side dependency ever arrives, add pkgs.stdenv.cc.cc.lib and
      # pkgs.zlib HERE -- not to `toolchain`. Linux-only attrs are safe here and
      # only here, because this list is never forced on darwin.
      nativeLibs = pkgs: [ ];

      # ======================================================================
      # PER-REPO BLOCK 4 -- constant environment variables
      # ======================================================================
      # Constants only. Anything that must READ an existing value
      # (LD_LIBRARY_PATH) or UNSET something (SOURCE_DATE_EPOCH) is the
      # machinery's business, not this attrset's.
      #
      # Applied to BOTH surfaces -- the dev shell and every `nix run` wrapper --
      # so a command cannot behave differently depending on how it was invoked.
      envVars = pkgs: {
        # The .py files here get copied verbatim onto a microcontroller, so a
        # __pycache__/ that CPython dropped beside them during `dev-test` is
        # noise sitting in the deploy directory. .gitignore already lists
        # __pycache__/ and *.pyc, so git never sees them; this stops them being
        # written in the first place.
        PYTHONDONTWRITEBYTECODE = "1";
        # print() is this codebase's only debugging channel -- there is no
        # `import logging` anywhere in the 9 .py files. Unbuffered, that output
        # stays correctly interleaved with stderr when an agent captures both
        # through a pipe instead of a tty.
        PYTHONUNBUFFERED = "1";
      };

      # ======================================================================
      # PER-REPO BLOCK 5 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#test`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-test` actually runs.
      #
      # `setup` and `build` are ABSENT, and their absence is information: there
      # is nothing to install (no requirements file, no third-party imports on
      # the host side) and nothing to compile -- MicroPython sources are
      # deployed as-is, there is no artifact.
      #
      # Every text starts with `cd "$REPO_ROOT"`, and that cd is load-bearing
      # rather than tidy. Defaulting the path argument to "$REPO_ROOT" covers
      # the no-argument case, but only the cd covers the FLAG-ONLY one:
      # `dev-lint --show-files` expands to a non-empty "$@" with no path in it,
      # so ruff falls back to its own default of ".". Measured, standing in a
      # foreign directory: `ruff check --show-files` with no path argument
      # listed that directory's bot.py and victim.py and exited 0. The
      # verbAnchoring check below is the regression gate for exactly this, and
      # it was mutation-tested -- deleting this one cd makes it fail.
      #
      # Consequence to know about: a relative path you pass is therefore
      # relative to the repo root, not to your cwd, which is also what makes it
      # impossible for one to escape the repo.
      #
      # ruff gets `--no-cache` everywhere, because it writes .ruff_cache into
      # the directory it was pointed at and both possible directories are wrong.
      # Outside a checkout that is the read-only store snapshot: measured, ruff
      # there exits 2 with "Failed to initialize cache at
      # /nix/store/...-source/.ruff_cache: Read-only file system" having linted
      # nothing -- a false RED. Inside a checkout it is untracked clutter that
      # earlier automation kept leaving behind. Nine Python files lint in
      # milliseconds; the cache is not worth either failure mode.
      commands = pkgs: {
        test = {
          # A bare `python3` is correct here: there is no venv, so the store
          # interpreter the wrappers put on PATH is the only interpreter.
          #
          # The file is named directly rather than handed to `unittest
          # discover`, because discover's default test*.py pattern also picks up
          # test.py, an on-board MicroPython scratch script. Measured:
          # `python3 -m unittest discover` here reports "Ran 10 tests" and
          # "FAILED (errors=1)" -- ModuleNotFoundError: No module named
          # 'network', from test.py line 1.
          description = "run the 9 host-side unittest cases in test_utils.py";
          text = ''
            cd "$REPO_ROOT"
            python3 test_utils.py "$@"
          '';
        };
        lint = {
          # Honest description: this exits 1 today. Measured on this pin (ruff
          # 0.16.2, no ruff config in the repo, so ruff's own defaults): 23
          # findings, spread test.py 6, micropyserver.py 5, stepper.py 4,
          # VL53L0X.py 3, curtain_bot.py 3, main.py 1, test_utils.py 1 -- and
          # utils.py 0. One of them is real rather than stylistic: F821
          # undefined name `connect` at test.py:57. A cold agent must not read
          # that exit code as "the flake is broken".
          description = "ruff check the whole repo, from any cwd (exits 1: 23 pre-existing findings in tree)";
          text = ''
            cd "$REPO_ROOT"
            ruff check --no-cache "''${@:-$REPO_ROOT}"
          '';
        };
        fmt = {
          # MUTATING, so it refuses instead of half-working:
          # need_writable_checkout fails loudly when the only tree in reach is
          # the read-only store snapshot, rather than falling back to the
          # caller's directory and rewriting files that are not ours.
          description = "ruff format the repo (rewrites files, so it needs a writable checkout)";
          text = ''
            need_writable_checkout
            cd "$REPO_ROOT"
            ruff format --no-cache "''${@:-$REPO_ROOT}"
          '';
        };
        run = {
          # NEEDS HARDWARE, and this verb has NOT been verified end to end: no
          # board was attached. What was verified is that mpremote is on PATH
          # and that this text is shellcheck-clean at build time. The serial
          # handshake is the untested part.
          #
          # test.py and test_utils.py are deliberately not copied -- the former
          # is an abandoned scratch script (it is the file carrying the F821),
          # the latter is host-only. index.html is not copied either: it is
          # empty and nothing in main.py reads it.
          #
          # Every source is named under $REPO_ROOT, so this deploys THIS repo
          # whatever the cwd, and never some same-named file next to the caller.
          description = "copy the board sources over USB and start main.py (needs hardware + my_secrets.py)";
          text = ''
            cd "$REPO_ROOT"
            # my_secrets.py is gitignored (it holds the WLAN credentials) and
            # main.py does `from my_secrets import ssid, passw`, so a missing
            # file means an ImportError on the board rather than here. Fail
            # early instead. Outside a checkout $REPO_ROOT is the store
            # snapshot, which cannot contain a gitignored file, so this is also
            # what stops the verb from flashing a board from the store copy.
            if [ ! -f "$REPO_ROOT/my_secrets.py" ]; then
              echo "my_secrets.py is missing: create it next to main.py with 'ssid' and 'passw'" >&2
              exit 1
            fi
            mpremote connect auto fs cp \
              "$REPO_ROOT/boot.py" \
              "$REPO_ROOT/main.py" \
              "$REPO_ROOT/curtain_bot.py" \
              "$REPO_ROOT/stepper.py" \
              "$REPO_ROOT/micropyserver.py" \
              "$REPO_ROOT/utils.py" \
              "$REPO_ROOT/VL53L0X.py" \
              "$REPO_ROOT/my_secrets.py" \
              :
            mpremote connect auto run "$REPO_ROOT/main.py" "$@"
          '';
        };
      };

      # ======================================================================
      # PER-REPO BLOCK 6 -- extra checks
      # ======================================================================
      # The machinery's `anchoring` check proves the MECHANISM behaves. It does
      # not prove that THIS repo's verbs use it. This one drives the actual
      # wrappers from inside a foreign tree.
      #
      # It is not decoration, and that was tested rather than assumed: on a
      # copy of this repo with the single `cd "$REPO_ROOT"` deleted from `lint`,
      # this derivation failed with "dev-lint --show-files did not list this
      # repo's files", printing /build/decoy/main.py and
      # /build/decoy/sibling_only.py.
      #
      # `run` is not exercised: it needs a USB-attached board. Its guard is
      # covered indirectly -- from the sandbox $REPO_ROOT is the store snapshot,
      # which cannot hold the gitignored my_secrets.py.
      extraChecks = pkgs: {
        verbAnchoring =
          pkgs.runCommand "verb-anchoring-check"
            {
              nativeBuildInputs = lib.attrValues (wrappers pkgs);
            }
            ''
              set -euo pipefail

              # Logs live OUTSIDE the decoy, so the diff at the end needs no
              # --exclude and any new file at all is a failure.
              mkdir logs decoy
              cd decoy
              # main.py is a name this repo really has -- a marker-file anchor
              # falls for it. sibling_only.py is a name this repo does not have.
              printf 'import os\nx  =1\n' > main.py
              printf 'import json\ny  =2\n' > sibling_only.py
              printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > flake.nix
              cp -r . ../decoy.orig

              # Grep by NAME, never by directory: a wrongly-anchored ruff is
              # also STANDING in the decoy, so it prints bare relative paths and
              # a grep for "decoy" would match nothing. sibling_only.py is the
              # name that cannot be spelled both ways.
              dev-lint > ../logs/lint.log 2>&1 || true
              if grep -q sibling_only ../logs/lint.log; then
                echo "dev-lint graded the decoy" >&2
                cat ../logs/lint.log >&2
                exit 1
              fi

              # ...and it must have read SOMETHING. --show-files rather than the
              # findings, because the findings drop to zero the day somebody
              # fixes them, and a cleaned-up repo must not turn this check red.
              dev-lint --show-files > ../logs/files.txt
              grep -q '/micropyserver\.py$' ../logs/files.txt || {
                echo "dev-lint --show-files did not list this repo's files" >&2
                cat ../logs/files.txt >&2
                exit 1
              }
              if grep -q sibling_only ../logs/files.txt; then
                echo "dev-lint --show-files listed the decoy" >&2
                exit 1
              fi

              # dev-test can only find test_utils.py under $REPO_ROOT; the decoy
              # has none. Running it here at all proves the anchor resolved.
              dev-test > ../logs/test.log 2>&1
              grep -q 'Ran 9 tests' ../logs/test.log || {
                echo "dev-test did not run this repo's 9 cases" >&2
                cat ../logs/test.log >&2
                exit 1
              }

              # Refusal, not silence, and not a half-done rewrite.
              if dev-fmt > ../logs/fmt.log 2>&1; then
                echo "dev-fmt succeeded in a foreign tree; it must refuse" >&2
                cat ../logs/fmt.log >&2
                exit 1
              fi

              diff -r . ../decoy.orig
              touch "$out"
            '';
      };

      # >>>>> BEGIN CANONICAL MACHINERY v1 <<<<<
      # ======================================================================
      # Everything from the BEGIN sentinel above to the END sentinel on the last
      # line of this file is fleet-canonical text: the same bytes in every repo
      # that carries this flake style. That is a checkable claim, not a boast --
      #
      #   sed -n '/BEGIN CANONICAL MACHINERY v1/,$p' flake.nix | sha256sum
      #
      # prints the same digest in every repo, or one of them has been edited.
      # (`,$p`, not a range ending on the END sentinel: a range whose closing
      # pattern were spelled out here would terminate on this very comment.)
      # Nothing here names a repository, a language, a tool or a project file.
      # If you find such a name below, it is contamination: the fix is to move
      # it into the per-repo section above, never to special-case it here.
      #
      # This region READS exactly these names from the per-repo section:
      #   nixpkgs  self  lib  repoName  toolchain  nativeLibs  envVars
      #   commands  extraChecks
      # and DEFINES exactly these:
      #   systems  forAllSystems  ldPreamble  rootPreamble  guardPreamble
      #   wrappers  helpFor  anchorCheck
      # plus the four flake outputs apps / devShells / checks / formatter.
      # Anything else in scope is invisible to it. The types of those eight
      # inputs, and the shell variables this region exports into command texts,
      # are specified in INTERFACE.md, which travels with this block.
      #
      # To change behaviour here you change it in every repo at once and bump
      # the version in both sentinels. A local edit is a bug by construction:
      # the digest above stops matching, and -- because rootPreamble anchors on
      # flake.nix byte-identity -- an edited working tree also stops being
      # recognised by wrappers built from the previous revision.
      # ======================================================================

      # ---- systems policy: decided once for the whole fleet ----
      #
      # Read this list as "evaluated on three, built on one". That is what was
      # measured, and it is all it means:
      #   * `nix flake check --all-systems` passes, so every output attribute
      #     below EVALUATES on all three systems.
      #   * only x86_64-linux has ever been BUILT. The machine this was verified
      #     on has no aarch64 emulation -- no binfmt handler, and `extra-
      #     platforms` is x86-only -- so aarch64 cannot be built there at all.
      # It is not a statement that anything works on aarch64. Do not upgrade it
      # into one in a README.
      #
      # Evaluating all three is still worth its seconds, because the failure it
      # catches is an eval-time failure: a `pkgs.<attr>` that exists on Linux
      # and not on darwin (`stdenv.cc.cc.lib` is the usual one) throws during
      # evaluation, and `nix flake check` without --all-systems checks only the
      # current system and sails straight past it.
      #
      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with a `throw`. genAttrs is lazy, so plain `nix develop`
      # on Linux would not notice -- it detonates later, on the --all-systems
      # run this policy requires. Add it back only against a separate
      # nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather
      # than a system string, because that is what every call site wants, and
      # keeps the system list in this file rather than in a second input's
      # hardcoded copy of it.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      #
      # `&&` short-circuits in Nix, so on darwin `nativeLibs pkgs` is never
      # forced. That is load-bearing for the systems policy above: it is what
      # lets a repo list Linux-only attrs in nativeLibs and still evaluate on
      # aarch64-darwin. Do not reorder the two operands.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $SRC_ROOT and $REPO_ROOT. `nix run` and `nix develop`
      # both start in whatever directory they were invoked from, and no verb may
      # act on that directory -- these two are what it acts on instead.
      #
      # $SRC_ROOT is this flake's own source, snapshotted into the store when
      # the flake was evaluated. It is the one anchor that is always available:
      # `nix run /path/to/repo#lint` tells the running program nothing whatever
      # about /path/to/repo (flake refs are location-independent by design, and
      # there is no $FLAKE_DIR to read), so without `self` a wrapper invoked
      # that way has literally no way to name the repo it belongs to. Two
      # limitations worth knowing: it is read-only, being a store path, and in a
      # git checkout it contains only TRACKED files.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. Three things this deliberately is NOT:
      #
      #   * NOT `pwd`. A fallback to the caller's directory is how `fmt`
      #     rewrites a stranger's source tree and how `lint` prints "all checks
      #     passed" having read none of this repo.
      #   * NOT `git rev-parse --show-toplevel`. Run from inside some OTHER git
      #     repo it cheerfully answers with THAT repo's top level. It also needs
      #     git on PATH and a .git directory, so it fails on an export and in
      #     any wrapper whose toolchain omits git.
      #   * NOT an inherited $REPO_ROOT from the environment. The dev shell
      #     EXPORTS this variable, so honouring it would mean that running
      #     `nix run /path/to/B#fmt` from inside repo A's dev shell points B's
      #     formatter at A. An explicit path argument is how a caller overrides
      #     a verb's target; an ambient variable is how they do it by accident.
      #
      # Instead: walk up from $PWD and take the first ancestor that IS this
      # repo, proved by carrying a byte-identical flake.nix. A single tracked
      # filename, a marker directory, or a set of them is not proof -- sibling
      # repos in a fleet share those, and a decoy can be built to carry any list
      # of names you care to publish. The whole flake.nix is what distinguishes
      # repos, because description, toolchain and command map all differ, so the
      # whole flake.nix is what gets compared. Compared with bash's own
      # `$(<file)` rather than cmp or sha256sum, so the check depends on no
      # package at all -- pure builtins, correct even in a wrapper whose PATH
      # carries nothing but the repo's own toolchain.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg "${self}"}
        export SRC_ROOT

        _dev_find_root() {
          local dir ref
          ref=$(<"$SRC_ROOT/flake.nix") || return 1
          dir=$(
            unset CDPATH
            cd -P -- "''${1:-.}" 2>/dev/null && pwd
          ) || return 1
          while [ -n "$dir" ]; do
            if [ -f "$dir/flake.nix" ] && [ "$(<"$dir/flake.nix")" = "$ref" ]; then
              printf '%s\n' "$dir"
              return 0
            fi
            dir=''${dir%/*}
          done
          return 1
        }

        REPO_ROOT="$(_dev_find_root "$PWD" || printf '%s\n' "$SRC_ROOT")"
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead
      # of falling back to "well, the cwd then".
      #
      # The test is $REPO_ROOT != $SRC_ROOT, i.e. "rootPreamble found a real
      # checkout", not a permission or a store-path-prefix test. Both of those
      # answer a narrower question: a checkout may be read-only for unrelated
      # reasons, and a store path is not the only tree we must refuse to write.
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "''${0##*/}: this command rewrites files, so it needs a writable" >&2
          echo "checkout of this repo -- and standing in $PWD there is none: no" >&2
          echo "parent directory carries this flake's flake.nix. The only tree in" >&2
          echo "reach is the read-only store snapshot $SRC_ROOT, and rewriting" >&2
          echo "$PWD instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      #
      # writeShellApplication, not writeShellScriptBin: it runs shellcheck at
      # BUILD time and sets `set -euo pipefail`, so an unquoted $@ or a silently
      # ignored failure is a `nix flake check` failure rather than a surprise in
      # front of an agent.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${guardPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      # `dev-help` is generated from the same attrset as everything else, so it
      # cannot describe a verb that does not exist or miss one that does. No
      # runtimeInputs: printing the map must work with nothing installed.
      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };

      # The regression gate for rootPreamble and guardPreamble, which are the
      # two pieces of this flake that can silently damage a tree that is not
      # this repo. It tests the MECHANISM, not any verb, which is precisely what
      # makes it fleet-generic: it needs to know nothing about what this repo
      # does, only that the anchor resolves and the guard refuses.
      #
      # The decoy is a real directory carrying a real flake.nix that differs.
      # Marker-file anchors pass a decoy like this -- that is the whole point of
      # the probe -- and so does any anchor that trusts `pwd`. Probe 2 is the
      # other half, and without it a guard that refused everything would score a
      # perfect pass: a tree that IS byte-identical must still be adopted, or
      # every mutating verb in the repo is dead. Probe 3 pins the subdirectory
      # case, which is the normal one for an agent working inside a repo.
      #
      # A per-repo probe that drives the actual verbs is strictly better and
      # cannot live here -- it has to know which verb writes and which needs a
      # network. INTERFACE.md shows how to add one via `extraChecks`.
      anchorCheck =
        pkgs:
        pkgs.runCommand "anchor-check" { } ''
          set -euo pipefail

          # The two preambles under test, verbatim, in a file the probes source.
          # A quoted heredoc, so every $ below is the bash the wrappers see.
          cat > preamble.sh <<'CANONICAL_PREAMBLE_EOF'
          ${rootPreamble}
          ${guardPreamble}
          CANONICAL_PREAMBLE_EOF

          mkdir decoy
          printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > decoy/flake.nix
          printf 'do not touch me\n' > decoy/victim.txt
          cp -r decoy decoy.orig

          # ---- probe 1: a foreign tree must not be adopted ----
          if ! ( cd decoy && . ../preamble.sh && [ "$REPO_ROOT" = "$SRC_ROOT" ] ); then
            echo "anchor adopted a directory that is not this repo" >&2
            exit 1
          fi
          # In a subshell: need_writable_checkout ends in `exit`, which would
          # otherwise take this whole build down instead of failing a condition.
          if ( cd decoy && . ../preamble.sh && need_writable_checkout ) > guard.log 2>&1; then
            echo "need_writable_checkout accepted a tree that is not this repo" >&2
            exit 1
          fi
          if ! diff -r decoy decoy.orig; then
            echo "the probes modified the foreign tree" >&2
            exit 1
          fi

          # ---- probe 2: a byte-identical checkout must be adopted ----
          cp -r ${lib.escapeShellArg "${self}"} checkout
          chmod -R u+w checkout
          if ! ( cd checkout && . ../preamble.sh &&
                 [ "$REPO_ROOT" = "$(pwd -P)" ] && need_writable_checkout ); then
            echo "anchor refused a byte-identical checkout of this repo" >&2
            exit 1
          fi

          # ---- probe 3: from a subdirectory, still the checkout root ----
          mkdir -p checkout/probe3/deeper
          if ! ( cd checkout/probe3/deeper && . ../../../preamble.sh &&
                 [ "$REPO_ROOT" = "$(cd -P ../.. && pwd)" ] ); then
            echo "anchor did not walk up to the checkout root from a subdirectory" >&2
            exit 1
          fi

          touch "$out"
        '';
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Natively-compiled extension modules are routinely built at -O0,
          # where glibc's _FORTIFY_SOURCE stops being a warning and becomes a
          # hard error.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            # $REPO_ROOT and $SRC_ROOT are exported here as a convenience for
            # the human at the prompt. Every wrapper re-resolves them from
            # scratch and none of them reads these, on purpose: a stale value
            # exported by one repo's shell must never steer another repo's verb.
            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No environment
            # bootstrapping, no dependency installation, no `read`, no
            # `exec $SHELL`. Bootstrapping in the hook makes a cold
            # `nix develop -c <anything>` start downloading before it runs
            # anything, on EVERY invocation -- the exact failure an unattended
            # agent cannot diagnose. That is what a `setup` verb is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "${repoName} dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction, and the only gate this
      # style has. `toolchain` realises the whole toolchain closure (so a typo'd
      # or currently-broken attr fails here, not halfway through a task) and
      # builds every wrapper, which runs shellcheck over every command text.
      # `anchoring` is the regression test described above.
      #
      # Repo-specific checks go in `extraChecks`, never here. They may not
      # shadow either canonical name: silently replacing `anchoring` with
      # something weaker is the exact failure this whole file exists to make
      # impossible, so a collision is an eval error with both names in it.
      #
      # NEVER add a check that always passes. An agent reads "all checks
      # passed!" as a signal, and a fake check makes `nix flake check` a liar.
      checks = forAllSystems (
        pkgs:
        let
          canonical = {
            toolchain =
              pkgs.runCommand "toolchain-check"
                {
                  nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];
                }
                ''
                  set -euo pipefail
                  dev-help > help.txt

                  # A while-read over a heredoc rather than `for x in <list>`,
                  # which is a bash syntax error when the list is empty -- and a
                  # repo with no verbs yet is a legitimate state.
                  while IFS= read -r verb; do
                    [ -n "$verb" ] || continue
                    command -v "dev-$verb" > /dev/null || {
                      echo "dev-$verb is not on PATH" >&2
                      exit 1
                    }
                    grep -q -- "dev-$verb" help.txt || {
                      echo "dev-$verb is missing from the dev-help map" >&2
                      exit 1
                    }
                  done <<'CANONICAL_VERBS_EOF'
                  ${lib.concatStringsSep "\n" (lib.attrNames (commands pkgs))}
                  CANONICAL_VERBS_EOF

                  touch "$out"
                '';
            anchoring = anchorCheck pkgs;
          };
          extra = extraChecks pkgs;
          clash = lib.intersectLists (lib.attrNames canonical) (lib.attrNames extra);
        in
        if clash != [ ] then
          throw "extraChecks must not redefine canonical checks: ${lib.concatStringsSep ", " clash}"
        else
          canonical // extra
      );

      # `nix fmt` -- formats the *Nix* in this repo; project code gets a `fmt`
      # verb. nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because
      # bare nixfmt tries to parse every path handed to it and fails on non-Nix
      # files. This file ships already formatted, so `nix fmt` is a no-op rather
      # than a diff across the fleet.
      #
      # This is the one verb here NOT anchored to $REPO_ROOT, and it cannot be:
      # `nix fmt` is nix's own verb, and nix -- not this flake -- decides which
      # paths the formatter receives, passing the cwd when the user names none.
      # A wrapper that overrode them would break `nix fmt path/to/one/file.nix`,
      # and it cannot tell that "." apart from the default. So `nix fmt` formats
      # where you stand, by design; the `fmt` verb is the anchored one.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
# >>>>> END CANONICAL MACHINERY v1 <<<<<
