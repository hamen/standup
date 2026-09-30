#!/usr/bin/env ruby

require 'date'
require 'json'
require 'open3'
require 'yaml'
require 'optparse'

# Configuration
DEFAULT_ROOT_CANDIDATES = [
  File.join(Dir.home, 'code'),
  File.join(Dir.home, 'projects'),
].freeze

def load_config(explicit_path: nil, verbose: false)
  candidate_paths =
    if explicit_path
      [File.expand_path(explicit_path)]
    else
      [
        File.join(Dir.home, '.standup.yml'),
        File.join(Dir.pwd, 'standup.yml'),
      ]
    end

  path = candidate_paths.find { |p| File.file?(p) }

  # An explicitly named config that is not there is an error, not an empty
  # config. Falling back silently is what made a leak out of a typo: on
  # 2026-09-09 a config path was mangled before it reached here, this returned
  # {} rather than complaining, and the report ran with no exclude_repos and no
  # name mapping — every repository under the projects root, named by its
  # directory, in a message with publish buttons on it.
  #
  # Asking for a specific file and getting a silent default is never what the
  # caller wanted. Finding nothing when nothing was asked for still is: that
  # path below keeps working, and is what makes the tool usable with no config
  # at all.
  raise "Config file not found: #{explicit_path}" if path.nil? && explicit_path
  return { config: {}, path: nil } unless path

  raw = config_utf8(File.binread(path), path)
  config = YAML.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: true) || {}
  puts "Loaded config: #{path}" if verbose
  { config: config, path: path }
rescue Psych::SyntaxError => e
  raise "Invalid YAML in config file #{path}: #{e.message}"
end

def resolve_projects_root(cli_root:, config_root:, env_root:, verbose: false)
  root =
    cli_root ||
    config_root ||
    env_root ||
    DEFAULT_ROOT_CANDIDATES.find { |p| Dir.exist?(p) }

  raise "Could not determine projects root. Use --projects-root PATH or set STANDUP_PROJECTS_ROOT." unless root

  root = File.expand_path(root)
  puts "Using projects root: #{root}" if verbose
  root
end

# A repository with no mapping is published under a hashtag made from its
# directory name. The bare name used to go out as it was, and the formatter,
# told that every header is a hashtag, put a "#" in front of it: X ends a
# hashtag at the first "-", so "app-promo-reel" went out as a link to "#app".
# Lowercase ASCII letters and digits are the only shape every reader of the
# header agrees on — X, wip.co, and the publisher's own header matching.
def repo_display_name(repo_basename, repo_name_mapping)
  mapped = repo_name_mapping && repo_name_mapping[repo_basename]
  return mapped if mapped

  tag = repo_basename.downcase.gsub(/[^a-z0-9]/, '')
  tag.empty? ? repo_basename : "##{tag}"
end

# A header the publisher can turn into "name — link" on X.
SWAPPABLE_HEADER = /\A#([a-z0-9]+)\z/

