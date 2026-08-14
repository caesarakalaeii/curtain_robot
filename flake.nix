{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "curtain_robot -- MicroPython curtain opener (stepper + VL53L0X ToF + HTTP API) for a Pico W class board. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node in
  # every repo (flake-utils transitively pulls `systems`, so really two), a
  # second upstream that can break one repo and not the other forty, and a
  # hardcoded system list this repo cannot edit. That list is currently broken:
  # it still contains x86_64-darwin, which now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `self` is bound because every command has to know where this repo IS --
    # its own source path is the only anchor that survives being invoked as
    # `nix run /path/to/repo#lint` from an unrelated directory (see
    # rootPreamble). `...` rather than a closed { self, nixpkgs } all the same:
    # adding a second input later would otherwise fail with "called with
    # unexpected argument '<that input>'".
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with `throw "Nixpkgs 26.11 has dropped support for
      # x86_64-darwin"`. genAttrs is lazy, so plain `nix develop` on Linux would
      # not notice -- it detonates later, on `nix flake check --all-systems`.
      # Add it back only against a separate nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # Read this first, because it is the one surprising thing about this repo:
      # the code here is MicroPython, not CPython. boot.py, main.py, stepper.py,
      # curtain_bot.py, VL53L0X.py and test.py import `machine`, `network`,
      # `_thread`, `ntptime`, `micropython.const`, `ustruct` and `utime`, none of
      # which exist off-board. They are deployed onto the microcontroller
      # verbatim; they are never executed on the host, and no host Python can
      # make them importable.
      #
      # What IS host-runnable is utils.py (stdlib `re` only) and its
      # test_utils.py -- 9 unittest cases that genuinely pass on CPython 3.13.
      # That, plus static analysis, is the whole of the desktop surface, and it
      # needs zero third-party packages. Hence: no uv, no venv, no requirements
      # file, and no `setup` verb -- this shell is fully offline.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      #
      # Pin language runtimes by MAJOR (python313), never by rolling alias
      # (python3). An alias that moves under you invalidates every .venv in the
      # fleet on the same afternoon.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        pkgs.python313
        pkgs.ruff
        # The official MicroPython remote tool -- this is how source gets onto the
        # board over USB serial. It vendors its own pyserial, so do NOT add
        # python313Packages.pyserial beside it.
        pkgs.mpremote

        # Two omissions that look like oversights and are not:
        #
        # `pkgs.micropython` (the unix port) FAILS TO BUILD on this pin -- 10 of
        # its own tests fail in checkPhase (basics/try_finally_return2.py,
        # float/math_fun.py, ...), so including it would make `nix flake check`
        # red for a binary that still cannot import `machine`. Do not "fix" this
        # by adding it back with doCheck = false; there is no verb that needs it.
        #
        # picotool/esptool flash the MicroPython runtime itself. That is one-off
        # board bringup, not repo work, and it wants BOOTSEL-mode USB anyway.

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Empty on purpose, and that is the honest answer here: the host side of
      # this repo touches nothing but the Python standard library, so there is no
      # manylinux wheel and no compiled extension to dlopen a stray libstdc++.
      # ldPreamble below skips the export entirely for an empty list, which means
      # the caller's LD_LIBRARY_PATH is left byte-for-byte untouched.
      #
      # If a host-side dependency ever arrives (pyserial is already vendored
      # inside mpremote, so it does not count), add pkgs.stdenv.cc.cc.lib and
      # pkgs.zlib HERE -- not to `toolchain`.
      nativeLibs = pkgs: [ ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only values that are constants belong here. Anything that must READ an
      # existing value (LD_LIBRARY_PATH), UNSET something (SOURCE_DATE_EPOCH) or
      # touch the work tree goes in the shellHook further down.
      #
      # This attrset is applied to BOTH surfaces -- the dev shell and every
      # `nix run` wrapper -- so a command cannot behave differently depending on
      # how it was invoked.
      #
      # None of the fleet's UV_* pins appear here because there is no uv and no
      # venv in this repo (see block 1).
      envVars = pkgs: {
        # The .py files in this repo get copied verbatim onto a microcontroller
        # with a few hundred KB of flash. A __pycache__/ that CPython dropped
        # next to them during a test run is pure confusion at deploy time.
        PYTHONDONTWRITEBYTECODE = "1";
        # print() in this codebase is the primary debugging channel. Unbuffered,
        # it stays correctly interleaved with stderr when an agent captures both
        # through a pipe instead of a tty.
        PYTHONUNBUFFERED = "1";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#test`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-test` actually runs.
      #
      # `setup` and `build` are ABSENT, and their absence is information:
      # there is nothing to install (no requirements file, no third-party
      # imports on the host side) and nothing to compile -- MicroPython sources
      # are deployed as-is, there is no artifact.
      #
      # `text` is bash under `set -euo pipefail`, shellcheck'd at BUILD time, and
      # it runs with the repo root as its cwd (see `wrappers`) so that a verb
      # behaves the same however it was invoked, while still seeing uncommitted
      # edits when there is a checkout. Rules for writing one:
      #   * always end with a quoted "$@" -- unquoted $@ fails the build (SC2068)
      #   * a bare "$@" must never be the ONLY path argument: with no arguments
      #     the tool then walks its own default of ".", and that used to be the
      #     caller's directory. Default it -- "${@:-$REPO_ROOT}" -- or name the
      #     files under $REPO_ROOT outright, as `test` and `run` do
      #   * $REPO_ROOT is this repo from any cwd, and $REPO_SRC is the read-only
      #     store copy of it; they are equal exactly when no checkout was found,
      #     which is how a MUTATING verb detects that it has nothing to write to
      #   * use $REPO_ROOT for anything stateful ("$REPO_ROOT/.venv"), never a
      #     bare relative path
      #   * pass the batch/non-interactive flag to anything that could prompt:
      #     there is no tty, so a prompt hangs until the agent's timeout
      #   * say "(network)" in the description of anything that needs it

      # ruff insists on a .ruff_cache/ in the project root it was pointed at, and
      # it does not degrade gracefully when that root is read-only: outside a
      # checkout it exited 2 with `Failed to create temporary file ...
      # /nix/store/...-source/.ruff_cache/...` and linted nothing -- a false RED
      # to replace the old false GREEN. So redirect the cache in exactly that
      # case. Inside a checkout the default .ruff_cache/ is kept (it ships its
      # own .gitignore, so it never shows up in `git status`) and repeat runs
      # stay warm. $UID keeps two users out of each other's /tmp directory.
      ruffCachePreamble = ''
        if [ "$REPO_ROOT" = "$REPO_SRC" ]; then
          export RUFF_CACHE_DIR="''${TMPDIR:-/tmp}/ruff-cache-$UID"
        fi
      '';

      commands = pkgs: {
        test = {
          # A bare `python3` is correct here, unlike in the venv-shaped repos in
          # this fleet: there is no .venv, so the store interpreter the wrappers
          # put on PATH is the only interpreter, and naming it absolutely would
          # buy nothing.
          #
          # The test file is named by absolute path rather than handed to
          # `unittest discover` for two reasons: it puts $REPO_ROOT on sys.path
          # (so `import utils` resolves from any cwd), and discover's default
          # test*.py pattern would also try to import test.py, which is an
          # on-board MicroPython scratch script and dies on `import network`.
          description = "run the 9 host-side unittest cases in test_utils.py";
          text = ''python3 "$REPO_ROOT/test_utils.py" "$@"'';
        };
        lint = {
          # Honest description: this exits 1 today. ruff finds 23 pre-existing
          # issues, mostly in the vendored micropyserver.py/utils.py/VL53L0X.py
          # plus a real F821 (test.py calls an undefined `connect()`). A cold
          # agent must not read that exit code as "the flake is broken".
          #
          # Those 23 are also what it reports from an unrelated directory, which
          # is the point of the default below: with a bare "$@" this gate went
          # green on an empty cwd, and a check that passes by looking at nothing
          # is worse than no check at all.
          description = "ruff check the whole repo, from any cwd (exits 1: 23 pre-existing findings in tree)";
          text = ''
            ${ruffCachePreamble}
            ruff check "''${@:-$REPO_ROOT}"
          '';
        };
        fmt = {
          # MUTATING, so this one refuses instead of half-working. With no
          # checkout in sight $REPO_ROOT is the read-only store copy of this
          # flake and `ruff format` would emit "Permission denied" per file; the
          # one thing it must never do is fall back to the caller's directory and
          # rewrite files that are not ours. Explicit arguments are still
          # honoured -- the cd in `wrappers` keeps a relative one inside the repo.
          description = "ruff format the repo (rewrites files, so it needs a checkout)";
          text = ''
            if [ "$#" -eq 0 ] && [ "$REPO_ROOT" = "$REPO_SRC" ]; then
              echo "dev-fmt rewrites files and found no checkout to rewrite: run it from inside a clone of this repo, or name paths explicitly" >&2
              exit 1
            fi
            ${ruffCachePreamble}
            ruff format "''${@:-$REPO_ROOT}"
          '';
        };
        run = {
          # NEEDS HARDWARE, and this could not be validated when the flake was
          # written because no board was attached. What was verified is that
          # mpremote is on PATH and this text is shellcheck-clean; the serial
          # handshake is the untested part.
          #
          # test.py and test_utils.py are deliberately not copied -- the former is
          # an abandoned scratch script, the latter is host-only.
          #
          # Every source is named under $REPO_ROOT, so this deploys THIS repo
          # whatever the cwd, and never some same-named file next to the caller.
          # Outside a checkout $REPO_ROOT is $REPO_SRC, which cannot contain the
          # gitignored my_secrets.py, so the guard below is also what stops this
          # verb from flashing a board from the store copy.
          description = "copy the firmware to a USB-attached board and start main.py (needs hardware + my_secrets.py)";
          text = ''
            # my_secrets.py is gitignored (it holds the WLAN credentials) and
            # main.py imports `ssid` and `passw` from it, so a missing file means
            # an ImportError on the board rather than here. Fail early instead.
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
      # GENERIC MACHINERY -- byte-identical in all 41 repos, do not edit
      # ======================================================================
      # `rootPreamble` and the cd in `wrappers` below were edited once, to fix
      # the anchoring bug described at each of them. That edit belongs in all 41
      # copies: a repo left on the old `git rev-parse ... || pwd` version still
      # lints and formats whatever directory it is called from.

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $REPO_ROOT, and it points at THIS repo -- never at
      # the caller's cwd. That distinction is the whole point: the first cut of
      # this file resolved `git rev-parse --show-toplevel 2>/dev/null || pwd`,
      # which is the caller's tree, and `nix run /path/to/repo#<verb>` (the form
      # CI and a cold agent use) then acted on wherever it was launched from --
      # `#lint` in an empty directory printed "All checks passed!" and exited 0
      # after inspecting zero files, and `#fmt` reformatted the .py files it
      # found there.
      #
      # $REPO_SRC is this flake's own source, baked in at build time, so it is
      # correct from any cwd on any machine. It is the read-only store copy of
      # the git-tracked tree -- exactly what a flake URL denotes -- so the
      # read-only verbs work from anywhere and report the same findings they do
      # in a clone.
      #
      # A live checkout still wins when the caller genuinely stands in THIS
      # repo, so an agent can lint or format uncommitted edits. "Genuinely this
      # repo" means the checkout's flake.nix is byte-identical to the one these
      # wrappers were built from; if it differs, the wrapper on PATH was not
      # built from that tree and has no business reading or rewriting it. That
      # is the `cd ~/other-repo && nix run /path/to/this-repo#fmt` case, which a
      # bare git-toplevel lookup happily reformatted.
      #
      # `$(<file)` is a bash redirection builtin, so the comparison forks no
      # process and needs nothing on PATH but git.
      rootPreamble = ''
        REPO_SRC=${lib.escapeShellArg self}
        REPO_ROOT="$REPO_SRC"
        devCheckout="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$devCheckout" ] && [ -f "$devCheckout/flake.nix" ] && [ "$(<"$devCheckout/flake.nix")" = "$(<"$REPO_SRC/flake.nix")" ]; then
          REPO_ROOT="$devCheckout"
        fi
        unset devCheckout
        export REPO_SRC REPO_ROOT
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
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
              ${ldPreamble pkgs}
              # Every verb runs FROM the repo root. Defaulting each path argument
              # to "$REPO_ROOT" (below) covers the no-argument case, but only
              # this cd covers the flag-only one: `dev-lint --fix` expands to a
              # non-empty "$@" with no path in it, and ruff would then fall back
              # to its own default of "." -- the caller's directory -- and
              # rewrite it. Consequence to know about: a relative path you pass
              # is relative to the repo root, not to your cwd, which is also what
              # makes it impossible for one to escape the repo.
              cd "$REPO_ROOT"
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

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

          # Some C extensions and node-gyp addons compile at -O0, where glibc's
          # _FORTIFY_SOURCE becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No venv creation, no
            # `npm install`, no `dotnet restore`, no `read`, no `exec $SHELL`.
            # Bootstrapping in the hook makes a cold `nix develop -c pytest`
            # start downloading before it runs anything, on EVERY invocation --
            # the exact failure an unattended agent cannot diagnose. That is what
            # `dev-setup` is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "curtain_robot dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. Add real
      # test derivations beside it. NEVER add a check that always passes: an
      # agent reads "all checks passed!" as a signal, and a fake check makes
      # `nix flake check` a liar.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done
              touch "$out"
            '';

        # A regression test for the defect this flake shipped with, and it does
        # fail against the old command texts -- it is not decoration. The build
        # sandbox is an ideal stand-in for "some unrelated directory": it is not
        # a git repo and it is not this repo, which is precisely the situation in
        # which `nix run /path/to/repo#<verb>` used to act on the caller.
        anchoring =
          pkgs.runCommand "anchoring-check"
            {
              nativeBuildInputs = lib.attrValues (wrappers pkgs);
            }
            ''
              printf 'import os,sys\nx=1\n' > decoy.py
              cp decoy.py decoy.py.orig

              # A mutating verb with nothing to write to must fail, not wander.
              if dev-fmt; then
                echo "dev-fmt succeeded outside a checkout: it wrote something" >&2
                exit 1
              fi
              cmp decoy.py decoy.py.orig || {
                echo "dev-fmt rewrote a file outside the repo" >&2
                exit 1
              }

              # ... and a read-only verb must inspect the repo, not the caller.
              # decoy.py is worth 3 ruff findings, so a lint that walked this
              # directory could not stay quiet about it. Both argument shapes are
              # exercised: no arguments at all (where the old text let ruff
              # default to ".") and flag-only (where a path default is not enough
              # on its own and the cd carries it).
              dev-lint > lint.log 2>&1 || true
              ! grep -q 'decoy\.py' lint.log || {
                echo "dev-lint inspected the caller's directory" >&2
                exit 1
              }

              # --show-files also pins down the positive half -- that it really
              # did look at this repo -- and stays true if the 23 findings are
              # ever cleaned up.
              dev-lint --show-files > files.txt
              grep -q '/test_utils\.py$' files.txt || {
                echo "dev-lint did not see this repo's files" >&2
                exit 1
              }
              ! grep -q 'decoy\.py' files.txt || {
                echo "dev-lint --show-files inspected the caller's directory" >&2
                exit 1
              }

              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff in 41 repos.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
