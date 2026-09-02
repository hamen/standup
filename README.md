<p align="center">
  <img src=".github/banner.svg" alt="standup — yesterday's commits, every repository, every branch" width="880">
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/licence-MIT-f5c518"></a>
  <img alt="Ruby 3.x" src="https://img.shields.io/badge/ruby-3.x-8fb7a0">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-9aa7b8">
</p>

A single Ruby file that reads the Git repositories sitting in your projects
directory and prints what you actually shipped yesterday, grouped by project.

It looks one level down — `~/code/my-app/.git`, not `~/code/work/my-app/.git` —
so repositories filed inside a subdirectory are not picked up.

```console
$ standup
#weathercast
• Retry the forecast fetch once before falling back to cache
• Drop the hourly chart below 400px, it was unreadable

#ledgerly
• Reconcile split transactions against the imported statement
• 📝 2026-09-01 – Chose SQLite over Postgres for the desktop build
```

No dependencies, no daemon, no account. Ruby and `git`.

## Why it is not `git log`

Because `git log` reads the branch your checkout happens to be sitting on, and
that is usually not where the day's work is.

If you use worktrees, or feature branches, or you merge through pull requests
and rarely pull `main` back down, then a plain `git log` in each repository
reports a fraction of your day — silently, which is the worst part. On the day
this was found, the tool reported *"no commits"* for a day with **83 commits
across twelve repositories**.

`standup` reads `--branches --remotes` instead, so the work counts wherever its
branch lives. It also:

- skips merge commits, because *"Merge pull request #51"* is not a standup line
- skips the stash, which `--all` would otherwise walk into
- matches your author name literally, so a name holding `[` or `(` still works
- leaves out the commits of a repository that has no `user.name`, since an empty
  author filter matches **everyone's** commits. A dated `llm-context.md` entry
  in such a repository is still reported: it carries no author to filter on.

## Install

```bash
git clone https://github.com/hamen/standup.git
cd standup
chmod +x standup.rb
./standup.rb --help
```

Put it on your `PATH` if you want it everywhere:

```bash
ln -s "$PWD/standup.rb" ~/.local/bin/standup
```

## Usage

```bash
standup                        # yesterday (the default)
standup --today                # today
standup --projects-root ~/work # somewhere other than the configured root
standup --config ~/.standup.yml
standup --verbose              # say where it is looking, and how much it found
standup --help
```

## Configuration

Configuration is optional. With no config, `standup` looks in `~/code`, then
`~/projects`.

It reads the first of these that exists:

1. `--config PATH`
2. `~/.standup.yml`
3. `./standup.yml`
4. `STANDUP_PROJECTS_ROOT` in the environment
5. the defaults above

```yaml
projects_root: /home/you/code

# Directory name -> the name the report prints. Hashtags are the common case.
repo_name_mapping:
  habit-tracker: "#habittracker"
  ebook-finder: "#ebookfinder"
  daily-journal: "#dailyjournal"

# Repositories to keep out of the report entirely.
exclude_repos:
  - some-client-work
  - unannounced-side-project
```

### `repo_name_mapping`

Renames a repository in the output. That is *all* it does — it never decides
which repositories are scanned.

### `exclude_repos`

Names the repositories to hide. Deliberately a list of what to **hide** rather
than what to show: a repository you create next month appears on its own, and
hiding one stays a decision instead of becoming something you forget.

It matches the directory name, not the display name, so renaming a project
cannot quietly un-hide it. An entry that matches no repository is a warning on
stderr, because that typo does not look like a mistake — the repository it was
meant to hide is simply reported as usual.

## Publishing the report

A hashtag in a [wip.co](https://wip.co) todo attaches it to that project, which
is exactly the shape `repo_name_mapping` produces. Give every repository you
publish an entry in the map: one without an entry prints its bare directory
name, which attaches to nothing and puts a private-looking name in a public
post.

Keep private work out with `exclude_repos` before you publish anywhere. A
repository name is a small thing to leak and an awkward one to take back.

A daily cron that pipes the output somewhere — Telegram, an API, your notes —
is a few lines of shell around `standup`; the tool itself stays a reader.

## `llm-context.md`

If a repository contains an `llm-context.md`, `standup` also reports the
date-stamped entries in it:

```text
#### 2026-09-01 – Decided to drop the queue and call it inline
#### 2026‑09‑01 – En dashes in the date work too
```

A file changed on the target date but carrying no entry for it reports as
`llm-context.md was updated`. That check reads every branch as well, so an entry
written on a feature branch still counts.

## Tests

```bash
ruby test_standup.rb
```

One file, no framework. It builds throwaway repositories for the situations
that actually bit — a commit on an unmerged branch, a merge, a stash, a hostile
`user.name`, a repository with no name at all, a broken ref — and asserts the
report says the right thing about each.

## Licence

MIT — see [`LICENSE`](LICENSE).
