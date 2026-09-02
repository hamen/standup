#!/usr/bin/env ruby
# Regression test: run it with `ruby test_standup.rb`.
#
# The standup once reported "No activity" on a day with 83 commits, because it
# read only the checked-out branch, and the day's work lived on feature
# branches in other worktrees.

ENV['TZ'] = 'UTC' # the log window below has no offset, so git reads it as local time

require 'date'
require 'fileutils'
require 'shellwords'
require 'tmpdir'

SCRIPT = File.expand_path('standup.rb', __dir__)
YESTERDAY = Date.today - 1

def git(*args)
  system('git', *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
end

def commit(subject, date, file: 'file.txt', content: nil)
  stamp = "#{date} 12:00:00 +0000"
  File.write(file, content || "#{subject}\n")
  git('add', file)
  ENV['GIT_COMMITTER_DATE'] = stamp
  git('commit', '-m', subject, '--date', stamp)
ensure
  ENV.delete('GIT_COMMITTER_DATE')
end

def build_repo(path)
  FileUtils.mkdir_p(path)
  Dir.chdir(path) do
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'Test User')
    git('config', 'user.email', 'test@example.com')
    git('config', 'commit.gpgsign', 'false')
    commit('base commit', Date.today - 10)

    # Yesterday's work sits on a branch that is never merged into main, and
    # main stays checked out — the way a main checkout stays behind while the
    # work happens in a worktree. Nothing here is reachable from HEAD.
    git('checkout', '-q', '-b', 'feature')
    commit('the commit that must show up', YESTERDAY)

    # An llm-context.md that exists only on that branch.
    commit('add llm-context on the feature branch', YESTERDAY, file: 'llm-context.md',
           content: "#### #{YESTERDAY} - branch-only entry\n")
    git('checkout', '-q', 'main')

    # A second branch, carrying a merge whose own commit lands yesterday too.
    # Its subject is noise, and it must not reach the report.
    git('checkout', '-q', '-b', 'released')
    ENV['GIT_COMMITTER_DATE'] = "#{YESTERDAY} 13:00:00 +0000"
    git('merge', '--no-ff', '-q', '-m', 'Merge pull request #99 from feature', 'feature')
    ENV.delete('GIT_COMMITTER_DATE')
    git('checkout', '-q', 'main')

    # An uncommitted change, stashed yesterday. Its stash commits are not work.
    File.write('file.txt', "stashed edit\n")
    ENV['GIT_COMMITTER_DATE'] = "#{YESTERDAY} 14:00:00 +0000"
    git('stash', 'push', '-q', '-m', 'the stash that must not show up')
    ENV.delete('GIT_COMMITTER_DATE')
  end
end

def build_quiet_repo(path)
  FileUtils.mkdir_p(path)
  Dir.chdir(path) do
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'Test User')
    git('config', 'user.email', 'test@example.com')
    git('config', 'commit.gpgsign', 'false')
    commit('nothing happened here yesterday', Date.today - 10)

    # An llm-context.md in the checkout, with an entry stamped yesterday. The
    # file is old; only the entry is dated, and it must be listed by name.
    commit('add llm-context', Date.today - 10, file: 'llm-context.md',
           content: "#### #{YESTERDAY} - the entry that must be named\n")
  end
end

Dir.mktmpdir do |root|
  build_repo(File.join(root, 'demo-repo'))
  build_quiet_repo(File.join(root, 'quiet-repo'))
  output = `ruby #{Shellwords.escape(SCRIPT)} --projects-root #{Shellwords.escape(root)} 2>&1`

  failures = []
  failures << 'reported no activity' if output.include?('No activity found')
  failures << 'a date-stamped llm-context.md entry was not listed by name' unless
    output.include?('the entry that must be named')
  failures << 'commit on the unmerged-into checkout is missing' unless
    output.include?('the commit that must show up')
  failures << 'a merge commit was reported as work' if
    output.include?('Merge pull request')
  failures << 'a stash commit was reported as work' if
    output.match?(/index on |WIP on |untracked files on |must not show up/)
  failures << 'an llm-context.md that exists only on a branch went unreported' unless
    output.include?('llm-context.md was updated')

  # repo_name_mapping renames a repository. It must not decide which ones are
  # scanned: a repository missing from the map is still a repository worked in.
  config = File.join(root, 'standup.yml')
  File.write(config, "repo_name_mapping:\n  quiet-repo: \"#quiet\"\n")
  mapped = `ruby #{Shellwords.escape(SCRIPT)} --projects-root #{Shellwords.escape(root)} --config #{Shellwords.escape(config)} 2>&1`

  failures << 'a repository missing from repo_name_mapping was filtered out' unless
    mapped.include?('demo-repo')
  failures << 'repo_name_mapping did not rename the repository it names' unless
    mapped.include?('#quiet')

  if failures.empty?
    puts 'ok: the standup reports the day\'s commits, and only those'
  else
    warn "--- standup output ---\n#{output}--- with a config ---\n#{mapped}----------------------"
    failures.each { |f| warn "FAIL: #{f}" }
    exit 1
  end
end
