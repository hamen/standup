#!/usr/bin/env python3
"""Publish the daily standup to X and wip.co, but only after the button is pressed.

daily-standup.sh sends the morning message with an inline "Pubblica" button and
leaves the text in a state file. This runs from cron a few times an hour, asks
Telegram whether the button was pressed, and publishes if it was.

Nothing here publishes on its own. No button, no post.
"""

import contextlib
import fcntl
import io
import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
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


def warn(msg):
    """Diagnostics that must never reach stdout.

    daily-standup.sh captures --preview's stdout as the text it posts to X, so
    anything printed there lands inside the tweet — and for_x would then return
    different bytes at publish time than the preview showed.
    """
    print(msg, file=sys.stderr, flush=True)


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


HASHTAG = re.compile(r"#([a-z0-9]+)")

# A header as standup.rb emits it: the mapped hashtag, alone on its line.
RAW_HEADER = re.compile(r"#([A-Za-z0-9][A-Za-z0-9_-]*)")
# The same header after the formatter, which may have bolded it and may have
# eaten the "#". Anything with a space in it is a title or a trailer, not a header.
FMT_HEADER = re.compile(r"\*?#?([A-Za-z0-9][A-Za-z0-9_-]*)\*?")


# Every character MarkdownV2 gives a meaning to. All of them are escaped,
# without asking whether this one looks like markup: guessing is what legacy
# Markdown does, and guessing is the bug.
MDV2_SPECIAL = re.compile(r"([_*\[\]()~`>#+\-=|{}.!\\])")


def escape_mdv2(text):
    return MDV2_SPECIAL.sub(r"\\\1", text)


def to_markdown_v2(text):
    """Render the report for Telegram, with the emphasis put in here.

    Legacy Markdown has no escape character, so a single unpaired "_" anywhere
    in the message is a syntax error for the whole message. On 2026-09-09 the
    commit subject "Build config: dart_defines from production.env" carried
    exactly one, Telegram answered "Can't find end of the entity starting at
    byte offset 896" — the byte of that underscore — and the send fell back to
    plain text. The report arrived with every asterisk showing raw and nothing
    bold, which reads as "the formatting is broken", and it hid a repair that
    had in fact worked.

    So: escape everything as MarkdownV2, then add the two emphases that are ours
    to add — the title, and each project header. A commit subject can then hold
    any character it likes, because none of them are markup any more.

    The input must be unescaped text. This is not idempotent and cannot be: a
    report legitimately containing a backslash has to have it escaped, so
    escaped output is a different kind of value from source text, not a fixed
    point.
    """
    out = []
    for i, line in enumerate(text.split("\n")):
        stripped = line.strip()
        header = RAW_HEADER.fullmatch(stripped) or (i == 0 and stripped.startswith("📋"))
        out.append(f"*{escape_mdv2(stripped)}*" if header and stripped else escape_mdv2(line))
    return "\n".join(out)


# Telegram rejects a message over 4096 characters. Escaping only inflates the
# text — every "." and "-" gains a backslash — so a busy day that fitted before
# can stop fitting exactly when the report matters most.
TELEGRAM_LIMIT = 4096


def tg_len(text):
    """Length as Telegram counts it: UTF-16 code units, not code points.

    The 📋 in the title is one Python character and two of these. Counting
    Python characters gives a budget that is quietly too generous for exactly
    the reports that carry emoji, which is all of them.
    """
    return len(text.encode("utf-16-le")) // 2


