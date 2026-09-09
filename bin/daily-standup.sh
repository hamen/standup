#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# daily-standup.sh — Daily standup summary → Telegram
# ============================================================================
# Runs the standup script, passes the output to Claude for formatting,
# and sends it to Telegram.
#
# Usage:
#   ./daily-standup.sh              # yesterday's standup
#   ./daily-standup.sh --today      # today's standup
#   ./daily-standup.sh --test       # send a test ping
#   ./daily-standup.sh --check      # print what it resolved, send nothing
#
# Everything it needs is either beside it in this repository or named by an
# environment variable, so it runs from a clone rather than from one machine:
#
#   STANDUP_CONFIG_DIR   where the credentials live   (~/.config/standup)
#   STANDUP_CONFIG       the report config            (<repo>/standup.yml)
#   STANDUP_STATE_DIR    pending button presses       (~/.local/state/standup)
#   CLAUDE_TOKEN_ENV     headless Claude Code auth    (~/.config/claude-code-token.env)
#   CLAUDE_BIN           the Claude CLI               (whatever is on PATH)
# ============================================================================

# readlink -f, not dirname alone: the README teaches symlinking this into
# ~/.local/bin, and a bare dirname then resolves to ~/.local/bin, where neither
# standup.rb nor standup-publish.py is.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# standup.rb sits at the repository root; this script sits in bin/ beneath it.
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ---- Source shell profile (cron runs with minimal env) ----
if [ -f "$HOME/.zshrc" ]; then
  export SHELL=/bin/zsh
  set +eu
  source "$HOME/.zshenv" 2>/dev/null || true
  source "$HOME/.zprofile" 2>/dev/null || true
  source "$HOME/.zshrc" 2>/dev/null || true
  set -eu
elif [ -f "$HOME/.bashrc" ]; then
  set +eu
  source "$HOME/.bash_profile" 2>/dev/null || true
  source "$HOME/.bashrc" 2>/dev/null || true
  set -eu
fi

# ---- Load Telegram credentials ----
#
# The standup wants a bot of its own, not one shared with another program. Two
# processes reading one Telegram update queue means each button press goes to
# whichever asked first, so the button looks fine and collects nothing.
STANDUP_CONFIG_DIR="${STANDUP_CONFIG_DIR:-$HOME/.config/standup}"
TELEGRAM_CREDS="$STANDUP_CONFIG_DIR/telegram.env"
if [ -f "$TELEGRAM_CREDS" ]; then
  set -a; source "$TELEGRAM_CREDS"; set +a
fi

# ---- Claude Code headless auth (cron has no interactive OAuth session) ----
CLAUDE_TOKEN_ENV="${CLAUDE_TOKEN_ENV:-$HOME/.config/claude-code-token.env}"
if [ -f "$CLAUDE_TOKEN_ENV" ]; then
  set -a; source "$CLAUDE_TOKEN_ENV"; set +a
fi

# ---- Check mode: what did all of that resolve to? ----
#
# Placed before the credential check on purpose, and this is the whole point of
# the flag: --check has to work on a machine that has nothing set up yet, or it
# cannot report what is missing. Put it after, and it dies on the first thing
# absent instead of listing all of them — which is what happened, and what CI
# caught. It sends nothing and always exits 0.
#
# Resolution order here mirrors what actually runs: the environment variable
# first, then PATH, then the documented default. Printing PATH first would
# name a binary the cron job will never call.
if [ "${1:-}" = "--check" ]; then
  cfg="${STANDUP_CONFIG:-$REPO_DIR/standup.yml}"
  echo "repository:    $REPO_DIR"
  echo "standup.rb:    $REPO_DIR/standup.rb $([ -f "$REPO_DIR/standup.rb" ] || echo '(MISSING)')"
  echo "report config: $cfg $([ -f "$cfg" ] || echo '(MISSING — copy standup.yml.example)')"
  echo "credentials:   $TELEGRAM_CREDS $([ -f "$TELEGRAM_CREDS" ] || echo '(MISSING — copy standup.env.example)')"
  echo "bot token:     $([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo set || echo 'NOT SET')"
  echo "chat id:       $([ -n "${TELEGRAM_CHAT_ID:-}" ] && echo set || echo 'NOT SET')"
  echo "claude:        ${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
  echo "bird:          ${BIRD_BIN:-$(command -v bird 2>/dev/null || echo "$HOME/.npm-global/bin/bird")}"
  echo "publisher:     $SCRIPT_DIR/standup-publish.py $([ -f "$SCRIPT_DIR/standup-publish.py" ] || echo '(MISSING)')"
  echo "state dir:     ${STANDUP_STATE_DIR:-$HOME/.local/state/standup}"
  exit 0
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "ERROR: Telegram credentials not found at $TELEGRAM_CREDS"
  exit 1
