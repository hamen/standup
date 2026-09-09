#!/usr/bin/env bash
# Regression test: run it with `bash test_send.sh`.
#
# The renderer has its own tests. This covers the wiring, which is where the
# 2026-09-09 failure lived: the report was rendered correctly and then sent with
# the wrong parse_mode. Every assertion reads what the script actually handed to
# curl, through a stub, so nothing reaches Telegram.
#
# Everything runs from a COPY of the checkout. An earlier version replaced
# bin/standup-publish.py in place to test the broken-renderer path, which left
# the repository damaged if it was interrupted between the two moves.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=()

WORK="$TMP/work"
mkdir -p "$WORK/bin" "$TMP/stub" "$TMP/fakehome"
cp "$ROOT/bin/daily-standup.sh" "$ROOT/bin/standup-publish.py" "$WORK/bin/"
cp "$ROOT/standup.rb" "$WORK/"
printf 'projects_root: %s\n' "$TMP/projects" > "$WORK/standup.yml"

# curl: records every argument, then answers as Telegram would. FAIL_FIRST makes
# the first call fail, which is how the plain-text retry gets exercised.
cat > "$TMP/stub/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CURL_LOG"
printf -- '--- end of call ---\n' >> "$CURL_LOG"
if [ -n "${FAIL_FIRST:-}" ] && [ ! -f "$CURL_LOG.first" ]; then
  : > "$CURL_LOG.first"
  echo '{"ok":false,"description":"Bad Request: stubbed failure"}'
  exit 0
fi
echo '{"ok":true,"result":{"message_id":1,"chat":{"id":1}}}'
SH
chmod +x "$TMP/stub/curl"

run() { # run <log> <args...>
  local log="$1"; shift
  : > "$log"; rm -f "$log.first"
  # LC_ALL because env -i drops it: CPython coerces a C locale to UTF-8 on this
  # build, so the emoji in the title survives, but that is a build option and
  # not something a test should rely on.
  env -i HOME="$TMP/fakehome" PATH="$TMP/stub:/usr/bin:/bin" CURL_LOG="$log" \
      LC_ALL=C.UTF-8 PYTHONUTF8=1 PYTHONIOENCODING=utf-8 \
      ${FAIL_FIRST:+FAIL_FIRST=1} \
      TELEGRAM_BOT_TOKEN=not-a-token TELEGRAM_CHAT_ID=not-a-chat \
      bash "$WORK/bin/daily-standup.sh" "$@" 2>&1
}

# The text of the Nth curl call, so an assertion can say which request it means.
call() { awk -v n="$2" 'BEGIN{c=1} /^--- end of call ---$/{c++; next} c==n' "$1"; }

# --- 1. --test goes out as MarkdownV2 -------------------------------------
out=$(run "$TMP/test.log" --test)
call "$TMP/test.log" 1 | grep -q 'parse_mode=MarkdownV2' ||
  failures+=("--test did not send MarkdownV2")
call "$TMP/test.log" 1 | grep -qx 'parse_mode=Markdown' &&
  failures+=("--test still sends legacy Markdown")
echo "$out" | grep -q 'Test message sent' ||
  failures+=("--test did not report success through the stub")

# --- 2. The whole report path, with the underscore that caused all this ----
# Stub ruby and claude so the script reaches its real send with known text.
cat > "$TMP/stub/ruby" <<'SH'
#!/usr/bin/env bash
printf '#alpha\n• Build config: dart_defines from production.env\n'
SH
cat > "$TMP/stub/claude" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '📋 *Daily Standup*\n\n*#alpha*\n• Build config: dart_defines from production.env\n\n1 project.\n'
SH
chmod +x "$TMP/stub/ruby" "$TMP/stub/claude"

out=$(run "$TMP/report.log")
first=$(call "$TMP/report.log" 1)
echo "$first" | grep -q 'parse_mode=MarkdownV2' ||
  failures+=("the report was not sent as MarkdownV2")
echo "$first" | grep -q 'dart\\_defines' ||
  failures+=("the underscore reached Telegram unescaped")
echo "$first" | grep -q 'inline_keyboard' ||
  failures+=("the report lost its publish buttons")

# The state file must hold the UNESCAPED text: that is what X and wip.co get.
state=$(cat "$TMP/fakehome/.local/state/standup/pending-"*.json 2>/dev/null)
[ -n "$state" ] || failures+=("no pending state was written")
case "$state" in
  *'dart\\_defines'*) failures+=("the state file holds escaped text; X would publish backslashes") ;;
  *dart_defines*) : ;;
  *) failures+=("the state file lost the commit subject") ;;
esac

# --- 3. The retry, when Telegram rejects the first request -----------------
export FAIL_FIRST=1
out=$(run "$TMP/retry.log")
unset FAIL_FIRST   # it would otherwise stub the next test's only call into failing
retry=$(call "$TMP/retry.log" 2)
[ -n "$retry" ] || failures+=("a rejected send was not retried")
echo "$retry" | grep -q 'parse_mode' &&
  failures+=("the retry still carried a parse_mode")