def fit_telegram(text, limit=TELEGRAM_LIMIT):
    """Trim the report to what Telegram will accept, on a boundary that reads.

    Trimming happens BEFORE escaping, never after: an escape is a two-character
    pair, and a cut landing between the backslash and its character leaves a
    dangling backslash — which Telegram rejects, which is the very failure this
    module exists to remove, reintroduced by its own guard.

    Whole project blocks go first, because half a project is worse than a named
    omission. If one block alone is too big, that block is cut by line.
    """
    # Measured on the text a reader sees, not on the payload.
    #
    # Telegram applies the limit after it parses entities, so the backslashes
    # and the emphasis asterisks this module adds do not count toward it. An
    # earlier revision measured the escaped payload and then the rendered one;
    # both trim reports that Telegram would have accepted, and on a subject full
    # of full stops the escape inflates the count by a tenth or more.
    #
    # The failure modes are not symmetrical, which is why this is worth getting
    # right rather than being conservative: trimming early silently drops a
    # project from the report, while measuring too generously produces a
    # rejection that the plain-text retry below already handles.
    def payload(t):
        return tg_len(t)

    marker = "\n\n… trimmed to fit Telegram; the published version is complete."
    if payload(text) <= limit:
        return text

    room = limit - payload(marker)

    # Split on project headers, not on blank lines. A blank line is wherever the
    # formatter felt like one — put one between two bullets and a "block" is
    # half a project, so half a project is what gets dropped.
    blocks, current = [], []
    for line in text.split("\n"):
        if RAW_HEADER.fullmatch(line.strip()) and current:
            blocks.append("\n".join(current).strip("\n"))
            current = [line]
        else:
            current.append(line)
    if current:
        blocks.append("\n".join(current).strip("\n"))

    kept = []
    for block in blocks:
        candidate = kept + [block]
        if payload("\n\n".join(candidate)) <= room:
            kept = candidate
            continue

        # This block does not fit whole. Cut it by line rather than dropping it:
        # an oversized first project used to leave the reader with a title and a
        # trim marker and no commits at all, because the by-line path could only
        # run when nothing had been kept — and a report always has a title.
        lines = block.split("\n")
        while lines and payload("\n\n".join(kept + ["\n".join(lines)])) > room:
            lines.pop()
        # If even its first line is too long, cut the line itself.
        if not lines:
            first = block.split("\n")[0]
            while first and payload("\n\n".join(kept + [first])) > room:
                first = first[:-1]
            lines = [first] if first else []
        if lines:
            kept.append("\n".join(lines))
        break  # nothing after an overflowing block can fit either

    return "\n\n".join(kept) + marker


def strip_telegram_markup(text):
    """The morning message is Telegram Markdown. X and wip.co are not.

    Only the asterisks go. An underscore in a commit subject is a character in
    an identifier, not italics: on 2026-09-09 this deleted the one in
    "Build config: dart_defines from production.env", and the X post would have
    read "dartdefines". The formatter is asked for *bold* and rarely writes
    _italics_, so deleting every underscore to catch a case that mostly does not
    happen costs more than it saves.
    """
    out = []
    for line in text.splitlines():
        bare = line.strip()
        # Asterisks are removed only where they can only be markup: the title,
        # and a project header, both of which are re-emphasised downstream
        # anyway. Everywhere else an asterisk is a character somebody committed
        # — "*.rb", "2 * 3" — and deleting it is the same data loss as the
        # underscore this function exists to stop deleting.
        # Tested with the asterisks removed, so **#alpha** is recognised as the
        # header it is. FMT_HEADER allows one asterisk a side, and a formatter
        # that reaches for ** despite the prompt used to have its stars deleted
        # by the old blanket replace; matching on the bare token restores that
        # without deleting asterisks anywhere else.
        if bare.startswith("📋") or FMT_HEADER.fullmatch(bare.replace("*", "")):
            line = line.replace("*", "")
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


# A project block's first line IS the hashtag, optionally in Telegram bold.
# Deliberately not "a line that contains one": a bullet opening
# "\u2022 #123 was the culprit" would otherwise become a project and write "123"
# into the rotation history.
SLOT_HEADER = re.compile(r"\*?#([a-z0-9]+)\*?")
DATE_KEY = re.compile(r"\d{4}-\d{2}-\d{2}")


def _lead_files():
    """Resolved at call time, never at import: selftest rebinds STATE_DIR."""
    return STATE_DIR / "lead-history.json", STATE_DIR / "lead-history.lock"


@contextlib.contextmanager
def _lead_lock():
    """Yields True when the lock is held, False when it could not be taken.

    A caller that gets False must read nothing and write nothing. Carrying on
    unlocked would let two processes overwrite each other's history, which is
    the whole reason the lock is here — and losing a day of rotation is a much
    smaller price than a corrupted one.

    The lock lives on a sidecar that is never replaced. Locking the JSON file
    itself would not work: the atomic write installs a new inode, so the next
    process would lock a different file and the two updates would race.
    """
    _, lock_path = _lead_files()
    handle = None
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        handle = open(lock_path, "a+")
        fcntl.flock(handle, fcntl.LOCK_EX)
    except Exception as e:  # noqa: BLE001 - a lock we cannot take must not stop a publish
        warn(f"lead rotation lock unavailable: {e}")
        if handle is not None:
            with contextlib.suppress(Exception):
                handle.close()
        handle = None
    try:
        yield handle is not None
    finally:
        if handle is not None:
            with contextlib.suppress(Exception):
                fcntl.flock(handle, fcntl.LOCK_UN)
            with contextlib.suppress(Exception):
                handle.close()


def _set_aside(path, keep=False):
    """Preserve an unusable file, so an overwrite is recoverable and not silent.

    Nanoseconds, not seconds: two renders in the same second would otherwise
    collide, the rename would fail, and the next write would replace the only
    copy of the broken file.
    """
    with contextlib.suppress(Exception):
        target = path.with_suffix(f".json.bad-{time.time_ns()}")
        shutil.copy2(path, target) if keep else path.rename(target)