fi

send_telegram() {
  local message="$1"
  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" \
    --data-urlencode "parse_mode=Markdown")
  if echo "$resp" | grep -q '"ok":true'; then
    return 0
  fi
  # Markdown rejected (e.g. unbalanced entities) — retry as plain text so the
  # message still gets delivered, and surface the error instead of hiding it.
  echo "  Telegram Markdown send failed: $resp"
  resp=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}")
  echo "$resp" | grep -q '"ok":true' || echo "  Plain-text send also failed: $resp"
}

# ---- Test mode ----
if [ "${1:-}" = "--test" ]; then
  send_telegram "✅ Daily standup bot is working. $(date '+%Y-%m-%d %H:%M')"
  echo "Test message sent."
  exit 0
fi

# ---- Config ----
TODAY=$(date '+%Y-%m-%d')
STANDUP_BIN="$REPO_DIR/standup.rb"
STANDUP_CONFIG="${STANDUP_CONFIG:-$REPO_DIR/standup.yml}"

# A missing report config is a leak, not an inconvenience, which is why this
# refuses to run rather than carrying on with a default.
#
# standup.yml is gitignored, so a fresh clone has none, and standup.rb answers a
# missing config with an empty one rather than an error. The report would then
# have no repo_name_mapping and no exclude_repos — and this pipeline publishes
# to X and wip.co. Every private repository under the projects root would be
# named, under its own directory name, in public.
#
# Checked here and not earlier on purpose: --test and --check must still work on
# a fresh clone, because proving the bot works is the first thing anyone does.
if [ ! -s "$STANDUP_CONFIG" ]; then
  echo "ERROR: no usable report config at $STANDUP_CONFIG"
  # -s, not -f: an empty file parses to an empty config, which is exactly the
  # publish-everything case this guard exists to stop.
  echo "Copy standup.yml.example to that path and edit it, or set STANDUP_CONFIG."
  echo "Refusing to run: without it, every repository would be published by directory name."
  exit 1
fi

# Build standup args
# An array, not a string: word splitting would turn a config path containing a
# space into two arguments and the run would fail on a path that is perfectly
# legal.
STANDUP_ARGS=(--config "$STANDUP_CONFIG")
if [ "${1:-}" = "--today" ]; then
  STANDUP_ARGS+=(--today)
  DATE_LABEL="today"
else
  DATE_LABEL="yesterday"
fi

# ---- Run standup ----
echo "[$TODAY] Running daily standup ($DATE_LABEL)..."
RAW_STANDUP=$(ruby "$STANDUP_BIN" "${STANDUP_ARGS[@]}" 2>&1) || {
  echo "  Standup script failed: $RAW_STANDUP"
  send_telegram "⚠️ Daily standup failed: ${RAW_STANDUP:0:200}"
  exit 1
}

if [ -z "$RAW_STANDUP" ] || echo "$RAW_STANDUP" | grep -q "^No activity found"; then
  send_telegram "📋 *Daily Standup — $TODAY*

No commits $DATE_LABEL. Rest day? 🏖️"
  echo "[$TODAY] No activity — message sent."
  exit 0
fi

# ---- Format with Claude (claude -p) ----
echo "  Formatting with Claude..."
PROMPT="You are formatting a daily developer standup for Telegram.

