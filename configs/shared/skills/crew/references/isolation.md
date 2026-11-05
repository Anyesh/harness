# Build and test isolation

Read when writing `brief.md` or `check` for a repo whose builds would share an output dir, or whose tests or binaries could reach a live service, the user's data or the machine's state. Each repo writes its own wrapper, because tool homes and build tools differ per stack.

## Build output

- Give each worktree its own build output dir and the merge gate (`check`) one more, never shared. Build tools key incremental state on paths and mtimes; cargo names path crates the same in every worktree, so one shared `CARGO_TARGET_DIR` runs tests against another branch's build. End each worktree's dir in the item id or `w-<id>` and write it to `items/<id>/build-dir`, because `crew-clean-build` deletes only such a dir, at landing.
- Keep these dirs under one parent, list it in `watch-paths`, and build with smaller debug info (for cargo, `CARGO_PROFILE_DEV_DEBUG=line-tables-only`) so they all fit on the disk.
- To cap parallel builds, write the slot count to `$crew/light-slots` and run them through `crew-light <command...>` (`SKILL.md`'s Heavy slot section) instead of hand-rolled `flock` slots or one exclusive lock that serializes every worker.

## Isolation wrapper

Tests and `check` run the product through a wrapper that:

- points `HOME` and `XDG_RUNTIME_DIR` at fresh temp dirs and unsets `DBUS_SESSION_BUS_ADDRESS`, so the code cannot read or write the user's config, data, keyring or session services. On macOS app data sits under `~/Library`, which the temp `HOME` hides as well.
- keeps tool homes such as `CARGO_HOME` and `RUSTUP_HOME` on the real ones, set before `HOME` changes, so toolchains and caches still resolve.
- puts a stub dir first on `PATH` whose `systemctl`, `launchctl`, `loginctl`, `sudo`, `ssh` and `scp` print what they were asked and exit 1.
- keeps tests off the live service's API port: point the code's endpoint setting at an unused port, or fail the run when something answers on the live one.

```bash
#!/usr/bin/env bash
set -euo pipefail
export CARGO_HOME=${CARGO_HOME:-$HOME/.cargo} RUSTUP_HOME=${RUSTUP_HOME:-$HOME/.rustup}
iso=$(mktemp -d)
trap 'rm -rf "$iso"' EXIT
mkdir -p "$iso/home" "$iso/run" "$iso/bin"
chmod 700 "$iso/run"
for c in systemctl launchctl loginctl sudo ssh scp; do
  printf '#!/bin/sh\necho "isolated: %s $*" >&2\nexit 1\n' "$c" >"$iso/bin/$c"
  chmod +x "$iso/bin/$c"
done
unset DBUS_SESSION_BUS_ADDRESS
HOME=$iso/home XDG_RUNTIME_DIR=$iso/run PATH=$iso/bin:$PATH "$@"
```
