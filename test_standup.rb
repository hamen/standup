#!/usr/bin/env ruby
# Regression test: run it with `ruby test_standup.rb`.
#
# The standup once reported "No activity" on a day with 83 commits, because it
# read only the checked-out branch, and the day's work lived on feature
# branches in other worktrees.

require 'date'
require 'fileutils'
require 'tmpdir'

SCRIPT = File.expand_path('standup.rb', __dir__)

def git(*args)
  system('git', *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
end

def commit(subject, date)
  stamp = "#{date} 12:00:00 +0000"
  File.write('file.txt', subject)
  git('add', 'file.txt')
  git('-c', 'user.name=Test User', '-c', 'user.email=test@example.com',
      '-c', "commit.gpgsign=false", 'commit', '-m', subject,
      '--date', stamp)
ensure
  ENV.delete('GIT_COMMITTER_DATE')
end

Dir.mktmpdir do |root|
  yesterday = Date.today - 1
  repo = File.join(root, 'demo-repo')
  FileUtils.mkdir_p(repo)

  Dir.chdir(repo) do
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'Test User')
    git('config', 'user.email', 'test@example.com')

    ENV['GIT_COMMITTER_DATE'] = "#{Date.today - 10} 12:00:00 +0000"
    commit('base commit', Date.today - 10)

    # Yesterday's work: on a feature branch, then merged. main is left behind,
    # the way a main checkout is left behind when the work happens elsewhere.
    git('checkout', '-q', '-b', 'feature')
    ENV['GIT_COMMITTER_DATE'] = "#{yesterday} 12:00:00 +0000"
    commit('the commit that must show up', yesterday)
    git('checkout', '-q', 'main')
  end

  ENV.delete('GIT_COMMITTER_DATE')
  output = `ruby #{SCRIPT} --projects-root #{root} 2>&1`

  failures = []
  failures << "commit on the unchecked-out branch is missing:\n#{output}" unless
    output.include?('the commit that must show up')
  failures << "repo with no config entry was filtered out:\n#{output}" unless
    output.include?('demo-repo')
  failures << "reported no activity:\n#{output}" if output.include?('No activity found')

  if failures.empty?
    puts 'ok: standup sees commits that are not on the checked-out branch'
  else
    failures.each { |f| warn "FAIL: #{f}" }
    exit 1
  end
end
