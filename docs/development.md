# Development

[Repository overview](../README.md) · [Design](design.md) · [Operations](operations.md)

This document describes how to change and verify the configuration. The [agent guide](../AGENTS.md) holds the rules for contributors.

## Validation

On a machine with Nix and flakes enabled:

```bash
nix fmt
nix flake check --no-build --all-systems
```

`--no-build` evaluates the complete `x86_64-linux` system without building it. Nix still builds the checks for the local platform. Nix only sees files that Git tracks, so `git add` new files first.

[CI](../.github/workflows/check.yml) runs on every push. It scans the Git history for secrets and builds every flake check:

- The system closure.
- The NixOS VM tests.
- `nginx -t` on the generated Nginx configuration.
- Formatting and lints.
- The DNS records.
- The encrypted secrets.
- The targets of Markdown links.

The test that boots the complete configuration runs in a second job at the same time. CI’s own build results go to the public Cachix cache `mkoppmann-apollo`, so later runs rebuild only what changed. Apollo does not use that cache.

The same workflow runs four times a day on `main`. It first updates the inputs of [updated-inputs.json](../modules/system/updated-inputs.json), as Apollo’s [automatic updates](operations.md#automatic-updates) do. It commits nothing. GitHub mails a failed scheduled run to whoever last changed the schedule. GitHub stops scheduling in a repository without activity for 60 days.

Checks built on macOS don’t prove the Linux build. The Linux build sandbox differs, for example in which CA certificates it offers. Linux builds and VM tests run in CI only.

## Comparing system builds

A refactor should leave the system unchanged. The system derivation embeds the Git revision, so pin the revision before you compare:

```bash
drv() {
  nix eval --raw --impure --expr "
    let
      f = builtins.getFlake \"$1\";
      s = f.nixosConfigurations.apollo.extendModules {
        modules = [ { system.configurationRevision = f.inputs.nixpkgs.lib.mkForce \"pinned\"; } ];
      };
    in s.config.system.build.toplevel.drvPath"
}
before=$(drv "git+file://$PWD?ref=main")
after=$(drv "git+file://$PWD")
[ "$before" = "$after" ] && echo unchanged
nix shell nixpkgs#nix-diff -c nix-diff --skip-already-compared "$before" "$after"
```

`nix-diff` names every derivation that differs. Expect differences when file names reach the store, such as a renamed file referenced with `${./file}`, or when reordered imports reorder merged lists.

## Tests

The [VM tests](../tests/) boot the real modules and check behavior, not that the configuration equals itself. nixpkgs’ own tests can’t be extended, because their test scripts don’t merge. The tests therefore build minimal nodes around Apollo’s modules. Sandboxes live in their own files for that reason: a test imports a service’s sandbox without the rest of the service. [tests/sops.nix](../tests/sops.nix) provides a test key and encrypted values for secrets.

[tests/apollo.nix](../tests/apollo.nix) boots the complete configuration instead: every module of [configuration.nix](../configuration.nix) on a fresh disk. The test fails in three cases:

- An activation step or a unit fails during boot.
- A virtual host doesn’t answer through Nginx.
- A response has no HSTS header, or more than one.

This catches what neither the build nor the tests of single services see, such as a service that doesn’t start with its real settings. The test runs beside the other tests, which check behavior that booting doesn’t exercise. The machine differs from Apollo in what a VM can’t have:

- `/persist` is a directory on the VM’s disk. There is no pool, so the boot unlocks nothing and doesn’t roll the root file system back. The remote unlock has its own test, described below.
- Every secret that the configuration declares gets a generated value. A new secret needs a line in the test only when its consumer expects a format, like WireGuard’s keys.
- A certificate authority built for the test signs the certificates, and the machine trusts it. No ACME order runs.
- The host names resolve to the machine itself, which has no other network. The photo server’s host therefore answers 502.
- No timer fires.
- The test creates what Apollo has and no module creates: Matrix Authentication Service’s secret files.

The state is new on every run. The test therefore also shows whether the services start on an empty `/persist`, but not whether they still start with Apollo’s data.

[tests/remote-unlock.nix](../tests/remote-unlock.nix) covers the boot that the complete configuration skips. A server with Apollo’s initrd settings, SSH settings and disk layout creates the encrypted pool on a second disk. The server then reboots with its root on that pool. A client connects like the operator does, with the declared host key pinned. The client enters the passphrase at the prompt, and the server boots and rolls its root back. The first boot has no pool yet, which shows that the system reports a failed rollback. The test also fails when the unlock key runs a command of its own or when the initrd accepts a classical key exchange. Two things differ from Apollo. The host key is a public test key from the Nix store. The address sits on the test network’s interface.

## Sandboxing services

- Start from the sandbox of a comparable nixpkgs module where one exists. Test the result in a VM test or on Apollo before you deploy.
- systemd merges list-valued options, so overriding an upstream setting such as `ProtectSystem` needs `lib.mkForce`.
- `SystemCallFilter = [ "@system-service" "~@privileged" ]` also removes `@chown` and `@setuid`. Services that change the owner of a socket, such as Gunicorn in Authentik, need `@chown` back. A blocked call kills the process with `SIGSYS`. A parent process may then only log the child’s wait status `159`.
- `MemoryDenyWriteExecute` breaks JIT compilers: the Erlang VM, and PHP unless `pcre.jit` is off.
- PHP-FPM’s master process runs as root and keeps the capabilities it needs to start its workers.
- `IPAddressAllow` on a unit overrides an `IPAddressDeny` of its slice: systemd combines the lists of the unit and all its slices, and allow wins. Changing `system.slice` needs `overrideStrategy = "asDropin"`, because NixOS doesn’t ship that unit itself. The test driver’s commands also run in `system.slice`.
- `PrivateNetwork` works for services that only listen on Unix sockets.

## Pitfalls

- A switch inside `nixos-upgrade.service` reloads that unit, so its pre-start and post-start steps can come from different generations.
- Git run as root in `/etc/nixos` leaves root-owned files. The next automatic update fails when `deploy` can’t write them.
- Authentik blueprints: policy bindings that target a flow stage binding need `!KeyOf`, not `!Find`. Blueprints must be real files inside the blueprint directory. Authentik rejects symlinks into other store paths.
- `ak shell` output passes through a terminal and can carry invisible prefixes. Extract values with `grep -o`.
- `pleroma_ctl` exits successfully when a database query fails. Check its output for `QUERY ERROR`.
- Elixir releases take `RELEASE_COOKIE` as the cookie itself, not as the path of a file.
- Every file in the Nix store dates from 1970. nixpkgs’ Nginx leaves out `Last-Modified` for store files, unless `etag` is off. Other servers, such as Authentik’s, send the header, and browsers then keep the files for a week or for years. Authentik’s server sends an ETag made of the date and the length, which only changes with the length. Hiding the date is therefore not enough: serve such files from Nginx. Sites served from the store use the `revalidate` snippet of [lib/nginx-headers.nix](../lib/nginx-headers.nix).
