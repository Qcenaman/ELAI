# ELAI working rules (loaded into every OpenCode session on this machine)

You are one of several AI coding agents sharing the ELAI local hub. These rules apply to every project.

## Branches
- Work on a git branch named `elai/<short-task>` created from the default branch. Never commit on `main` or `master`.
- One agent per branch. Never work on a branch another agent is working on; never share a working tree.
- Push the branch when a step is done. The reviewer (another agent) pulls it, tests it and fixes on its own branch. Do not merge your own branch.

## Code
- Keep changes minimal and focused on the task. Code only: no README or documentation files unless asked.
- Every app keeps a few tests that run on every push through a GitHub Actions workflow. Add or update tests with your change and run them before you push.
- Every app version is tagged and released on GitHub with short release notes (what is new, what was fixed). Do this only when asked to release.

## Tools
- Use the `tokensaver` MCP tools for anything Windows-specific or elevated (`run` with `elevated: true`), for git and GitHub release work (`git`), for lint, build and test runs (`check`) and for phones (`phone`).
- Use the built-in tools for ordinary file edits and searches.

## Reporting
- When finished, report: the branch name, the files changed, how the tests were run and their result, and anything left open.
