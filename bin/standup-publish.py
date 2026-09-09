#!/usr/bin/env python3
"""Publish the daily standup to X and wip.co, but only after the button is pressed.

daily-standup.sh sends the morning message with an inline "Pubblica" button and
leaves the text in a state file. This runs from cron a few times an hour, asks
Telegram whether the button was pressed, and publishes if it was.

Nothing here publishes on its own. No button, no post.
"""

import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

STATE_DIR = pathlib.Path(
    os.environ.get("STANDUP_STATE_DIR") or pathlib.Path.home() / ".local/state/standup"
)
OFFSET_FILE = STATE_DIR / "telegram-offset"
# The standup wants a bot of its own. Two processes reading one Telegram update
# queue means each press goes to whichever asked first — so the button would
# look fine and collect nothing.
CONFIG_DIR = pathlib.Path(
    os.environ.get("STANDUP_CONFIG_DIR") or pathlib.Path.home() / ".config/standup"
)
TELEGRAM_ENVS = [CONFIG_DIR / "telegram.env"]
WIP_TOKEN_FILE = CONFIG_DIR / "wip-token"

# Resolved, not hardcoded — but not left to PATH alone either. This runs from
# cron, where PATH is short and holds none of the places a global npm install
# puts its binaries, and --selftest never calls bird, so a PATH-only lookup
# fails at the one moment nothing is watching: the post to X.
BIRD = (
    os.environ.get("BIRD_BIN")
    or shutil.which("bird")
    or str(pathlib.Path.home() / ".npm-global/bin/bird")
)


def log(msg):
    print(msg, flush=True)


def die(msg):
    log(f"ERROR: {msg}")
    sys.exit(1)


