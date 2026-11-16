# Agent guide

These rules are for coding agents that work on this repository. They apply to human contributors as well.

The repository is the complete configuration of Apollo, a single NixOS server, and a public showcase. The [README](README.md) explains the layout. [Design](docs/design.md) records goals, decisions and rejected alternatives. [Development](docs/development.md) describes validation and testing. [GitHub issues](https://github.com/mkoppmann/nixos-configuration/issues) track open work. Everything needed to continue the work lives here: don’t rely on earlier chat sessions.

## Hard rules

- Never access Apollo. Agents edit the repository. The operator reviews, pushes, deploys and runs commands on the server. Hand over commands instead.
- Never read, print or edit secret values, in `secrets/`, on the server or in command output. Declare secrets in Nix. The operator sets the values ([secrets](docs/secrets.md#editing-secrets)). Commands for the operator must not print unfiltered output that can contain secrets or tokens. Extract the needed fields with `grep -o` or `jq`.
- The repository and its issues are public. Don’t include secret values, references to agent tooling, or details of the operator’s other machines or network. Name them by their role, such as “the photo server”. Fix a weakness before you describe it. Until then, phrase issues and commits as improvements.
- Never build `path:.#apollo`: it copies untracked files into the world-readable Nix store.
- Never change `system.stateVersion`.
- Change application data only through the applications’ official tools, such as `nextcloud-occ`, `ak` or `pleroma_ctl`. Never edit database entries directly. Read-only queries for diagnosis are fine.

## Working together

- Challenge assumptions, including the operator’s. Explain the problem before you propose a solution. Recommend one option instead of a list of all options.
- Prefer the simplest design that works. Tools and abstractions need a concrete payoff on a single host.
- Read the issue before you start. Record new decisions in [design](docs/design.md) in the same branch as the change and keep issues current, or tell the operator what to update.

## Changes

- Work on a branch with a short, natural kebab-case name. The operator may have `main` checked out.
- Each service module owns everything of its service. Host concerns go in `modules/system/`, and services go in `modules/services/`. `configuration.nix` holds the single, explicit import list.
- Validate with `nix fmt` and `nix flake check --no-build --all-systems`. Nix ignores files that Git doesn’t track: `git add` new files first.
- Prove that a refactor leaves the system unchanged: [compare derivations](docs/development.md#comparing-system-builds).
- CI builds what a macOS machine can’t, including the VM tests. A check that passes locally can still fail on Linux.
- Update the docs in the same branch. Keep lists that go stale out of the README.

## Commits

- The message gives the reason for the change: the problem, the decision and what it rules out. The code and the docs show what changed.
- Keep the subject under 52 characters and wrap the body at 80. Keep messages lean and qualitative: no measured figures, no AI attribution trailers.
- Until the operator merges a branch, fold each fix into the commit it belongs to: `git commit --fixup COMMIT`, then `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash origin/main`.
- The operator merges with GitHub’s rebase and merge. Afterwards, check that `main`’s tree equals the branch and delete the local branch.

## Pull requests

- Assign every pull request to the operator.
- The description gives an overview of the change for a reader who has not read the commits. Don’t repeat the commit messages.
- Add tips for the review: where to start, what CI doesn’t cover, and what the deploy needs.

## Docs and comments

- Docs and comments describe the current state. What changed, and what was there before, belongs in the commit message.
- Leave out what the code or the text beside it already says.
- A comment states a fact that the code can’t show, such as the reason for a setting.

## Writing

These rules cover the docs, comments, issues, pull requests and commit messages. They follow the sentence rules of Simplified Technical English and leave its word list out.

- Start with the fact. Leave out sentences that announce, repeat or praise, such as “this change aims to” or a closing summary.
- Write one idea per sentence. Use at most 25 words, or 20 in an instruction. Split a longer sentence instead of joining its parts with a semicolon or a dash.
- Use the active voice and name the actor: “Nginx serves the files”, not “the files are served”.
- Put a condition before its command: “If the check fails, read the log.”
- Use the verb instead of its noun: “check the log”, not “perform a check of the log”.
- Use one plain verb instead of a phrasal verb: “start”, not “spin up”.
- Give each thing one name and keep that name. A second name reads as a second thing.
- Delete words that claim quality or importance, such as “robust”, “seamless”, “simply” or “crucial”. Give the reason instead.
- Keep a hedge that states real doubt, such as “may” in a diagnosis, and use it once. Never turn doubt into a fact, and never add a fact that the source doesn’t state.
- Use a list for three or more parallel items or steps, and prose for everything else. Don’t use bold for emphasis, and don’t use emoji.
- Write as a person who knows the system writes to another. Leave out the habits of generated text: groups of three for rhythm, “not only X, but Y”, a heading on a short text and filler such as “note that”.
- Leave code, commands, paths, identifiers and quoted output unchanged.
- Use the typographic apostrophe ’ in prose, comments and commit messages. Code and commands stay ASCII.

## Commands for the operator

- Apollo’s shell is Fish, so wrap multi-line scripts in `sudo bash`. In `/etc/nixos`, run Git only as `sudo -u deploy git …`.
- Deploy only after CI passed, as described in [operations](docs/operations.md#deployment). Apply network and SSH changes with `nixos-rebuild test` first, and keep a second session open.
