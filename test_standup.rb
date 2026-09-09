#!/usr/bin/env ruby
# Regression test: run it with `ruby test_standup.rb`.
#
# The standup once reported "No activity" on a day with 83 commits, because it
# read only the checked-out branch, and the day's work lived on feature
# branches in other worktrees.

ENV['TZ'] = 'UTC' # the log window below has no offset, so git reads it as local time

require 'date'
require 'fileutils'
require 'open3'
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

    # A subject that is not ASCII, because most of them are not. This is what
    # the no-locale case below reads: with no LANG, Ruby tags git's bytes
    # US-ASCII and raises on the first character like these.
    commit('seo(ro): Somnoroase păsărele, and a bedtime routine', YESTERDAY,
           file: 'accented.txt')

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

# A repository whose configured user.name is hostile to a shell, and to a
# regular expression. git log used to be assembled as a shell string, so the
# $(...) ran; --author is a regex, so the parentheses matched nothing.
def build_odd_name_repo(path, name, marker)
  FileUtils.mkdir_p(path)
  Dir.chdir(path) do
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', name)
    git('config', 'user.email', 'test@example.com')
    git('config', 'commit.gpgsign', 'false')
    commit(marker, YESTERDAY)

    # The same hostile name has to reach the llm-context.md query too. Putting
    # the file on a branch keeps it out of the checkout, so the only way it can
    # be reported is through that query.
    git('checkout', '-q', '-b', 'notes')
    commit('add notes', YESTERDAY, file: 'llm-context.md',
           content: "#### #{YESTERDAY} - notes\n")
    git('checkout', '-q', 'main')
  end
end

# A repository the standup cannot attribute. An empty --author= matches every
# commit, so this one's commit belongs to somebody else and must not be
# reported. `name` nil leaves user.name unset, which is the other route to the
# same place: git config then exits non-zero instead of printing an empty line.
def build_unidentified_repo(path, subject, name: '')
  FileUtils.mkdir_p(path)
  Dir.chdir(path) do
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', name) if name
    git('config', 'user.email', 'test@example.com')
    git('config', 'commit.gpgsign', 'false')
    stamp = "#{YESTERDAY} 12:00:00 +0000"
    File.write('file.txt', "someone else\n")
    git('add', 'file.txt')
    begin
      ENV['GIT_COMMITTER_DATE'] = stamp
      git('-c', 'user.name=Someone Else', 'commit', '-m', subject, '--date', stamp)
    ensure
      ENV.delete('GIT_COMMITTER_DATE')
    end
  end
end

# A repository whose branch points at an object that is not there. git log
# fails with something on stderr, which must be said rather than swallowed
# into an empty day.
def build_broken_repo(path)
  FileUtils.mkdir_p(path)
  Dir.chdir(path) do
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'Test User')
    git('config', 'user.email', 'test@example.com')
    git('config', 'commit.gpgsign', 'false')
    commit('a commit that will be unreachable', YESTERDAY)
    File.write(File.join('.git', 'refs', 'heads', 'main'), "#{'0' * 40}\n")
  end
end

# A repository with no commits at all. git log over its refs finds an empty
# set, which is not a failure, so this one must pass in silence.
def build_unborn_repo(path)
  FileUtils.mkdir_p(path)
  Dir.chdir(path) do
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'Test User')
    git('config', 'user.email', 'test@example.com')
  end
end