def _read_history():
    """(decisions, last_led), always.

    Individual malformed entries are skipped rather than thrown away with the
    rest: one stray value must not erase every project's turn. But anything
    dropped means the next write loses it for good, so a copy is set aside
    first — the same promise as a file that cannot be parsed at all.
    """
    path, _ = _lead_files()
    try:
        raw = json.loads(path.read_text())
    except FileNotFoundError:
        return {}, {}
    except Exception:  # noqa: BLE001 - unreadable or not JSON
        raw = None
    if not isinstance(raw, dict):
        _set_aside(path)
        return {}, {}
    decisions = {k: v for k, v in (raw.get("decisions") or {}).items()
                 if isinstance(k, str) and DATE_KEY.fullmatch(k) and isinstance(v, str)} \
        if isinstance(raw.get("decisions"), dict) else {}
    last_led = {k: v for k, v in (raw.get("last_led") or {}).items()
                if isinstance(k, str) and isinstance(v, str) and DATE_KEY.fullmatch(v)} \
        if isinstance(raw.get("last_led"), dict) else {}
    kept = len(decisions) + len(last_led)
    present = sum(len(raw[k]) for k in ("decisions", "last_led")
                  if isinstance(raw.get(k), dict))
    malformed_section = any(k in raw and not isinstance(raw[k], dict)
                            for k in ("decisions", "last_led"))
    if malformed_section or kept != present:
        _set_aside(path, keep=True)
    return decisions, last_led


def _write_history(decisions, last_led):
    """Best effort. A rotation file we cannot write is not worth a lost publish."""
    path, _ = _lead_files()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps({"decisions": decisions, "last_led": last_led},
                                  ensure_ascii=False, indent=2))
        os.replace(tmp, path)
    except Exception as e:  # noqa: BLE001
        warn(f"could not write the lead rotation file: {e}")


def choose_lead(tags, seed, date):
    """Which project leads today: the one that has gone longest without leading.

    The lead slot is the promotion — X builds the link card from the first URL
    in the post — so drawing it at random every day was never fair. An
    independent draw clusters, and it did: one project led three mornings
    running while three others had never led at all.

    Pinned per date, because --preview renders this text at 07:30 and the
    publish re-renders it when the button is finally pressed, hours later. A
    preview that does not match what goes out is not an approval of anything.
    The pin is validated against today's projects: a second daily-standup.sh run
    the same morning rewrites the pending file, possibly with a different set.
    """
    with _lead_lock() as locked:
        if not locked:
            return None
        decisions, last_led = _read_history()
        pinned = decisions.get(date)
        if pinned in tags:
            return pinned
        # Never-led sorts first; the hashtag breaks the sort stably. Only the
        # group tied at the front is shuffled, and only with the date seed:
        # hash() and set order follow PYTHONHASHSEED, and preview and publish
        # are two processes.
        ranked = sorted(tags, key=lambda t: (last_led.get(t) or "", t))
        front_key = last_led.get(ranked[0]) or ""
        front = [t for t in ranked if (last_led.get(t) or "") == front_key]
        random.Random(seed).shuffle(front)
        lead = front[0]
        decisions[date] = lead
        _write_history(decisions, last_led)
        return lead


def should_record_lead(x_before, state, lead):
    """A turn is spent by a fresh X success on this press, and nothing else.

    Not the "already posted, skipped" path, and not a wip.co-only press: only X
    carries the link card that makes the lead slot worth having.
    """
    return bool(not x_before and state.get("posted_x") and lead.get("tag"))


def record_lead(date, project):
    """Mark the turn as spent. Only after X actually accepted the post.

    A standup that is previewed and never approved, or whose publish fails, must
    not consume a project's turn. A wip.co-only press records nothing: only X
    has the card that makes the lead slot worth anything.
    """
    if not (DATE_KEY.fullmatch(date or "") and project):
        return
    with _lead_lock() as locked:
        if not locked:
            return
        decisions, last_led = _read_history()
        # Never backwards: pending_states() can publish an older day after a
        # newer one, and an older date here would make that project look
        # least-recently-led and lead again tomorrow.
        if (last_led.get(project) or "") >= date:
            return
        last_led[project] = date
        _write_history(decisions, last_led)


