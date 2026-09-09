#!/usr/bin/env ruby
# Regression test: run it with `ruby test_privacy.rb`.
#
# This repository is public and the pipeline in bin/ publishes to X and wip.co.
# Two different things must therefore never be committed: a credential, and the
# name of a private repository. Both have nearly happened. The example config
# and the README once used real project directories and real wip.co hashtags,
# and they were only removed by rewriting the published history.
#
# A rule in a document does not survive the morning somebody is in a hurry, so
# this is a test.

require 'open3'
require 'yaml'

ROOT = __dir__
failures = []
notes = []

tracked, status = Open3.capture2('git', '-C', ROOT, 'ls-files')
abort 'not a git repository, or git is unavailable' unless status.success?
files = tracked.split("\n").reject(&:empty?)
abort 'git ls-files returned nothing' if files.empty?

# Read as bytes: a stray binary would otherwise raise on encoding rather than
# report a finding, and a test that dies is a test that says nothing.
contents = files.to_h do |f|
  path = File.join(ROOT, f)
  [f, File.file?(path) ? File.read(path, mode: 'rb').force_encoding('UTF-8').scrub : '']
end

def offend(contents, failures, label)
  contents.each do |file, body|
    body.each_line.with_index(1) do |line, n|
      failures << "#{label}: #{file}:#{n}" if yield(line)
    end
  end
end

# --- 1. Credentials -------------------------------------------------------
#
# A Telegram bot token is <digits>:<35-odd of base64ish>. The placeholder in
# standup.env.example is deliberately not of that shape, so this rule needs no
# exemption to argue about later.
offend(contents, failures, 'a Telegram bot token') do |line|
  line.match?(/\b\d{8,12}:[A-Za-z0-9_-]{30,}/)
end

# An api_key with something attached to it. `api_key=` alone is the wip.co URL
# builder in bin/, which is code, not a secret.
offend(contents, failures, 'an API key with a value') do |line|
  line.match?(/api[_-]?key["'\s]*[:=]["'\s]*[A-Za-z0-9_\-]{12,}/i)
end

# No \b before the keyword. An underscore is a word character, so \bTOKEN never
# matches WIP_TOKEN or TELEGRAM_BOT_TOKEN — which are the two names a real
# credential would actually be assigned to here. The rule reported them safe.
offend(contents, failures, 'an assigned secret') do |line|
  line.match?(/(?:^|[^A-Za-z])[A-Z_]*(TOKEN|SECRET|PASSWORD|API_KEY)\s*=\s*["']?[A-Za-z0-9_\-]{16,}/i)
end

# --- 2. Somebody's home directory ----------------------------------------
#
# No exemption for "obvious" placeholders. The example config and the README
# used to spell out two of them, and an exemption list is precisely where a
# real path eventually hides. Write ~ or /path/to instead.
#
# No trailing slash is required either: a bare home path at the end of a line
# is exactly as much of a leak as one with a directory after it.
#
# Note this file must not spell out the shape it bans, or it fails itself —
# which is a fair test of the rule.
offend(contents, failures, 'an absolute home directory') do |line|
  line.match?(%r{/(home|Users)/[A-Za-z0-9._-]+})
end

# --- 3. Private repository names ------------------------------------------
#
# The names come from standup.yml, which is gitignored, so this check can only
# run where that file exists — on the machine that has something to leak. It
# cannot run in CI, and that is stated out loud rather than passing quietly:
# a check that is silently skipped is worse than one that is absent, because it
# reads as a pass.
config = File.join(ROOT, 'standup.yml')
if File.file?(config)
  # Parsed as YAML, not scanned with a regex. `- "quoted-name"` and
  # `"quoted-name": "#project"` are both perfectly ordinary YAML and both
  # escaped the pattern version — and a private name that escapes this check is
  # the entire failure this test exists to prevent.
  #
  # Every mapping key, too, not only those mapped to a hashtag: repo_name_mapping
  # maps directories to display names generally, and one mapped to a plain name
  # is exactly as private as one mapped to "#something".
  parsed = begin
    YAML.safe_load(File.read(config)) || {}
  rescue Psych::SyntaxError => e
    abort "standup.yml is not valid YAML, so the name check cannot run: #{e.message}"
  end
  names = Array(parsed['exclude_repos']).grep(String)
  names += Array(parsed['repo_name_mapping']).to_h.keys.grep(String) if parsed['repo_name_mapping']
  names = names.map(&:strip).reject(&:empty?).uniq

  # This repository excludes itself from its own report, so its own name is in
  # that list — and its own name is, unavoidably, all over its own README, its
  # scripts and its tests. It is also public by definition. Drop it, or the test
  # fails 43 times on the day it is written and teaches everyone to ignore it.
  #
  # Taken from the remote rather than the directory name: a worktree is called
  # whatever the branch needed, not what the project is.
  remote, ok = Open3.capture2('git', '-C', ROOT, 'remote', 'get-url', 'origin')
  own = ok.success? ? File.basename(remote.strip, '.git') : nil
  own ||= File.basename(Open3.capture2('git', '-C', ROOT, 'rev-parse', '--show-toplevel').first.strip)
  names.delete(own)

  # A name is matched as a whole word, never as a substring of prose. The
  # substring version failed on an excluded directory whose name also appeared,
  # innocently, inside longer words elsewhere in the repository — and a test
  # that makes you delete an explanation to stay green is making the code worse.
  #
  # This comment cannot name the example, for the same reason the home-directory
  # rule cannot spell out the shape it bans: the check reads this file too.
  # Nothing is excluded by filename, and the example config and the README's
  # fenced blocks least of all: those are the two places the real names lived,
  # and removing published history was the price. An earlier draft skipped them
  # to avoid a placeholder colliding with a real name. That is the wrong trade —
  # if a placeholder here ever matches a real private repository, the right
  # answer is to change the placeholder, and this test saying so is the feature.
  # Nothing is skipped — not comments, not headings, not fenced blocks. An
  # earlier draft skipped "#" comments in code so that a legacy comment naming
  # a tool would not trip it. No such comment survives here, and the exemption
  # only blinded the check in the files where names actually get pasted.
  contents.each do |file, body|
    body.each_line.with_index(1) do |line, n|
      names.each do |name|
        # No length floor. It used to skip anything under four characters, which
        # is exactly the shape of the names most likely to be missed — a repo
        # called "api" or "wip" could sit in any tracked file. The whole-word
        # match below is what keeps short names from firing on prose.
        failures << "the private repository name #{name.inspect}: #{file}:#{n}" if
          line.match?(/(?<![A-Za-z0-9._-])#{Regexp.escape(name)}(?![A-Za-z0-9._-])/)
      end
    end
  end
  notes << "checked #{names.size} private names from standup.yml"
else
  notes << 'name check SKIPPED: no standup.yml here (expected in CI; it is gitignored). ' \
           'The credential and home-directory checks above still ran.'
end

notes.each { |n| puts "note: #{n}" }

if failures.empty?
  puts 'ok: nothing private is committed'
else
  failures.uniq.each { |f| warn "FAIL: #{f}" }
  exit 1
end