# The report is blocks separated by blank lines, each headed by the repository
# name. Splitting it that way lets an assertion name the repository it means.
def report_blocks(stdout)
  stdout.split(/\n{2,}/).each_with_object({}) do |block, acc|
    lines = block.lines.map(&:chomp).reject(&:empty?)
    next if lines.empty?

    acc[lines.first] = lines.drop(1)
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

  canary = File.join(root, 'the-injection-ran')
  build_odd_name_repo(File.join(root, 'shell-repo'),
                      "Shell $(touch #{canary}) User", 'the shell-name commit')
  # Brackets, not parentheses: git's --author is a basic regular expression,
  # where "(" is already literal but "[Meta]" is a character class.
  build_odd_name_repo(File.join(root, 'regex-repo'),
                      'Regex [Meta] User', 'the regex-name commit')
  build_unidentified_repo(File.join(root, 'empty-name-repo'), 'the empty-name commit')
  build_unidentified_repo(File.join(root, 'no-name-repo'), 'the absent-name commit', name: nil)
  build_broken_repo(File.join(root, 'broken-repo'))
  build_unborn_repo(File.join(root, 'unborn-repo'))

  # A home of its own, so the machine's global user.name cannot stand in for
  # the one no-name-repo deliberately lacks. Every fixture sets its own.
  fake_home = File.join(root, 'fake-home')
  FileUtils.mkdir_p(fake_home)
  output, errors, = Open3.capture3({ 'HOME' => fake_home },
                                   'ruby', SCRIPT, '--projects-root', root)
  blocks = report_blocks(output)

  failures = []
  failures << 'a user.name holding $(...) was executed as a command' if
    File.exist?(canary)
  failures << 'the commit of a user whose name holds $(...) is missing' unless
    output.include?('the shell-name commit')
  failures << 'the commit of a user whose name holds regex characters is missing' unless
    output.include?('the regex-name commit')
  %w[shell-repo regex-repo].each do |repo|
    unless blocks.key?(repo)
      failures << "#{repo} is missing from the report entirely"
      next
    end

    failures << "the llm-context.md query did not run for #{repo}" unless
      blocks[repo].any? { |line| line.include?('llm-context.md was updated') }
  end
  failures << 'a repository whose git log fails was passed over in silence' unless
    errors.include?('broken-repo')
  failures << 'a git failure was written into the report instead of stderr' if
    output.include?('bad object')
  failures << 'a repository with no commits was reported as broken' if
    errors.include?('unborn-repo')
  failures << 'a repository whose user.name is empty reported somebody else\'s commit' if
    output.include?('the empty-name commit')
  failures << 'a repository with no user.name at all reported somebody else\'s commit' if
    output.include?('the absent-name commit')
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
  #
  # A config with no exclude_repos at all still reports everything.
  config = File.join(root, 'standup.yml')
  File.write(config, "repo_name_mapping:\n  quiet-repo: \"#quiet\"\n")
  mapped, = Open3.capture2e({ 'HOME' => fake_home },
                            'ruby', SCRIPT, '--projects-root', root, '--config', config)

  failures << 'a repository missing from repo_name_mapping was filtered out' unless
    mapped.include?('demo-repo')
  failures << 'repo_name_mapping did not rename the repository it names' unless
    mapped.include?('#quiet')
  failures << 'a config with no exclude_repos dropped a repository' unless
    mapped.include?('the shell-name commit')

  # exclude_repos is what decides. A published standup must not name what it
  # lists, and must still name everything else. It matches the directory name,
  # not the display name repo_name_mapping gives it — otherwise renaming a
  # project would quietly un-hide it.
  excluding = File.join(root, 'excluding.yml')
  File.write(excluding, <<~YAML)
    repo_name_mapping:
      shell-repo: "#renamed"
    exclude_repos:
      - shell-repo
  YAML
  hidden, = Open3.capture2e({ 'HOME' => fake_home },
                            'ruby', SCRIPT, '--projects-root', root, '--config', excluding)

  failures << 'an excluded repository was named in the report' if
    hidden.include?('shell-repo') || hidden.include?('#renamed')
  failures << 'an excluded repository still reported its commits' if
    hidden.include?('the shell-name commit')
  failures << 'excluding one repository dropped the others' unless
    hidden.include?('the regex-name commit')

  # A scalar instead of a list would make the check a substring match, which
  # hides repositories nobody asked to hide. It has to refuse, not guess.
  scalar = File.join(root, 'scalar.yml')
  File.write(scalar, "exclude_repos: repo\n")
  scalar_out, scalar_status = Open3.capture2e({ 'HOME' => fake_home },
                                              'ruby', SCRIPT, '--projects-root', root,
                                              '--config', scalar)

  failures << 'exclude_repos written as a scalar was accepted' if scalar_status.success?
  failures << 'the scalar exclude_repos error does not say what is wrong' unless
    scalar_out.include?('exclude_repos must be a list')

  # A list is not enough on its own: one entry that is not a string puts a
  # non-string into the same include? check the scalar case exists to stop.
  mixed = File.join(root, 'mixed.yml')
  File.write(mixed, "exclude_repos:\n  - shell-repo\n  - 42\n")
  mixed_out, mixed_status = Open3.capture2e({ 'HOME' => fake_home },
                                            'ruby', SCRIPT, '--projects-root', root, '--config', mixed)

  failures << 'exclude_repos holding a non-string entry was accepted' if mixed_status.success?
  failures << 'the non-string exclude_repos error does not say what is wrong' unless
    mixed_out.include?('exclude_repos must be a list')

  # An empty entry is not a repository name, and it would otherwise reach the
  # unmatched warning as "exclude_repos names , which is not a repository".
  blank = File.join(root, 'blank.yml')
  File.write(blank, "exclude_repos:\n  - \"\"\n")
  blank_out, blank_status = Open3.capture2e({ 'HOME' => fake_home },
                                            'ruby', SCRIPT, '--projects-root', root, '--config', blank)

  failures << 'an empty exclude_repos entry was accepted' if blank_status.success?
  failures << 'the empty exclude_repos entry error does not say what is wrong' unless
    blank_out.include?('exclude_repos must be a list')

  # An empty list is a real answer: exclude nothing. Strict validation must not
  # start rejecting the configs it was written to allow.
  empty = File.join(root, 'empty.yml')
  File.write(empty, "exclude_repos: []\n")
  emptied, empty_status = Open3.capture2e({ 'HOME' => fake_home },
                                          'ruby', SCRIPT, '--projects-root', root, '--config', empty)

  failures << 'an empty exclude_repos list was rejected' unless empty_status.success?
  failures << 'an empty exclude_repos list dropped a repository' unless
    emptied.include?('the shell-name commit')

  # The match is on the whole directory name. "repo" must not take out
  # "shell-repo", or the substring trap is back through a valid list.
  substring = File.join(root, 'substring.yml')
  File.write(substring, "exclude_repos:\n  - repo\n")
  partial, = Open3.capture2e({ 'HOME' => fake_home },
                             'ruby', SCRIPT, '--projects-root', root, '--config', substring)

  failures << 'an exclude_repos entry matched a repository name as a substring' unless
    partial.include?('the shell-name commit') && partial.include?('the regex-name commit')
  failures << 'an exclude_repos entry that matches nothing was passed over in silence' unless
    partial.include?('not a repository in')

  # Excluding everything with work is the end state of a long enough list. The
  # report has to reach its no-activity line rather than crash or print husks.
  everything = File.join(root, 'everything.yml')
  File.write(everything, "exclude_repos:\n#{report_blocks(output).keys.map { |n| "  - #{n}\n" }.join}")
  silent, silent_status = Open3.capture2e({ 'HOME' => fake_home },
                                          'ruby', SCRIPT, '--projects-root', root, '--config', everything)

  failures << 'excluding every active repository did not exit cleanly' unless silent_status.success?
  failures << 'excluding every active repository did not report a quiet day' unless
    silent.include?('No activity found')

  # A config that was asked for by name and is not there must stop the run.
  #
  # This is not hypothetical. On 2026-09-09 a config path was split before it
  # reached here, standup.rb answered with an empty config, and the report ran
  # with no exclude_repos: every repository under the projects root, named by
  # its directory, in a message with publish buttons attached to it. A silent
  # default is the wrong answer to "read this file".
  missing_out, missing_status = Open3.capture2e({ 'HOME' => fake_home },
                                                'ruby', SCRIPT, '--projects-root', root,
                                                '--config', File.join(root, 'not-here.yml'))

  failures << 'a config named on the command line and missing did not stop the run' if
    missing_status.success?
  failures << 'the missing-config error does not name the file' unless
    missing_out.include?('not-here.yml')
  failures << 'a report was printed despite the missing config' if
    missing_out.include?('the shell-name commit')

  # And the opposite: no --config at all still falls back, which is what makes
  # the tool usable with no configuration.
  _, bare_status = Open3.capture2e({ 'HOME' => fake_home },
                                   'ruby', SCRIPT, '--projects-root', root)
  failures << 'running with no config at all stopped working' unless bare_status.success?

  # The report must survive an environment with no locale, which is the one
  # cron provides.
  #
  # Ruby tags bytes from git with the locale's encoding. With no LANG that is
  # US-ASCII, and the first accented character in a commit subject raises
  # "invalid byte sequence in US-ASCII" — so a day with one Romanian or Italian
  # commit killed the whole standup. It survived only because the wrapper script
  # sources a shell profile that happens to set LANG, which is protection by
  # accident: anything invoking standup.rb directly from cron crashed.
  bare_env = { 'HOME' => fake_home, 'PATH' => ENV['PATH'], 'LANG' => nil, 'LC_ALL' => nil }
  no_locale, no_locale_status = Open3.capture2e(bare_env, 'ruby', SCRIPT,
                                                '--projects-root', root, '--config', config)

  failures << 'the report crashed with no locale set' unless no_locale_status.success?
  failures << 'a non-ASCII commit subject was lost with no locale set' unless
    no_locale.include?('păsărele')

  if failures.empty?
    puts 'ok: the standup reports the day\'s commits, and only those'
  else
    warn "--- standup output ---\n#{output}--- stderr ---\n#{errors}" \
         "--- with a config ---\n#{mapped}--- excluding one ---\n#{hidden}" \
         "--- with a scalar ---\n#{scalar_out}--- with a non-string ---\n#{mixed_out}" \
         "--- with a blank entry ---\n#{blank_out}--- with an empty list ---\n#{emptied}--- excluding a substring ---\n#{partial}" \
         "--- excluding everything ---\n#{silent}----------------------"
    failures.each { |f| warn "FAIL: #{f}" }
    exit 1
  end
end