def shuffle_projects(text, seed, lead_out=None):
    """Reorder the project blocks, the same way all day, differently each day.

    X builds the link card from the first URL in the tweet. The standup lists
    the projects in a stable order, so the same site was always first and the
    card carried the same image every morning.

    Seeded by the day on purpose: --preview renders this text hours before the
    button is pressed, and a preview that does not match what gets posted is
    not an approval of anything.

    Blocks with no hashtag — the title, the closing count — keep their place.

    `lead_out`, when given, receives the chosen hashtag under "tag". The caller
    needs it to record the turn afterwards, and it cannot be read back out of
    the finished text: for_x has replaced every hashtag with a name and a URL by
    then, so the key would never match.

    Nothing here may raise. This runs inside post_to_x, which catches nothing,
    and the update offset is already advanced by the time it does — so an
    exception would lose the press and the day. Any failure falls back to the
    plain seeded shuffle.
    """
    blocks = re.split(r"\n\s*\n", text)
    slots, tags = [], []
    for i, b in enumerate(blocks):
        m = SLOT_HEADER.fullmatch(b.split("\n")[0].strip())
        if m:
            slots.append(i)
            tags.append(m.group(1))
    picked = [blocks[i] for i in slots]

    lead = None
    random.Random(seed).shuffle(picked)
    try:
        if tags:
            lead = choose_lead(tags, seed, date=seed)
        if lead is not None and lead in tags:
            at = next(i for i, b in enumerate(picked)
                      if (m := SLOT_HEADER.fullmatch(b.split("\n")[0].strip()))
                      and m.group(1) == lead)
            picked.insert(0, picked.pop(at))
            if lead_out is not None:
                lead_out["tag"] = lead
    except Exception as e:  # noqa: BLE001 - fairness is never worth a lost day
        warn(f"lead rotation unavailable, falling back to the shuffle: {e}")

    for i, block in zip(slots, picked):
        blocks[i] = block
    return "\n\n".join(blocks)


def for_x(text, seed, lead_out=None):
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
    text = shuffle_projects(text, seed, lead_out=lead_out)
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


def post_to_x(text, seed, lead_out=None):
    text = for_x(text, seed, lead_out=lead_out)
    result = subprocess.run([BIRD, "tweet", text], capture_output=True, text=True, timeout=120)
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


def publish_pending(state, target, posters, save):
    """Post to each requested destination, writing down each success at once.

    The write has to happen after every individual post, not once at the end,
    because everything after a successful post can fail: the next destination,
    the status reply, the process. The update offset was already advanced before
    any of this ran, so a failure that loses the record also loses the press —
    and the next press starts again from "nothing has been posted". For X that
    means the same standup tweeted twice, and a duplicate on a public timeline
    is not something an apology undoes.

    So: post, remember, then move on. `save` is called with the state after each
    destination, and the caller decides where that goes.
    """
    lines = []
    for name, code, already, fn in posters:
        if target not in (code, "both"):
            continue
        if state.get(already):
            lines.append(f"✅ {name} — already posted, skipped")
            continue
        ok, detail = fn()
        state[already] = ok
        save(state)
        lines.append(f"{'✅' if ok else '❌'} {name} — {detail or 'posted'}")
    return lines


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


def _reset_rotation():
    """Every case starts from an empty history, or it passes for the wrong reason."""
    path, lock = _lead_files()
    path.unlink(missing_ok=True)
    lock.unlink(missing_ok=True)
    for bad in STATE_DIR.glob("lead-history.json.bad-*"):
        bad.unlink()


def selftest():
    """Isolated, always.

    STATE_DIR is bound at import, so setting STANDUP_STATE_DIR in here would do
    nothing. The 28-day loop below runs real dates, and without this rebind a
    test run writes fake projects into the live rotation file.
    """
    global STATE_DIR
    real, tmp = STATE_DIR, tempfile.mkdtemp(prefix="standup-selftest-")
    STATE_DIR = pathlib.Path(tmp)
    try:
        _selftest_body()
    finally:
        STATE_DIR = real
        shutil.rmtree(tmp, ignore_errors=True)