GITHUB_REMOTE = %r{\A(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)
                   ([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?\z}x

# The public GitHub page of a repository, from its origin remote, or nil.
#
# Read with git config rather than git_capture: git_capture warns on stderr,
# and stderr is part of what the publisher reads as the report. A remote that
# is missing or elsewhere is a normal answer here, and says nothing.
def github_url(repo_path)
  out, _err, status = Open3.capture3('git', '-C', repo_path.to_s, 'config', '--get', 'remote.origin.url')
  return nil unless status.success?

  m = GITHUB_REMOTE.match(as_utf8(out).strip)
  m && "https://github.com/#{m[1]}/#{m[2]}"
rescue SystemCallError
  nil
end

# The GitHub link for each reported header the publisher can swap, as JSON.
#
# Only a header that names exactly one reported repository gets one: two
# repositories under one tag would publish a link to either. Nothing here may
# stop the report — the links are a cosmetic fallback for X, and a report
# without them is still the report — so every failure is silent, and the
# publisher treats a missing file as no links at all.
def write_links(path, reported)
  counts = reported.map { |r| r[:header] }.tally
  links = {}
  reported.each do |r|
    m = SWAPPABLE_HEADER.match(r[:header])
    next unless m && counts[r[:header]] == 1

    url = github_url(r[:path])
    links[m[1]] = { 'name' => r[:name], 'url' => url } if url
  end
  File.write(path, JSON.generate(links))
rescue StandardError
  nil
end

# Bytes from outside this process, read as UTF-8 whatever the environment says.
#
# Ruby tags external bytes with the locale's encoding. Under cron there is no
# LANG, so that encoding is US-ASCII, and the first accented character in a
# commit subject then raises "invalid byte sequence in US-ASCII" on the split
# that follows — the whole standup dies on an ordinary working day. Commit
# messages, configs and notes are UTF-8 by convention, so say so rather than
# letting the environment decide.
#
# Scrubbing is right for what this reads OUT of repositories: one stray byte in
# an old commit message should cost that character, not the day's report.
#
# It is exactly wrong for the config, which is why that has its own function
# below. A scrubbed byte inside an exclude_repos entry changes the name, the
# name then matches no repository, and the repository it was meant to hide is
# reported as usual — into a message with publish buttons on it. Silent repair
# is the wrong answer to a question about what must not be published.
def as_utf8(bytes)
  text = retag_utf8(bytes)
  text.valid_encoding? ? text : text.scrub('?')
end

# The retag itself, shared so the two policies above and below cannot drift
# apart on what "read this as UTF-8" means.
def retag_utf8(bytes)
  bytes.dup.force_encoding(Encoding::UTF_8)
end

# The config, which must be exactly what was written or nothing at all.
def config_utf8(bytes, path)
  text = retag_utf8(bytes)
  return text if text.valid_encoding?

  raise "Config file #{path} is not valid UTF-8. Every name in it decides what " \
        "is published, so it is read exactly or not at all."
end

# Run git in a repository and return its stdout, or "" if it failed.
#
# Every argument goes to git as one argv entry, so nothing here reaches a
# shell. That matters because one of the arguments is `git config user.name`,
# and a name holding $(...) or a backtick used to run as a command.
def git_capture(repo_path, *args)
  out, err, status = Open3.capture3('git', '-C', repo_path.to_s, *args)
  out = as_utf8(out)
  return out if status.success?

  err = as_utf8(err)

  # A missing config key exits non-zero and says nothing, which is a normal
  # answer. Anything git does complain about is worth seeing, because the
  # alternative is a broken repository that quietly reports an empty day.
  warn "git #{args.first} failed in #{repo_path}: #{err.lines.first&.strip}" unless err.strip.empty?
  ''
rescue SystemCallError => e
  warn "Error running git in #{repo_path}: #{e.message}"
  ''
end

# The repository names to keep out of the report.
#
# Written as a YAML scalar rather than a list, this would be a String, and
# String#include? matches a substring: `exclude_repos: api` would silently drop
# every repository whose name contains "api". A config that hides the wrong
# work is worse than one that refuses to run, so this refuses.
def exclude_list(value)
  return [] if value.nil?

  unless value.is_a?(Array) && value.all? { |name| name.is_a?(String) && !name.strip.empty? }
    abort 'exclude_repos must be a list of repository directory names'
  end

  value
end

def find_git_repos(root, verbose: false)
  puts "Scanning #{root} for Git repositories..." if verbose
  # force_encoding, not scrub: the bytes must reach git untouched, and only the
  # tag needs to be consistent with the config's.
  #
  # This is insurance rather than a fix for something observed. CRuby derives
  # the filesystem encoding from the locale on Linux, so under cron it should be
  # US-ASCII and a directory name with diacritics should come back invalid — at
  # which point a repo_name_mapping lookup misses and, worse, an exclude_repos
  # entry stops matching and publishes what it was written to hide. Measured on
  # two builds here (3.3.8 and 3.4.10), Encoding.find('filesystem') does report
  # US-ASCII and the names still come back UTF-8 and valid, because Ruby falls
  # back to UTF-8 for non-ASCII filesystem bytes. So this line changes nothing
  # today. It stays because the cost is one tag and the failure it guards is a
  # private repository published under its own name.
  repos = Dir.glob(File.join(root, '*', '.git'))
              .map { |dot_git| File.dirname(dot_git).dup.force_encoding(Encoding::UTF_8) }
  puts "Found #{repos.size} repositories." if verbose
  repos
end

# The refs and the window one day's work is looked for in.
#
# --branches --remotes, because the day's work often sits on a feature branch,
# or in another worktree, and the checkout this runs in stays behind. Not
# --all: that also walks refs/stash, and one stash made that day puts
# "index on main: ..." in the report.
# --no-merges, because "Merge pull request #12" is not a standup line.
# --fixed-strings, because --author is otherwise a regular expression, and a
# name holding "(" is then either an error or a wrong match.
#
# Returns nil when the repository has no user.name configured. An empty
# --author= matches every commit, so such a repository would report everyone
# else's day as yours.
def day_log_args(repo_path, target_date)
  author = git_capture(repo_path, 'config', 'user.name').strip
  return nil if author.empty?

  date_str = target_date.to_s
  ['log', '--branches', '--remotes', '--no-merges', '--fixed-strings',
   "--since=#{date_str} 00:00:00", "--until=#{date_str} 23:59:59",
   "--author=#{author}"]
end

def get_commits(repo_path, target_date)
  args = day_log_args(repo_path, target_date)
  return [] unless args

  git_capture(repo_path, *(args + ['--pretty=format:%s'])).split("\n").reject(&:empty?)
end

def get_llm_context_entries(repo_path, target_date)
  entries = []
  date_str = target_date.strftime('%Y-%m-%d')

  # Was the file touched on the target date, on any branch? This runs before
  # the checkout is looked at, so a file that only exists on a feature branch
  # still counts as work.
  args = day_log_args(repo_path, target_date)
  was_modified =
    if args
      log = git_capture(repo_path, *(args + ['--name-only', '--pretty=format:', '--', 'llm-context.md']))
      !log.strip.empty?
    else
      false
    end

  # The entries themselves come from the checked-out copy, so a branch-only
  # entry reports as "llm-context.md was updated" rather than by name. That
  # over-reports; the alternative is to say nothing about a day's work.
  llm_context_path = File.join(repo_path, 'llm-context.md')
  return { entries: [], modified: was_modified } unless File.exist?(llm_context_path)

  # Read the file and look for date-stamped entries
  content = as_utf8(File.binread(llm_context_path))
  
  # Look for date-stamped entries (#### YYYY-MM-DD – Title)
  # Handle both regular hyphens and en-dashes in dates
  date_pattern = date_str.gsub('-', '[-‑]') # Match both - and ‑
  
  content.each_line do |line|
    # Match date-stamped entries: #### 2025-12-21 – Title or #### 2025‑12‑21 – Title
    if line.match?(/^####\s+#{date_pattern}[^\n]*$/i)
      # Remove the #### prefix and keep the rest
      entry = line.strip.gsub(/^####\s+/, '')
      entries << entry unless entry.empty?
    end
  end
  
  { entries: entries.uniq, modified: was_modified }
rescue => e
  { entries: [], modified: false }
end

def show_help
  puts <<~HELP
    Daily Standup Summary Script
    
    Usage: #{File.basename(__FILE__)} [OPTIONS]
    
    Options:
      --today               Show summary for today's work (default: yesterday)
      --config PATH         Load config from PATH (YAML)
      --projects-root PATH  Root folder containing your git projects
      --verbose             Print extra debug output
      --links-out PATH      Write the GitHub link of each reported project to PATH (JSON)
      --help                Show this help message
    
    Examples:
      #{File.basename(__FILE__)}              # Show yesterday's summary
      #{File.basename(__FILE__)} --today       # Show today's summary
      #{File.basename(__FILE__)} --projects-root ~/code
      #{File.basename(__FILE__)} --config ~/.standup.yml
      #{File.basename(__FILE__)} --help        # Show this help
    
    Config resolution order:
      1) CLI flags
      2) ~/.standup.yml then ./standup.yml
      3) Environment variables
      4) Defaults (~/code, ~/projects)

    Supported config keys (YAML):
      projects_root: /path/to/projects
      repo_name_mapping:
        repo_dir_name: "#display_name"
      exclude_repos:
        - repo_dir_name

    Every repository under the projects root is reported unless exclude_repos
    names it. Use that for the ones a published standup should not mention.

    The script scans all Git repositories under the projects root and:
    - Lists all commits from the target date
    - Shows date-stamped entries from llm-context.md files
    - Indicates when llm-context.md files were updated
  HELP
