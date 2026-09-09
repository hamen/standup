#!/usr/bin/env ruby

require 'date'
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

  raw = File.read(path)
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

def repo_display_name(repo_basename, repo_name_mapping)
  (repo_name_mapping && repo_name_mapping[repo_basename]) || repo_basename
end

# Run git in a repository and return its stdout, or "" if it failed.
#
# Every argument goes to git as one argv entry, so nothing here reaches a
# shell. That matters because one of the arguments is `git config user.name`,
# and a name holding $(...) or a backtick used to run as a command.
def git_capture(repo_path, *args)
  out, err, status = Open3.capture3('git', '-C', repo_path.to_s, *args)
  return out if status.success?

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
  repos = Dir.glob(File.join(root, '*', '.git')).map { |dot_git| File.dirname(dot_git) }
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
  content = File.read(llm_context_path)
  
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

  repos.each do |repo|
    commits = get_commits(repo, target_date)
    llm_context = get_llm_context_entries(repo, target_date)

    next if commits.empty? && llm_context[:entries].empty? && !llm_context[:modified]

    any_activity = true
    repo_name = File.basename(repo)
    display_name = repo_display_name(repo_name, repo_name_mapping)

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
end