def _selftest_body():
    global STATE_DIR
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
    # A success must be on disk before the next thing that can fail runs.
    # Without that, X posting and wip.co failing loses the X success, and the
    # next press tweets the same standup again.
    saved = []
    st = {"id": "d"}
    def explode():
        raise RuntimeError("wip.co is down")
    # The exception is allowed to escape — the process dying is not the problem.
    # The problem would be it dying with the X success only in memory.
    try:
        publish_pending(
            st, "both",
            (("X", "x", "posted_x", lambda: (True, "https://x.com/i/1")),
             ("wip.co", "wip", "posted_wip", explode)),
            lambda s: saved.append(dict(s)),
        )
        raise AssertionError("the failing destination should have raised")
    except RuntimeError:
        pass
    assert saved and saved[0].get("posted_x") is True, \
        "the X success was not written down before wip.co was attempted"
    assert st["posted_x"] is True and "posted_wip" not in st, st

    # And the ordinary path still records both, and skips what is already done.
    saved.clear()
    st = {"id": "d", "posted_x": True}
    def must_not_run():
        raise AssertionError("a destination already posted must not be posted again")
    lines = publish_pending(
        st, "both",
        (("X", "x", "posted_x", must_not_run),
         ("wip.co", "wip", "posted_wip", lambda: (True, "ok"))),
        lambda s: saved.append(dict(s)),
    )
    assert any("already posted" in l for l in lines), lines
    assert st["posted_wip"] is True and saved[-1]["posted_wip"] is True

    # A destination not asked for is not touched.
    st = {"id": "d"}
    publish_pending(st, "wip",
                    (("X", "x", "posted_x", must_not_run),
                     ("wip.co", "wip", "posted_wip", lambda: (True, "ok"))),
                    lambda s: None)
    assert "posted_x" not in st, st

    # --- The 2026-09-09 underscore, both halves of it ---------------------
    subject = "• Build config: dart_defines from production.env"
    assert "dart_defines" in strip_telegram_markup(f"*#alpha*\n{subject}"), \
        "an underscore in an identifier is not italics"
    assert "*" not in strip_telegram_markup("*#alpha*"), "a header's asterisks are markup and do go"
    # But an asterisk in a commit subject is a character somebody committed.
    kept_star = strip_telegram_markup("*#alpha*\n• Rename every *.rb under lib/")
    assert "*.rb" in kept_star, kept_star
    assert "*#alpha*" not in kept_star and "#alpha" in kept_star, kept_star
    assert "\\*\\.rb" in to_markdown_v2(kept_star), "a literal asterisk must be escaped, not dropped"

    tg = to_markdown_v2(f"\U0001F4CB Daily Standup — 2026-09-09\n\n#alpha\n{subject}")
    assert "dart\\_defines" in tg, tg
    assert "*\\#alpha*" in tg, "a project header is bold"
    assert tg.splitlines()[0] == "*\U0001F4CB Daily Standup — 2026\\-09\\-09*", tg.splitlines()[0]
    assert "\\." in tg, "a full stop is reserved in MarkdownV2 and must be escaped"

    # Every reserved character, including a literal backslash. Four assertions
    # would not support "a commit subject can hold anything".
    for ch in "_*[]()~`>#+-=|{}.!\\":
        rendered = to_markdown_v2(f"• a subject with {ch} in it")
        assert f"\\{ch}" in rendered, f"{ch!r} was not escaped: {rendered!r}"

    # A bullet that opens with "#" is an issue reference, not a header. Headers
    # are re-detected by pattern after markup is stripped, so this is the
    # plausible false positive.
    issue = to_markdown_v2("#alpha\n• #123 was the culprit")
    assert issue.splitlines()[0].startswith("*"), "the header lost its emphasis"
    assert not issue.splitlines()[1].startswith("*"), "a bullet was turned into a header"

    # No idempotence assertion: escaping a raw backslash and treating escaped
    # output as already-escaped are mutually exclusive, and the loop above
    # requires the former.

    # The CLI composes these three, and only the pieces were tested. A header
    # arrives from the formatter as *#alpha*, and must survive stripping and
    # come back bold — with its "#" escaped, which is what the earlier
    # by-hand rendering got wrong.
    cli = to_markdown_v2(fit_telegram(strip_telegram_markup(
        "\U0001F4CB Daily Standup — 2026-09-09\n\n*#alpha*\n• one dart_defines here")))
    assert "*\\#alpha*" in cli, cli
    assert "dart\\_defines" in cli, cli
    assert "**" not in cli, "the formatter's asterisks were not stripped first"

    # --- The length guard --------------------------------------------------
    small = "\U0001F4CB Daily Standup\n\n#alpha\n• one\n\n#beta\n• two"
    assert fit_telegram(small) == small, "a report that fits must not be touched"

    big = "\U0001F4CB Daily Standup\n\n" + "\n\n".join(
        f"#p{i}\n" + "\n".join(f"• a commit subject, number {j}." for j in range(20))
        for i in range(30))
    trimmed = fit_telegram(big)
    rendered = to_markdown_v2(trimmed)
    assert tg_len(trimmed) <= TELEGRAM_LIMIT, tg_len(trimmed)
    assert "trimmed to fit Telegram" in trimmed, "a trim has to say so"
    assert not re.search(r"(?<!\\)\\$", rendered), "the render ends in a dangling escape"
    # Trimming drops whole projects, never half of one.
    assert trimmed.count("#p0") == 1 and "• a commit subject, number 19." in trimmed

    # Escapes and emphasis are entities, not text: a report whose escaped form
    # is over the limit but whose visible text is not must go out untouched.
    dotted = "\U0001F4CB Daily Standup\n\n#alpha\n" + "\n".join(
        "• a subject. with. a lot. of. full. stops." for _ in range(90))
    assert tg_len(dotted) < TELEGRAM_LIMIT < tg_len(escape_mdv2(dotted)), \
        "the fixture must be legal as text and over the limit once escaped"
    assert fit_telegram(dotted) == dotted, \
        "a report Telegram would accept was trimmed because the escape was measured"

    # One block larger than the whole budget still has to come back inside it.
    single = "#solo\n" + "\n".join(f"• subject number {j}." for j in range(600))
    assert tg_len(fit_telegram(single)) <= TELEGRAM_LIMIT

    # The case opencode found: a title, then a first project bigger than the
    # whole budget. The by-line cut used to be unreachable once anything had
    # been kept, so the reader got a title and a marker and no commits.
    fat = ("\U0001F4CB Daily Standup\n\n#alpha\n"
           + "\n".join(f"• subject number {j}, with some words." for j in range(300))
           + "\n\n#beta\n• a later project")
    cut = fit_telegram(fat)
    assert tg_len(cut) <= TELEGRAM_LIMIT, tg_len(cut)
    assert "subject number 0" in cut, "the oversized project was dropped, not cut"
    assert cut.count("•") > 20, f"only {cut.count(chr(8226))} bullets survived"

    # A blank line inside a project is not a project boundary. Splitting on one
    # drops half a project and keeps the rest.
    spaced = ("\U0001F4CB Daily Standup\n\n#alpha\n• one\n\n• two after a blank line\n\n"
              + "\n\n".join(f"#p{i}\n" + "\n".join(f"• filler {j} here." for j in range(40))
                             for i in range(20)))
    trimmed_spaced = fit_telegram(spaced)
    if "#alpha" in trimmed_spaced:
        assert "• two after a blank line" in trimmed_spaced, \
            "a project was split at a blank line and half of it dropped"

    # A header the formatter wrote with double asterisks.
    assert strip_telegram_markup("**#alpha**\n• one").startswith("#alpha"), \
        "a **bold** header kept its asterisks"
    assert "*\\#alpha*" in to_markdown_v2(strip_telegram_markup("**#alpha**\n• one")), \
        "a **bold** header was not re-emphasised"

    # And one LINE longer than the budget is cut, not dropped: dropping it left
    # a message consisting of the trim marker and nothing else.
    overlong = "• " + "a very long subject. " * 400
    fitted = fit_telegram(overlong)
    assert tg_len(fitted) <= TELEGRAM_LIMIT, tg_len(fitted)
    assert "a very long subject" in fitted, "the only line was dropped instead of cut"

    # ---- lead rotation ----------------------------------------------------
    three = ("\U0001F4CB Daily Standup\n\n#alpha\n\u2022 one\n\n"
             "#beta\n\u2022 two\n\n#gamma\n\u2022 three\n\n3 projects")

    def lead_of(rendered):
        for block in re.split(r"\n\s*\n", rendered):
            m = SLOT_HEADER.fullmatch(block.split("\n")[0].strip())
            if m:
                return m.group(1)
        return None

    # A render pins the day and leaves last_led alone: previewing is not publishing.
    _reset_rotation()
    out = {}
    first = shuffle_projects(three, "2026-09-20", lead_out=out)
    decisions, last_led = _read_history()
    assert decisions == {"2026-09-20": out["tag"]}, decisions
    assert last_led == {}, "a render must not spend a turn"
    assert lead_of(first) == out["tag"], (first, out)

    # The same day renders the same order and rewrites nothing.
    lead_path, _ = _lead_files()
    before = lead_path.read_bytes()
    assert shuffle_projects(three, "2026-09-20") == first, "one day, one order"
    assert lead_path.read_bytes() == before, "a repeat render must not rewrite the file"

    # Only record_lead spends the turn, and only for the project handed to it.
    record_lead("2026-09-20", out["tag"])
    _, last_led = _read_history()
    assert last_led == {out["tag"]: "2026-09-20"}, last_led

    # Yesterday's leader does not lead today.
    second = {}
    shuffle_projects(three, "2026-09-21", lead_out=second)
    assert second["tag"] != out["tag"], (out, second)

    # Over many days everyone leads, and nobody leads twice running.
    _reset_rotation()
    seen, previous = [], None
    for d in range(1, 16):
        day = f"2026-10-{d:02d}"
        got = {}
        shuffle_projects(three, day, lead_out=got)
        record_lead(day, got["tag"])
        assert got["tag"] != previous, f"{day} repeated {previous}"
        previous = got["tag"]
        seen.append(got["tag"])
    assert set(seen) == {"alpha", "beta", "gamma"}, seen

    # A project that is not in today's standup is skipped, and is not marked led
    # even once the day is actually recorded.
    _reset_rotation()
    two = "\U0001F4CB Daily Standup\n\n#alpha\n\u2022 one\n\n#beta\n\u2022 two"
    got = {}
    shuffle_projects(two, "2026-11-01", lead_out=got)
    assert got["tag"] in ("alpha", "beta"), got
    record_lead("2026-11-01", got["tag"])
    _, last_led = _read_history()
    assert "gamma" not in last_led, last_led
    assert last_led == {got["tag"]: "2026-11-01"}, last_led

    # record_lead credits what it is handed, never what the file happens to say.
    # The old shape of this test recorded the same project the pin already
    # named, so a regression to reading decisions[D] would have passed.
    _reset_rotation()
    _write_history({"2026-11-09": "delta"}, {})
    record_lead("2026-11-09", "alpha")
    _, last_led = _read_history()
    assert last_led == {"alpha": "2026-11-09"}, last_led

    # The gate in main(): only a fresh X success on this press spends a turn.
    assert should_record_lead(False, {"posted_x": True}, {"tag": "alpha"})
    assert not should_record_lead(True, {"posted_x": True}, {"tag": "alpha"}), \
        "an already-posted X must not spend the turn again"
    assert not should_record_lead(False, {"posted_wip": True}, {"tag": "alpha"}), \
        "a wip.co-only press must not spend a turn"
    assert not should_record_lead(False, {"posted_x": True}, {}), \
        "no lead captured means nothing to record"

    # A malformed section keeps what is still good, and leaves a copy behind.
    _reset_rotation()
    lead_path, _ = _lead_files()
    lead_path.write_text(json.dumps({"decisions": [], "last_led": {"alpha": "2026-01-01"}}))
    decisions, last_led = _read_history()
    assert decisions == {} and last_led == {"alpha": "2026-01-01"}, (decisions, last_led)
    assert list(STATE_DIR.glob("lead-history.json.bad-*")), "a dropped section must be kept"

    # So does a value that is not a date.
    _reset_rotation()
    lead_path.write_text(json.dumps({"decisions": {}, "last_led": {"alpha": "nope"}}))
    decisions, last_led = _read_history()
    assert last_led == {}, last_led
    assert list(STATE_DIR.glob("lead-history.json.bad-*")), "a dropped value must be kept"

    # A lock that cannot be taken must read nothing and write nothing. Carrying
    # on unlocked is how two processes overwrite each other.
    _reset_rotation()
    real_flock = fcntl.flock
    fcntl.flock = lambda *a, **k: (_ for _ in ()).throw(OSError("no lock for you"))
    try:
        assert choose_lead(["alpha", "beta"], "2026-11-11", date="2026-11-11") is None
        record_lead("2026-11-11", "alpha")
        assert not lead_path.exists(), "nothing may be written without the lock"
        blind = {}
        rendered = shuffle_projects(three, "2026-11-11", lead_out=blind)
        assert sorted(HASHTAG.findall(rendered)) == ["alpha", "beta", "gamma"], rendered
        assert blind == {}, "no lead may be claimed without the lock"
    finally:
        fcntl.flock = real_flock

    # Never-led beats led-long-ago.
    _reset_rotation()
    _write_history({}, {"alpha": "2020-01-01", "beta": "2020-01-02"})
    got = {}
    shuffle_projects(three, "2026-11-02", lead_out=got)
    assert got["tag"] == "gamma", got

    # last_led never moves backwards: pending_states() can publish an older day
    # after a newer one, and the older date would hand that project the lead again.
    _reset_rotation()
    record_lead("2026-11-10", "alpha")
    record_lead("2026-11-05", "alpha")
    _, last_led = _read_history()
    assert last_led["alpha"] == "2026-11-10", last_led

    # A pin naming a project that is not here today is ignored, not obeyed.
    _reset_rotation()
    _write_history({"2026-11-03": "delta"}, {})
    got = {}
    shuffle_projects(three, "2026-11-03", lead_out=got)
    assert got["tag"] in ("alpha", "beta", "gamma"), got

    # An unusable file is moved aside, and the render still returns every block.
    _reset_rotation()
    lead_path, _ = _lead_files()
    lead_path.write_text("{ not json")
    rendered = shuffle_projects(three, "2026-11-04")
    assert sorted(HASHTAG.findall(rendered)) == ["alpha", "beta", "gamma"], rendered
    assert list(STATE_DIR.glob("lead-history.json.bad-*")), "the bad file must be kept"

    # A first line that merely mentions a hashtag is not a project header.
    assert lead_of("\u2022 #123 was the culprit\n\u2022 two") is None

    # Shapes that must not explode.
    _reset_rotation()
    assert shuffle_projects("#solo\n\u2022 one", "2026-11-06").startswith("#solo")
    assert shuffle_projects("no projects here", "2026-11-07") == "no projects here"

    # A state directory it cannot write still renders, raises nothing, and says
    # nothing on stdout — stdout is the tweet.
    _reset_rotation()
    blocked = STATE_DIR / "afile"
    blocked.write_text("not a directory")
    saved_dir = STATE_DIR
    STATE_DIR = blocked / "nested"
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rendered = shuffle_projects(three, "2026-11-08")
        assert sorted(HASHTAG.findall(rendered)) == ["alpha", "beta", "gamma"], rendered
        assert buf.getvalue() == "", f"nothing may reach stdout: {buf.getvalue()!r}"
    finally:
        STATE_DIR = saved_dir

    # Two processes, two hash seeds, one lead. The tie-break must not follow
    # PYTHONHASHSEED: --preview and the publish are different interpreters, and
    # on a day when every project ties they must still agree. Each child gets its
    # own empty history, or the pin would decide it for them.
    driver = ("import importlib.util,sys;"
              "spec=importlib.util.spec_from_file_location('sp',sys.argv[1]);"
              "m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);"
              "out={};m.shuffle_projects(sys.argv[2],'2026-12-01',lead_out=out);"
              "print(out.get('tag',''))")
    picks = []
    for hash_seed in ("0", "12345"):
        box = tempfile.mkdtemp(prefix="standup-tie-")
        try:
            child = subprocess.run(
                [sys.executable, "-c", driver, __file__, three],
                capture_output=True, text=True, timeout=60,
                env=dict(os.environ, PYTHONHASHSEED=hash_seed, STANDUP_STATE_DIR=box))
            assert child.returncode == 0, child.stderr[:300]
            picks.append(child.stdout.strip())
        finally:
            shutil.rmtree(box, ignore_errors=True)
    assert picks[0] and picks[0] == picks[1], f"the tie-break follows the hash seed: {picks}"

    print("selftest ok")