end

if __FILE__ == $0
  options = {
    today: false,
    config_path: nil,
    projects_root: nil,
    verbose: false,
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{File.basename(__FILE__)} [OPTIONS]"
    opts.on('--today', 'Show summary for today (default: yesterday)') { options[:today] = true }
    opts.on('--config PATH', 'Load config from PATH (YAML)') { |v| options[:config_path] = v }
    opts.on('--projects-root PATH', 'Root folder containing your git projects') { |v| options[:projects_root] = v }
    opts.on('--verbose', 'Print extra debug output') { options[:verbose] = true }
    opts.on('--links-out PATH', 'Write the GitHub link of each reported project to PATH (JSON)') { |v| options[:links_out] = v }
    opts.on('--help', 'Show help') do
      show_help
      exit 0
    end
  end

  begin
    parser.parse!(ARGV)
  rescue OptionParser::InvalidOption => e
    warn e.message
    show_help
    exit 1
  end

  cfg = load_config(explicit_path: options[:config_path], verbose: options[:verbose])[:config]
  projects_root = resolve_projects_root(
    cli_root: options[:projects_root],
    config_root: cfg['projects_root'],
    env_root: ENV['STANDUP_PROJECTS_ROOT'],
    verbose: options[:verbose],
  )

  repo_name_mapping = cfg['repo_name_mapping'] || {}

  # Determine target date
  target_date = options[:today] ? Date.today : Date.today - 1
  date_label = options[:today] ? "Today" : "Yesterday"

  # Repositories a published standup must not name. A list of what to hide,
  # not of what to show, so a new repository appears on its own. Checked before
  # anything is scanned, so a bad config fails at once.
  excluded = exclude_list(cfg['exclude_repos'])

  repos = find_git_repos(projects_root, verbose: options[:verbose])

  # An entry that matches nothing is usually a typo, and a typo here does not
  # look like a mistake: the repository it was meant to hide is simply reported
  # as usual. Say so, because that is the direction that leaks.
  names = repos.map { |repo| File.basename(repo) }
  (excluded - names).each do |name|
    warn "exclude_repos names #{name}, which is not a repository in #{projects_root}"
  end

  repos = repos.reject { |repo| excluded.include?(File.basename(repo)) }

  any_activity = false
  reported = []

  repos.each do |repo|
    commits = get_commits(repo, target_date)
    llm_context = get_llm_context_entries(repo, target_date)

    next if commits.empty? && llm_context[:entries].empty? && !llm_context[:modified]

    any_activity = true
    repo_name = File.basename(repo)
    display_name = repo_display_name(repo_name, repo_name_mapping)
    reported << { path: repo, name: repo_name, header: display_name }

    puts "#{display_name}\n"

    commits.each { |commit| puts "• #{commit}" } unless commits.empty?

    unless llm_context[:entries].empty?
      llm_context[:entries].each { |entry| puts "• 📝 #{entry}" }
    end

    if llm_context[:modified] && llm_context[:entries].empty?
      puts "• 📝 llm-context.md was updated"
    end

    puts
  end

  puts "No activity found for #{date_label.downcase}." unless any_activity
  write_links(options[:links_out], reported) if options[:links_out]
end