def read_env(paths, key):
    """Read a key from the first of these files that carries it."""
    for path in paths:
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            line = line.strip()
            if line.startswith(f"{key}=") or line.startswith(f"export {key}="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    die(f"{key} not found in any of {', '.join(str(p) for p in paths)}")


def wip_key():
    if not WIP_TOKEN_FILE.exists():
        die(f"{WIP_TOKEN_FILE} is missing")
    raw = WIP_TOKEN_FILE.read_text().strip()
    # The file has been seen holding WIP_TOKEN=<key> rather than the bare key,
    # which the API rejects exactly like a made-up one. Accept both shapes.
    return raw.split("=", 1)[1] if raw.startswith("WIP_TOKEN=") else raw


def telegram(token, method, **params):
    data = urllib.parse.urlencode(params).encode()
    url = f"https://api.telegram.org/bot{token}/{method}"
    try:
        with urllib.request.urlopen(url, data=data, timeout=30) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code != 409:
            body = e.read().decode("utf-8", "replace")[:300]
            die(f"telegram {method} failed: HTTP {e.code}: {body}")
        if e.code == 409:
            # Somebody else is polling this bot. Telegram hands each update to
            # whichever process asks first, so the button would keep looking
            # fine and keep collecting nothing. Say it where it will be read,
            # rather than dying quietly in a cron log.
            warn_conflict(token)
            die("another process is polling this bot (HTTP 409); the publish button is dead until it stops")
        raise
    if not body.get("ok"):
        die(f"telegram {method} failed: {body}")
    return body["result"]


def warn_conflict(token):
    """Send the alarm with sendMessage, which no conflict blocks."""
    chat_id = read_env(TELEGRAM_ENVS, "TELEGRAM_CHAT_ID")
    text = ("⚠️ Standup: the publish button is not working.\n\n"
            "Another process is reading this bot's updates (HTTP 409), so button "
            "presses never arrive. Usually claude-telegram-bot.service was started: "
            "stop it, or give the standup a bot of its own in "
            f"{TELEGRAM_ENVS[0]}.")
    try:
        data = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode()
        urllib.request.urlopen(
            f"https://api.telegram.org/bot{token}/sendMessage", data=data, timeout=30
        ).close()
    except Exception as e:  # noqa: BLE001 - the alarm must not hide the failure
        log(f"could not send the conflict warning: {e}")


def ack(token, callback_query_id, text):
    """The little toast on the button. Cosmetic, and allowed to fail.

    Telegram rejects a callback id that is too old, and it did: the 400 raised
    through the publish and the post never went out, with the offset already
    advanced so the press was gone. Nothing about a toast is worth a lost day.
    """
    try:
        telegram(token, "answerCallbackQuery", callback_query_id=callback_query_id, text=text)
    # SystemExit too: telegram() calls die() on a bad response, and SystemExit is
    # not an Exception, so catching Exception alone would still have exited here.
    except (Exception, SystemExit) as e:  # noqa: BLE001 - the publish is the point
        log(f"could not acknowledge the button press ({e}); publishing anyway")


def strip_telegram_markup(text):
    """The morning message is Telegram Markdown. X and wip.co are not."""
    out = []
    for line in text.splitlines():
        line = line.replace("**", "").replace("*", "").replace("_", "")
        out.append(line)
    return "\n".join(out).strip()


def wip_projects():
    """The projects as wip.co holds them, keyed by hashtag."""
    url = "https://api.wip.co/v1/users/me/projects?" + urllib.parse.urlencode(
        {"api_key": wip_key(), "limit": "100"}
    )
    with urllib.request.urlopen(url, timeout=30) as r:
        body = json.load(r)
    items = body if isinstance(body, list) else body.get("data", [])
    return {p["hashtag"]: p for p in items if p.get("hashtag")}


HASHTAG = re.compile(r"#([a-z0-9]+)")

# A header as standup.rb emits it: the mapped hashtag, alone on its line.
RAW_HEADER = re.compile(r"#([A-Za-z0-9][A-Za-z0-9_-]*)")
# The same header after the formatter, which may have bolded it and may have
# eaten the "#". Anything with a space in it is a title or a trailer, not a header.
FMT_HEADER = re.compile(r"\*?#?([A-Za-z0-9][A-Za-z0-9_-]*)\*?")


def repair_headers(raw, formatted):
    """Put back the hashtags the formatter dropped, against what standup.rb emitted.

    The headers are data, not prose. wip.co attaches a todo to a project BY the
    hashtag, and the X text swaps that hashtag for the project name and website.
    The prompt asks an LLM to keep one character, and on 2026-09-09 it did not:
    it bolded the names and dropped every "#". The post went out with no links,
    and the wip.co todo would have attached to nothing. Neither failure is
    visible downstream, because a missing "#" reads exactly like a project that
    never had one.

    So the hashtags are restored from the raw report rather than hoped for in
    the prompt. Returns (repaired_text, missing_tags); a non-empty second value
    means the formatter lost a whole project and its output must not be used.
    """
    tags = [m.group(1) for line in raw.split("\n")
            if (m := RAW_HEADER.fullmatch(line.strip()))]
    out = []
    for line in formatted.split("\n"):
        m = FMT_HEADER.fullmatch(line.strip())
        out.append(f"*#{m.group(1)}*" if m and m.group(1) in tags else line)
    repaired = "\n".join(out)
    return repaired, [t for t in tags if f"#{t}" not in repaired]


def shuffle_projects(text, seed):
    """Reorder the project blocks, the same way all day, differently each day.

    X builds the link card from the first URL in the tweet. The standup lists
    the projects in a stable order, so the same site was always first and the
    card carried the same image every morning.

    Seeded by the day on purpose: --preview renders this text hours before the
    button is pressed, and a preview that does not match what gets posted is
    not an approval of anything.

    Blocks with no hashtag — the title, the closing count — keep their place.
    """
    blocks = re.split(r"\n\s*\n", text)
    slots = [i for i, b in enumerate(blocks) if HASHTAG.search(b.split("\n")[0])]
    picked = [blocks[i] for i in slots]
    random.Random(seed).shuffle(picked)
    for i, block in zip(slots, picked):
        blocks[i] = block
    return "\n\n".join(blocks)


def for_x(text, seed):
    """Rewrite the hashtags as project names and links, for X.

    A hashtag is the attach mechanism on wip.co and nothing but text on X, where
    a row of them reads as spam. The name and the site say more.

    The names and URLs come from wip.co itself, at publish time, rather than a
    second list here that would drift from it — the same duplication that made
    a standup silently hide six repositories, and made a command report a cache
    it did not keep.

    If wip.co cannot be reached, the hashtags stay. A post that reads a little
    worse beats no post at all.
    """
    text = shuffle_projects(text, seed)
    try:
        projects = wip_projects()
    except Exception as e:  # noqa: BLE001 - never let this block a publish
        log(f"could not read wip.co projects, keeping the hashtags: {e}")
        return text

    def swap(match):
        project = projects.get(match.group(1))
        site = (project or {}).get("website_url")
        if not project or not site:
            return match.group(0)
        return f"{project.get('name') or match.group(1)} — {site}"

    return HASHTAG.sub(swap, text)


def post_to_x(text, seed):
    # Every failure has to come back as a value, never as an exception. The
    # offset file was advanced before this is called, so a raised TimeoutExpired
    # — or a FileNotFoundError from a BIRD_BIN that points nowhere, which is the
    # likely one under cron — takes the button press with it and the day cannot
    # be retried at all.
    text = for_x(text, seed)
    try:
        result = subprocess.run([BIRD, "tweet", text],
                                capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        return False, f"bird not found at {BIRD} (set BIRD_BIN)"
    except subprocess.TimeoutExpired:
        return False, "bird timed out after 120s; it may or may not have posted"
    except OSError as e:  # noqa: BLE001 - the reason has to reach the log
        return False, f"could not run bird: {e}"[:300]
    if result.returncode != 0:
        return False, (result.stderr or result.stdout).strip()[:300]
    return True, (result.stdout or "").strip()[:300]


def post_to_wip(text):
    data = urllib.parse.urlencode({"body": text}).encode()
    url = "https://api.wip.co/v1/todos?" + urllib.parse.urlencode({"api_key": wip_key()})
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = json.load(r)
        return True, body.get("url") or str(body)[:200]
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}"
    except Exception as e:  # noqa: BLE001 - the reason has to reach the log
        return False, str(e)[:300]


def pending_states():
    if not STATE_DIR.exists():
        return []
    out = []
    for p in sorted(STATE_DIR.glob("pending-*.json")):
        try:
            out.append((p, json.loads(p.read_text())))
        except json.JSONDecodeError:
            log(f"skipping unreadable state file {p}")
    return out


def selftest():
    text = ("\U0001F4CB Daily Standup \u2014 2026-09-06\n\n"
            "#alpha\n\u2022 one\n\n#beta\n\u2022 two\n\n#gamma\n\u2022 three\n\n"
            "3 projects, 9 commits shipped")
    day = shuffle_projects(text, "2026-09-06")
    assert day == shuffle_projects(text, "2026-09-06"), "one day must render one order"
    assert day.startswith("\U0001F4CB Daily Standup"), "the title has to stay first"
    assert day.endswith("9 commits shipped"), "the closing line has to stay last"
    assert sorted(HASHTAG.findall(day)) == ["alpha", "beta", "gamma"], "no project may be lost"
    firsts = {HASHTAG.search(shuffle_projects(text, f"2026-09-{d:02d}")).group(1)
              for d in range(1, 29)}
    assert len(firsts) > 1, f"the first project never changes: {firsts}"

    # The 2026-09-09 failure, and the shapes around it.
    raw = "#alpha\n\u2022 one\n#beta\n\u2022 two"
    dropped = "\U0001F4CB *Daily Standup*\n\n*alpha*\n\u2022 one\n\n*beta*\n\u2022 two\n\n2 projects \u2014 fine."
    fixed, missing = repair_headers(raw, dropped)
    assert not missing, missing
    assert "*#alpha*" in fixed and "*#beta*" in fixed, fixed
    assert "\U0001F4CB *Daily Standup*" in fixed, "the title is not a header"
    assert "2 projects \u2014 fine." in fixed, "the trailer is not a header"
    assert "\u2022 one" in fixed, "bullets must not be touched"
    # Already correct: repairing twice must not double the hash.
    again, _ = repair_headers(raw, fixed)
    assert again == fixed and "##" not in again, again
    # A project the formatter deleted cannot be repaired, and must be reported.
    _, lost = repair_headers(raw, "*alpha*\n\u2022 one")
    assert lost == ["beta"], lost
    # A project this standup never had must not be invented into a header.
    kept, _ = repair_headers(raw, "*gamma*\n\u2022 three\n\n*alpha*\n\u2022 one")
    assert "*gamma*" in kept and "#gamma" not in kept, kept
    print("selftest ok")


def main():
    # The morning message shows the wip.co form, where the hashtags do the
    # attaching. What goes to X is a different text, and approving a text you
    # cannot see is not approving anything: --preview renders it.
    if "--preview" in sys.argv:
        try:
            pending = sys.argv[sys.argv.index("--preview") + 1]
        except IndexError:
            die("--preview needs the pending id, e.g. --preview 2026-09-09")
        state = json.loads((STATE_DIR / f"pending-{pending}.json").read_text())
        print(for_x(strip_telegram_markup(state["text"]), pending))
        return

    if "--selftest" in sys.argv:
        selftest()
        return

    # Reads the formatted report on stdin and the raw one from RAW_STANDUP, so
    # neither has to survive argv quoting. Exits 1 when a project went missing,
    # which is daily-standup.sh's signal to publish the raw report instead.
    if "--repair-headers" in sys.argv:
        repaired, missing = repair_headers(os.environ.get("RAW_STANDUP", ""),
                                           sys.stdin.read())
        if missing:
            log(f"ERROR: the formatter dropped {', '.join('#' + t for t in missing)}")
            sys.exit(1)
        sys.stdout.write(repaired)
        return

    token = read_env(TELEGRAM_ENVS, "TELEGRAM_BOT_TOKEN")

    states = {s.get("id"): (p, s) for p, s in pending_states()}
    if not states:
        return  # nothing waiting; say nothing, this runs every few minutes

    offset = 0
    if OFFSET_FILE.exists():
        offset = int(OFFSET_FILE.read_text().strip() or 0)

    updates = telegram(token, "getUpdates", offset=offset, timeout=0,
                       allowed_updates=json.dumps(["callback_query"]))
    if updates:
        OFFSET_FILE.parent.mkdir(parents=True, exist_ok=True)
        OFFSET_FILE.write_text(str(updates[-1]["update_id"] + 1))

    for update in updates:
        cb = update.get("callback_query")
        if not cb:
            continue
        data = cb.get("data", "")
        if not data.startswith("publish:"):
            continue
        # publish:<id>:<target>, where target is x, wip, or both. Separate
        # buttons exist so a day already posted to one place can still be sent
        # to the other without risking a duplicate on the first.
        parts = data.split(":")
        key = parts[1]
        target = parts[2] if len(parts) > 2 else "both"
        if key not in states:
            ack(token, cb["id"], "Quel messaggio non è più in attesa.")
            continue

        path, state = states[key]
        text = strip_telegram_markup(state["text"])
        ack(token, cb["id"], "Pubblico…")

        # Each destination is remembered on its own. A half-done day — X posted,
        # wip.co refused — must be retryable without tweeting it twice, and a
        # duplicate on a public timeline is not something an apology undoes.
        lines = []
        for name, code, already, fn in (("X", "x", "posted_x", lambda t: post_to_x(t, key)),
                                        ("wip.co", "wip", "posted_wip", post_to_wip)):
            if target not in (code, "both"):
                continue
            if state.get(already):
                lines.append(f"✅ {name} — already posted, skipped")
                continue
            ok, detail = fn(text)
            state[already] = ok
            lines.append(f"{'✅' if ok else '❌'} {name} — {detail or 'posted'}")

        log(f"[{key}] " + " | ".join(lines))

        # Record what was published BEFORE telling anyone about it.
        #
        # The other order looks harmless and is not: telegram() calls die() on a
        # failed response, and the offset file was already advanced above, so a
        # Telegram hiccup between the tweet and the status reply loses the whole
        # record of the press. The next press then reposts to X. A duplicate on
        # a public timeline is not something an apology undoes, and it would be
        # caused by the one network call whose only job is to say what happened.
        if state.get("posted_x") and state.get("posted_wip"):
            path.unlink(missing_ok=True)
        else:
            # Keep what succeeded, so pressing the button again only retries the
            # destination that failed.
            path.write_text(json.dumps(state, ensure_ascii=False, indent=2))

        telegram(token, "sendMessage", chat_id=state["chat_id"],
                 reply_to_message_id=state["message_id"],
                 text="\n".join(lines))


if __name__ == "__main__":
    main()
