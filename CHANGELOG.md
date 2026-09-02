# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-09-02

First tagged release. `standup` had been working for months, and reporting a
fraction of the truth for most of them. This release is the day that was found
and fixed.

### Fixed

- **The report only saw the checked-out branch.** `git log` ran with no ref
  scope, so it read whichever branch each repository happened to be sitting on.
  Work done in a worktree, or on a feature branch, or merged through a pull
  request without pulling `main` back down, was invisible. The failure was
  silent: a day with 83 commits across twelve repositories reported *"no
  commits"*. It now reads `--branches --remotes`, so the day counts wherever its
  branch lives.
- **`repo_name_mapping` doubled as an allowlist.** A repository missing from the
  map was dropped before the scan, so six active repositories were invisible
  because nobody had remembered to add them. The map now only renames.
- **`git config user.name` was interpolated into a shell string.** A repository
  configured with a name holding `$(...)` or a backtick executed it. Every git
  call now passes its arguments as `argv` through `Open3`, and nothing reaches a
  shell.
- **`--author` was read as a regular expression.** A name holding `[` matched a
  character class and found nothing. Matching is literal now.
- **A repository with no `user.name` reported everyone else's work as yours.**
  An empty `--author=` is not a narrow filter; it matches every commit. The
  commits of such a repository, and the `llm-context.md` change detection that
  uses the same filter, are now left out. Dated `llm-context.md` entries are
  still reported from the checkout, since they carry no author to filter on.
- **A failing `git` became a quiet empty day.** Errors were discarded. A git
  that has something to say now says it on stderr.

### Added

- **`exclude_repos`** — the repositories to keep out of the report, for when it
  is published somewhere public. A list of what to hide rather than what to
  show, so a repository created next month appears on its own. It matches the
  directory name rather than the display name, refuses anything that is not a
  list of names, and warns when an entry matches nothing, because that typo
  otherwise looks like success while the repository stays visible.
- **`--verbose`** — the repository scan lines, which used to print
  unconditionally and land in the report.
- **`test_standup.rb`** — a regression suite with no framework. It builds
  throwaway repositories for each situation that actually bit, and every
  assertion was checked against the mutation it exists to catch.

### Changed

- Merge commits are excluded. *"Merge pull request #51"* is not a standup line.
- The stash is excluded. `--all` walks `refs/stash`, so a stash made that day
  arrived as `index on main: …` dressed up as work.
- Output is bullets and blank lines between projects, rather than banners and
  indentation, so it reads on a phone and pastes into a post.
- `llm-context.md` history is read across every branch, so a file that exists
  only on a feature branch still counts as work.

[1.0.0]: https://github.com/hamen/standup/releases/tag/v1.0.0
