# Agent guide

Rules for coding agents working on this repository; they apply to human contributors as well.

The repository is the complete configuration of Apollo, a single NixOS server, and a public showcase. The [README](README.md) explains the layout, [design](docs/design.md) records goals, decisions and rejected alternatives, and [development](docs/development.md) describes validation and testing. Open work is tracked in [GitHub issues](https://github.com/mkoppmann/nixos-configuration/issues). Everything needed to continue the work lives here: don’t rely on earlier chat sessions.

## Hard rules

- Never access Apollo. Agents edit the repository; the operator reviews, pushes, deploys and runs commands on the server. Hand over commands instead.
- Never read, print or edit secret values, in `secrets/`, on the server or in command output. Declare secrets in Nix; the operator sets the values ([secrets](docs/secrets.md#editing-secrets)). Commands for the operator must not print unfiltered output that can contain secrets or tokens: extract the needed fields with `grep -o` or `jq`.
- The repository and its issues are public: no secret values, no references to agent tooling, and no details of the operator’s other machines or network; name them by their role, such as “the photo server”. Fix weaknesses before describing them; until then, phrase issues and commits as improvements.
- Never build `path:.#apollo`: it copies untracked files into the world-readable Nix store.
- Never change `system.stateVersion`.
- Change application data only through the applications’ official tools, such as `nextcloud-occ`, `ak` or `pleroma_ctl`, never by editing database entries directly. Read-only queries for diagnosis are fine.

## Working together

- Challenge assumptions, including the operator’s. Explain the problem before proposing a solution, and recommend one option rather than listing all of them.
- Prefer the simplest design that works. Tools and abstractions need a concrete payoff on a single host.
- Read the issue before starting. Record new decisions in [design](docs/design.md) in the same branch as the change, and keep issues current, or tell the operator what to update.

## Changes

- Work on a branch with a short, natural kebab-case name; the operator may have `main` checked out.
- Each service module owns everything of its service. Host concerns go in `modules/system/`, services in `modules/services/`; `configuration.nix` holds the single, explicit import list.
- Validate with `nix fmt` and `nix flake check --no-build --all-systems`. Nix ignores files that Git doesn’t track: `git add` new files first.
- Prove that refactors leave the system unchanged by [comparing derivations](docs/development.md#comparing-system-builds).
- CI builds what a macOS machine can’t, including the VM tests. A check that passes locally can still fail on Linux.
- Update the docs in the same branch; they describe the current state. Keep lists that go stale out of the README.

## Commits

- Subject under 52 characters, body wrapped at 80. Keep messages lean and qualitative: no measured figures, no AI attribution trailers.
- Until a branch is merged, fold fixes into the commit they belong to: `git commit --fixup COMMIT`, then `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash origin/main`.
- The operator merges with GitHub’s rebase and merge. Afterwards, check that `main`’s tree equals the branch and delete the local branch.
- Comments only state non-obvious facts about the current state; reasons belong in the commit message.
- Use the typographic apostrophe ’ in prose, comments and commit messages; code and commands stay ASCII.

## Commands for the operator

- Apollo’s shell is Fish; wrap multi-line scripts in `sudo bash`. In `/etc/nixos`, run Git only as `sudo -u deploy git …`.
- Deploy only after CI passed, as described in [operations](docs/operations.md#deployment). Apply network and SSH changes with `nixos-rebuild test` first, with a second session open.