echo "$retry" | grep -q 'dart\\_defines' &&
  failures+=("the retry sent escaped text, which would display backslashes")
echo "$retry" | grep -q 'dart_defines' ||
  failures+=("the retry did not carry the report")

# --- 3b. send_telegram's own retry, which test 3 does not reach ------------
# Test 3 drives the report path. This drives the other send site, which carries
# --test, the rest-day message and the standup-failed alarm.
export FAIL_FIRST=1
out=$(run "$TMP/test-retry.log" --test)
unset FAIL_FIRST
[ -n "$(call "$TMP/test-retry.log" 2)" ] ||
  failures+=("a rejected --test was not retried")
call "$TMP/test-retry.log" 2 | grep -q 'parse_mode' &&
  failures+=("the --test retry still carried a parse_mode")
echo "$out" | grep -q 'Test message sent' ||
  failures+=("--test reported failure after a successful retry")

# --- 3c. A report over Telegram's limit ------------------------------------
# The trim has to reach the wire, and the plain-text retry has to be trimmed
# too — otherwise a busy day plus any rejection means no message at all.
cat > "$TMP/stub/claude" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '📋 *Daily Standup*\n\n*#alpha*\n'
for i in $(seq 1 400); do printf '• a long commit subject number %s, with words in it.\n' "$i"; done
printf '\n1 project.\n'
SH
chmod +x "$TMP/stub/claude"

export FAIL_FIRST=1
out=$(run "$TMP/big.log")
unset FAIL_FIRST
big_first=$(call "$TMP/big.log" 1)
big_retry=$(call "$TMP/big.log" 2)
echo "$big_first" | grep -q 'trimmed to fit Telegram' ||
  failures+=("the oversized report was sent untrimmed")
[ -n "$big_retry" ] || failures+=("the oversized report was not retried after rejection")
echo "$big_retry" | grep -q 'trimmed to fit Telegram' ||
  failures+=("the plain-text retry sent the untrimmed report, which Telegram also rejects")
# Without the keyboard there is nothing to press, so the day cannot be published.
echo "$big_retry" | grep -q 'inline_keyboard' ||
  failures+=("the retry lost the publish buttons")

# Restore the ordinary formatter for anything added after this point.
cat > "$TMP/stub/claude" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '📋 *Daily Standup*\n\n*#alpha*\n• Build config: dart_defines from production.env\n\n1 project.\n'
SH
chmod +x "$TMP/stub/claude"

# --- 3d. The retry keeps its buttons on an ordinary report -----------------
export FAIL_FIRST=1
out=$(run "$TMP/retry2.log")
unset FAIL_FIRST
call "$TMP/retry2.log" 2 | grep -q 'inline_keyboard' ||
  failures+=("the ordinary retry lost the publish buttons")

# --- 4. A broken renderer must not stop the message -----------------------
cp "$WORK/bin/standup-publish.py" "$TMP/publisher.good"
printf 'not python\n' > "$WORK/bin/standup-publish.py"
out=$(run "$TMP/broken.log" --test)
cp "$TMP/publisher.good" "$WORK/bin/standup-publish.py"   # a later test must not inherit this
call "$TMP/broken.log" 1 | grep -q 'parse_mode' &&
  failures+=("a doomed MarkdownV2 request was sent with unescaped text")
call "$TMP/broken.log" 1 | grep -q 'text=' ||
  failures+=("a broken renderer stopped the message going out at all")
echo "$out" | grep -q 'Test message sent' ||
  failures+=("a broken renderer made --test fail instead of falling back")
echo "$out" | grep -q 'Could not render MarkdownV2' ||
  failures+=("a broken renderer failed silently")

# --- 4b. A broken renderer on the REPORT path, which is a different branch --
cp "$WORK/bin/standup-publish.py" "$TMP/publisher.good2"
printf 'not python\n' > "$WORK/bin/standup-publish.py"
out=$(run "$TMP/broken-report.log")
cp "$TMP/publisher.good2" "$WORK/bin/standup-publish.py"
first=$(call "$TMP/broken-report.log" 1)
echo "$first" | grep -q 'parse_mode' &&
  failures+=("the report path sent a doomed MarkdownV2 request with unescaped text")
echo "$first" | grep -q 'dart_defines' ||
  failures+=("a broken renderer stopped the report going out at all")
echo "$first" | grep -q 'inline_keyboard' ||
  failures+=("the unformatted report lost its publish buttons")
echo "$out" | grep -q 'Sending the report unformatted' ||
  failures+=("the report path did not say it was falling back")

if [ ${#failures[@]} -eq 0 ]; then
  echo 'ok: the report reaches Telegram escaped, retries unescaped, and survives a broken renderer'
else
  printf 'FAIL: %s\n' "${failures[@]}" >&2
  exit 1
fi