Date: $TODAY (this is $DATE_LABEL's activity)

Here is the raw standup output (each section is a project hashtag, bullets are commits):

$RAW_STANDUP

Format this as a concise, scannable Telegram message:
- Start with: 📋 *Daily Standup — $TODAY*
- Group by project hashtag (bold the hashtag)
- Summarize related commits into one bullet where possible (don't repeat noise like 'chore: bump version')
- Use plain language, not commit-speak
- Add a brief one-line summary at the end with total project count
- Keep it short — this is a standup, not a changelog
- Use Telegram Markdown: SINGLE asterisk for bold (*bold*), NOT double (**bold**). Use _italic_ for italic.
- Output ONLY the formatted message, nothing else"

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
ANALYSIS=$(echo "$PROMPT" | timeout 120 "$CLAUDE_BIN" -p --model haiku 2>/dev/null) || ANALYSIS=""

# Fallback: if Claude failed, send raw standup
if [ -z "$ANALYSIS" ]; then
  echo "  Claude formatting failed, using raw fallback"
  ANALYSIS="📋 *Daily Standup — $TODAY*

$RAW_STANDUP"
fi

# The hashtags are data, not prose: wip.co attaches a todo to a project BY the hashtag, and the X
# text swaps it for the project name and website. The prompt above asks an LLM to keep one
# character, and on 2026-09-09 it did not — it bolded the names and dropped every "#". The X post
# went out with no links and the wip.co todo would have attached to nothing, and neither failure
# is visible downstream, because a dropped "#" reads exactly like a project that never had one.
# So restore them from what standup.rb actually emitted. If a whole project is missing, the
# formatter lost work: publish the raw report, which is uglier and correct.
REPAIRED=$(printf '%s' "$ANALYSIS" | RAW_STANDUP="$RAW_STANDUP" \
  python3 "$SCRIPT_DIR/standup-publish.py" --repair-headers) && ANALYSIS="$REPAIRED" || {
  echo "  Formatter lost a project; publishing the raw standup instead"
  ANALYSIS="📋 *Daily Standup — $TODAY*

$RAW_STANDUP"
}

# ---- Send to Telegram, with the button that publishes it ----
#
# The button does not publish. It records that you pressed it; standup-publish.py
# runs from cron, sees the press, and posts to X and wip.co. Nothing reaches
# either of them without that press.
echo "  Sending to Telegram..."

STATE_DIR="${STANDUP_STATE_DIR:-$HOME/.local/state/standup}"
mkdir -p "$STATE_DIR"
PENDING_ID="$TODAY"
# One button per destination, so a day already published to one place can still
# be sent to the other. Each destination is recorded on its own, so pressing the
# same button twice is a no-op rather than a duplicate.
KEYBOARD="{\"inline_keyboard\":[[{\"text\":\"🐦 X\",\"callback_data\":\"publish:${PENDING_ID}:x\"},{\"text\":\"📋 wip.co\",\"callback_data\":\"publish:${PENDING_ID}:wip\"}],[{\"text\":\"🚀 Entrambi\",\"callback_data\":\"publish:${PENDING_ID}:both\"}]]}"

RESP=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${ANALYSIS}" \
  --data-urlencode "parse_mode=Markdown" \
  --data-urlencode "reply_markup=${KEYBOARD}")

if ! echo "$RESP" | grep -q '"ok":true'; then
  # Markdown rejected (unbalanced entities, usually). Retry as plain text so the
  # message and its button still arrive, and say why rather than hiding it.
  echo "  Telegram Markdown send failed: $RESP"
  RESP=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${ANALYSIS}" \
    --data-urlencode "reply_markup=${KEYBOARD}")
fi

if echo "$RESP" | grep -q '"ok":true'; then
  MESSAGE_ID=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["message_id"])')
  CHAT_ID=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["chat"]["id"])')
  # ANALYSIS goes through the environment, not argv: it is multi-line and long,
  # and argv quoting is where this kind of thing breaks.
  export ANALYSIS
  python3 - "$STATE_DIR/pending-${PENDING_ID}.json" "$PENDING_ID" "$MESSAGE_ID" "$CHAT_ID" <<'PYEOF'
import json, os, sys
path, pending_id, message_id, chat_id = sys.argv[1:5]
json.dump({"id": pending_id, "message_id": int(message_id), "chat_id": int(chat_id),
           "text": os.environ["ANALYSIS"], "posted_x": False, "posted_wip": False},
          open(path, "w"), ensure_ascii=False, indent=2)
PYEOF
  # Show the X form too, as a reply. The message above is the wip.co form: the
  # hashtags are what attach a todo to a project there. On X they are just a row
  # of words, so standup-publish.py swaps them for the project name and site —
  # and until now that swap only happened after the button was pressed, which
  # meant approving a text nobody had seen. Sent separately on purpose: the
  # state file holds the wip.co text, and that is what wip.co must receive.
  X_PREVIEW=$(python3 "$SCRIPT_DIR/standup-publish.py" --preview "$PENDING_ID" 2>/dev/null || true)
  if [ -n "$X_PREVIEW" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "reply_to_message_id=${MESSAGE_ID}" \
      --data-urlencode "disable_web_page_preview=true" \
      --data-urlencode "text=🐦 Su X esce così:

${X_PREVIEW}" > /dev/null
  else
    echo "  X preview failed; the button still works, you just cannot see the X form"
  fi
  echo "[$TODAY] Daily standup sent, waiting for the publish button."
else
  echo "  Plain-text send also failed: $RESP"
  echo "[$TODAY] Daily standup NOT sent."
  exit 1
fi
