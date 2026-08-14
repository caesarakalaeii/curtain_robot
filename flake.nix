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
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument 'self'".
    { nixpkgs, ... }:
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
      # it runs in the caller's current directory so an agent can test
      # uncommitted edits. Rules for writing one:
      #   * always end with a quoted "$@" -- unquoted $@ fails the build (SC2068)
      #   * $REPO_ROOT is pre-set to the git top level; use it for anything
      #     stateful ("$REPO_ROOT/.venv"), never a bare relative path
      #   * pass the batch/non-interactive flag to anything that could prompt:
      #     there is no tty, so a prompt hangs until the agent's timeout
      #   * say "(network)" in the description of anything that needs it
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
          description = "ruff check (exits 1: 23 pre-existing findings in tree)";
          text = ''ruff check "$@"'';
        };
        fmt = {
          description = "ruff format (rewrites files)";
          text = ''ruff format "$@"'';
        };
        run = {
          # NEEDS HARDWARE, and this could not be validated when the flake was
          # written because no board was attached. What was verified is that
          # mpremote is on PATH and this text is shellcheck-clean; the serial
          # handshake is the untested part.
          #
          # test.py and test_utils.py are deliberately not copied -- the former is
          # an abandoned scratch script, the latter is host-only.
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

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $REPO_ROOT. `nix run` and `nix develop` both start in
      # whatever directory they were invoked from, so a bare `.venv` silently
      # forks a second environment as soon as an agent works from a subdirectory.
      # Note we do NOT cd there: commands act on the caller's cwd on purpose.
      rootPreamble = ''
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        export REPO_ROOT
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
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff in 41 repos.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
