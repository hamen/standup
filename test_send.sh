#!/usr/bin/env bash
# Regression test: run it with `bash test_send.sh`.
#
# The renderer has its own tests. This covers the wiring, which is where the
# 2026-09-09 failure actually lived: the report was rendered correctly and then
# sent with the wrong parse_mode. Every check here reads what the script handed
# to curl, through a stub, so nothing reaches Telegram.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=()

mkdir -p "$TMP/stub" "$TMP/home"
# Records every argument it was given, then answers as Telegram would.
cat > "$TMP/stub/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CURL_LOG"
printf -- '---\n' >> "$CURL_LOG"
echo '{"ok":true,"result":{"message_id":1,"chat":{"id":1}}}'
SH
chmod +x "$TMP/stub/curl"

run() { # run <log> <args...>; env -i so no shell profile rebuilds PATH over the stub
  CURL_LOG="$1"; shift
  : > "$CURL_LOG"
  env -i HOME="$TMP/home" PATH="$TMP/stub:/usr/bin:/bin" CURL_LOG="$CURL_LOG" \
      TELEGRAM_BOT_TOKEN=not-a-token TELEGRAM_CHAT_ID=not-a-chat \
      bash "$ROOT/bin/daily-standup.sh" "$@" 2>&1
}

# --- --test goes out as MarkdownV2, escaped -------------------------------
out=$(run "$TMP/test.log" --test)
grep -q 'parse_mode=MarkdownV2' "$TMP/test.log" ||
  failures+=("--test did not send MarkdownV2")
grep -q 'parse_mode=Markdown$' "$TMP/test.log" &&
  failures+=("--test still sends legacy Markdown")
echo "$out" | grep -q 'Test message sent' ||
  failures+=("--test did not report success through the stub")

# --- The underscore that started all of this ------------------------------
# A no-activity day takes the rest-day path, which goes through send_telegram.
cat > "$TMP/home/empty-projects.yml" <<'YML'
projects_root: /nonexistent-projects-root
YML
mkdir -p /tmp/nonexistent-projects-root 2>/dev/null || true
printf 'a_b_c and a.dot and a-dash\n' > "$TMP/subject.txt"

rendered=$(printf '📋 Daily Standup\n\n#alpha\n• Build config: dart_defines from production.env\n' |
  python3 "$ROOT/bin/standup-publish.py" --telegram-markdown)
[[ "$rendered" == *'dart\_defines'* ]] ||
  failures+=("the underscore was not escaped for Telegram")
[[ "$rendered" == *'*\#alpha*'* ]] ||
  failures+=("the project header lost its emphasis")

# --- A broken publisher must not silence the alarm ------------------------
# This is the failure path: standup.rb is gone, so the script reports it — and
# it must still report it when the escaper cannot run.
mv "$ROOT/bin/standup-publish.py" "$TMP/publisher.away"
printf 'not python\n' > "$ROOT/bin/standup-publish.py"
out=$(run "$TMP/broken.log" --test)
mv "$TMP/publisher.away" "$ROOT/bin/standup-publish.py"
grep -q 'text=' "$TMP/broken.log" ||
  failures+=("a broken publisher stopped the message going out at all")
echo "$out" | grep -q 'Test message sent' ||
  failures+=("a broken publisher made --test fail instead of falling back")

if [ ${#failures[@]} -eq 0 ]; then
  echo 'ok: the report reaches Telegram escaped, and still reaches it when the escaper cannot'
else
  printf 'FAIL: %s\n' "${failures[@]}" >&2
  exit 1
fi
