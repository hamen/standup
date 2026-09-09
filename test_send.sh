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
mkdir -p "$WORK/bin" "$TMP/stub" "$TMP/home"
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
  env -i HOME="$TMP/home" PATH="$TMP/stub:/usr/bin:/bin" CURL_LOG="$log" \
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
state=$(cat "$TMP/home/.local/state/standup/pending-"*.json 2>/dev/null)
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

# --- 4. A broken renderer must not stop the message -----------------------
printf 'not python\n' > "$WORK/bin/standup-publish.py"
out=$(run "$TMP/broken.log" --test)
call "$TMP/broken.log" 1 | grep -q 'parse_mode' &&
  failures+=("a doomed MarkdownV2 request was sent with unescaped text")
call "$TMP/broken.log" 1 | grep -q 'text=' ||
  failures+=("a broken renderer stopped the message going out at all")
echo "$out" | grep -q 'Test message sent' ||
  failures+=("a broken renderer made --test fail instead of falling back")
echo "$out" | grep -q 'Could not render MarkdownV2' ||
  failures+=("a broken renderer failed silently")

if [ ${#failures[@]} -eq 0 ]; then
  echo 'ok: the report reaches Telegram escaped, retries unescaped, and survives a broken renderer'
else
  printf 'FAIL: %s\n' "${failures[@]}" >&2
  exit 1
fi
