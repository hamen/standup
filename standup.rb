#!/usr/bin/env ruby

require 'date'
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
  return { config: {}, path: nil } unless path

  raw = File.read(path)
  config = YAML.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: true) || {}
  puts "Loaded config: #{path}" if verbose
  { config: config, path: path }
rescue Errno::ENOENT
  raise "Config file not found: #{explicit_path}"
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

def find_git_repos(root)
  puts "Scanning #{root} for Git repositories..."
  repos = Dir.glob(File.join(root, '*', '.git')).map { |dot_git| File.dirname(dot_git) }
  puts "Found #{repos.size} repositories."
  repos
end

def get_commits(repo_path, target_date)
  # Change directory to the repo
  Dir.chdir(repo_path) do
    # Get current git user name if not provided
    author = `git config user.name`.strip
    
    # Git log command for the target date
    date_str = target_date.to_s
    cmd = "git log --since=\"#{date_str} 00:00:00\" --until=\"#{date_str} 23:59:59\" --author=\"#{author}\" --pretty=format:\"%s\" 2>/dev/null"
    commits = `#{cmd}`.split("\n").reject(&:empty?)
    commits
  end
rescue => e
  puts "Error processing #{repo_path}: #{e.message}"
  []
end

def get_llm_context_entries(repo_path, target_date)
  llm_context_path = File.join(repo_path, 'llm-context.md')
  return { entries: [], modified: false } unless File.exist?(llm_context_path)
  
  entries = []
  date_str = target_date.strftime('%Y-%m-%d')
  
  # Check if file was modified on target date
  was_modified = false
  Dir.chdir(repo_path) do
    author = `git config user.name`.strip
    date_str_full = target_date.to_s
    cmd = "git log --since=\"#{date_str_full} 00:00:00\" --until=\"#{date_str_full} 23:59:59\" --author=\"#{author}\" --name-only --pretty=format: -- llm-context.md 2>/dev/null"
    was_modified = !`#{cmd}`.strip.empty?
  end
  
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

  repos = find_git_repos(projects_root)

  puts "\n--- Daily Summary for #{date_label} (#{target_date}) ---"
  
  any_activity = false
  repos.each do |repo|
    commits = get_commits(repo, target_date)
    llm_context = get_llm_context_entries(repo, target_date)
    
    # Skip if no commits and no llm-context entries
    next if commits.empty? && llm_context[:entries].empty? && !llm_context[:modified]
    
    any_activity = true
    repo_name = File.basename(repo)
    display_name = repo_display_name(repo_name, repo_name_mapping)
    puts "\n#{display_name}"
    
    # Show commits
    commits.each { |commit| puts "  - #{commit}" } unless commits.empty?
    
    # Show llm-context.md entries
    unless llm_context[:entries].empty?
      puts "  📝 llm-context.md entries:"
      llm_context[:entries].each { |entry| puts "    • #{entry}" }
    end
    
    # Show if file was modified but no date-stamped entries found
    if llm_context[:modified] && llm_context[:entries].empty?
      puts "  📝 llm-context.md was updated (check for new ADRs or changes)"
    end
  end
  
  puts "\nNo activity found for #{date_label.downcase}." unless any_activity
  puts "\n--- End of Summary ---\n"
end