def main():
    # The morning message shows the wip.co form, where the hashtags do the
    # attaching. What goes to X is a different text, and approving a text you
    # cannot see is not approving anything: --preview renders it.
    if "--preview" in sys.argv:
        pending = sys.argv[sys.argv.index("--preview") + 1]
        state = json.loads((STATE_DIR / f"pending-{pending}.json").read_text())
        print(for_x(strip_telegram_markup(state["text"]), pending))
        return

    # Reads the report on stdin and writes what Telegram should receive. Kept
    # out of the state file on purpose: X and wip.co get the unescaped text, and
    # backslashes are not prose.
    if "--telegram-markdown" in sys.argv:
        sys.stdout.write(to_markdown_v2(fit_telegram(strip_telegram_markup(sys.stdin.read()))))
        return

    # The same text, trimmed but not escaped: what the plain-text retry should
    # send. Without it a report over the limit plus a renderer failure means no
    # message arrives at all, which is the busy day fit_telegram exists for.
    if "--telegram-plain" in sys.argv:
        sys.stdout.write(fit_telegram(strip_telegram_markup(sys.stdin.read())))
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

        # Each destination is remembered on its own, the moment it succeeds, so
        # a half-done day — X posted, wip.co refused — is retryable without
        # tweeting it twice.
        # The hashtag that led, caught on the way past. It cannot be read back
        # out of the finished text: for_x has already replaced every hashtag
        # with a project name and a URL by then.
        lead = {}
        x_before = bool(state.get("posted_x"))
        lines = publish_pending(
            state, target,
            (("X", "x", "posted_x", lambda: post_to_x(text, key, lead_out=lead)),
             ("wip.co", "wip", "posted_wip", lambda: post_to_wip(text))),
            lambda s: path.write_text(json.dumps(s, ensure_ascii=False, indent=2)),
        )

        # Only a fresh X success spends the turn — not the "already posted,
        # skipped" path, and not a wip.co-only press.
        if should_record_lead(x_before, state, lead):
            record_lead(key, lead["tag"])

        log(f"[{key}] " + " | ".join(lines))

        # Only once nothing is left to retry. Everything below here can fail
        # without costing anything, because the file already says what happened.
        if state.get("posted_x") and state.get("posted_wip"):
            path.unlink(missing_ok=True)

        telegram(token, "sendMessage", chat_id=state["chat_id"],
                 reply_to_message_id=state["message_id"],
                 text="\n".join(lines))


if __name__ == "__main__":
    main()
