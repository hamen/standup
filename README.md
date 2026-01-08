# standup

A small Ruby CLI that scans your local Git repos and prints a **daily standup summary** for **yesterday** (default) or **today**.

It aggregates:
- Your Git commit subjects for the day
- Date-stamped entries in each repo’s `llm-context.md` (if present)
- A note if `llm-context.md` was modified that day (useful for ADR updates)

## Requirements

- Ruby 3.x (works on most Linux/macOS environments)
- `git` available in `PATH`

## Install

Clone the repository and run the script directly:

```bash
git clone <your-repo-url>
cd standup
ruby standup.rb --help
```

Optional:

```bash
chmod +x standup.rb
./standup.rb
```

## Usage

```bash
# Yesterday (default)
./standup.rb

# Today
./standup.rb --today

# Help
./standup.rb --help
```

## Configuration

Configuration is **optional**. If you don’t configure anything, the script will try:
1. `~/code`
2. `~/projects`

### Config file locations

The script loads config in this order:
1. `--config PATH`
2. `~/.standup.yml`
3. `./standup.yml`
4. `STANDUP_PROJECTS_ROOT` environment variable
5. defaults (`~/code`, `~/projects`)

### Example config

Copy the example:

```bash
cp standup.yml.example standup.yml
```

`standup.yml`:

```yaml
projects_root: /home/youruser/code

repo_name_mapping:
  pushup-tracker: "#pushup-tracker"
  kindle-gratis-compose: "#kindlegratis"
  three-things-a-day: "#3thingsaday"
```

**Note on `repo_name_mapping`**: This maps your local repository directory names to display names (often hashtags). This is particularly useful if you use project hashtags on communities like [wip.co](https://wip.co), where the hashtag name (e.g., `#3thingsaday`) matches your project name on that platform. The mapping allows your standup output to use the same hashtag format you use in your community updates.

### CLI overrides

```bash
./standup.rb --projects-root ~/code
./standup.rb --config ~/.standup.yml
./standup.rb --verbose
```

## Notes on `llm-context.md`

If a repo contains `llm-context.md`, the script looks for date-stamped entries like:

```text
#### 2025-12-21 – Something you did
#### 2025‑12‑21 – Also supported (en-dash in date)
```

## License

MIT — see `LICENSE`.


