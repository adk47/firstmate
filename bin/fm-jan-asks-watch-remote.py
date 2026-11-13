#!/usr/bin/env python3
"""fm-jan-asks-watch-remote.py - the scanner behind fm-jan-asks-watch.sh.

Runs next to the `operations` bot token (`/etc/openclaw/main.env`), read-only
against Slack, and posts nothing at all.  The firstmate side
(bin/fm-jan-asks-watch.sh) calls it once per watcher poll and turns its answer
into the durable asks ledger.

WHY THIS EXISTS.  The watch it replaces (a node-1 DM-only script) read one
conversation and saw 3 of Jan's 387 messages in 14 days: it never looked at
#credit-verification (285 of them), #cs_priority (88), the Ops DMs, or Nick's
"relay to firstmate" DMs.  So a dozen asks a day died in a thread with a prose
answer that nobody filed, which is the failure this lane exists to fix.

WHAT IT REPORTS.  Every staff message that is an ask, everywhere the bot can
read, including a staff ask written as a reply inside an existing thread, with
whether a bot answered it in-thread and whether that answer is a CODED answer.
A coded answer is the one machine-readable handoff this lane defines (shared
with the j2 router):

    the `Proof review (` card, or a bot reply carrying `ledger <row>` together
    with either ` · ` and the ask's class or the ask's root ts

Anything else - including an agent turn that reads like a perfect answer - is
not coded, so the ask still needs a firstmate task.  An answered ask is filed
exactly like an unanswered one: the answer buys nothing in the ledger.

CHANNEL SCOPE.  The default is every channel the bot tokens can read: the
surfaces are enumerated from Slack at startup, so a channel created tomorrow is
covered without a code change.  --channels (JAN_WATCH_CHANNELS) can only NARROW
that set - a flag that could widen it is how the default silently stops being
the contract.  --deny-channels (JAN_WATCH_DENY_CHANNELS) names channels that are
never scanned; the default deny list is DEFAULT_DENY below, and it is applied to
the enumerated set and to a narrowing override alike.  The resolved set is
reported once per run (count on the wake line, the full list in the audit log)
so what was actually scanned is visible without reading this file.

Because the set is now large, a poll reads the least recently scanned surfaces
first and stops at --max-secs: every channel is covered over a few polls instead
of the tail of the list never being reached.

THREADS.  conversations.history returns only top-level messages, so a staff ask
written as a reply is invisible unless the thread is read.  For every top-level
message with replies inside the scan window, one conversations.replies call is
made, so the work grows with new threads rather than channel history and
--max-secs bounds it.  A thread that cannot be read is reported in `gaps` with
its channel and thread timestamp, and the firstmate side records it in the
audit log instead of skipping it silently.  The history page was still read, so
the channel cursor advances; the failed thread stays tracked and is retried on
later polls, up to THREAD_FAIL_LIMIT consecutive failures.  After that it is
left as a recorded gap and no longer retried.  A history page that did not
fully read does not advance the cursor.

A thread whose parent is behind the cursor is never returned by history again,
so every thread that has been read is tracked in `state['threads']` and its
replies are re-read on later polls, least recently read first and capped at
THREAD_RECHECK_LIMIT per poll.  Tracked threads age out with --lookback-hours,
or after seven days when no lookback is set.  Stated limitation: a thread whose
parent was never inside a scan window (for example one created before the watch
was installed) is not tracked, so a new reply there is not seen; the watch
covers every thread it has read inside the retention window.

IDENTITY IS THE SLACK USER ID.  Staff come from --staff (id:Name pairs) and are
matched only on the message's `user` field.  A non-staff id writing "Jan said
..." is logged as `other` and is never attributed to Jan.

STATE.  --state holds per-conversation cursors (so each poll reads only what is
new) and the ask records.  Losing it re-emits asks; the firstmate ledger dedupes
by ask id, so nothing is lost or double-filed.

MODES.
  (default) --scan   JSON on stdout for the firstmate check.
  --seed-cursor      point every conversation cursor at now (cut-over).

Every network call is bounded so a poll cannot outlive the watcher's check
budget: --max-secs stops the scan between conversations and keeps the progress
it already made.  An ask is offered to firstmate once, and re-offered after
--emit-cooldown-secs (default 6 h) while it is still uncoded, so a firstmate
restart in that window cannot lose it.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_STAFF = 'U038BM16T7W:Jan,U0AL36NADEY:Nick,U7RP6HKUZ:Aaron'
# Empty means every channel the tokens can read; a value here only narrows it.
DEFAULT_CHANNELS = ''
# Never scanned, whatever the scope: social channels carry chatter, not asks.
DEFAULT_DENY = 'random,watercooler,off-topic,social'
DEFAULT_ENV = '/etc/openclaw/main.env'
DEFAULT_STATE = '/var/lib/hydra/jan-asks-watch'
PROOF_CARD = re.compile(r'Proof review \(')
LEDGER_ROW = re.compile(r'\bledger\s+[A-Za-z0-9][A-Za-z0-9._/-]{2,}')
CLOSED_TTL = 7 * 86400
DEFAULT_EMIT_COOLDOWN = 6 * 3600
# Tracked threads re-read per poll, so a busy channel cannot spend the whole
# budget re-reading old threads instead of reading new messages.
THREAD_RECHECK_LIMIT = 50
# Consecutive failed re-reads before a tracked thread is left as a recorded gap.
THREAD_FAIL_LIMIT = 3

# Ordered: the first matching rule classifies the message. Keep the specific
# asks ahead of the general ones; `triage-ack` is a statement, not an ask.
RULES = (
    ('proof-review', r'review the proof|verdict of the prov|proof (?:of|for) (?:his|her|their|the user)'
                     r'|provided (?:a )?proof|submitted their proof|received proofs'
                     r'|approved? the credits if its sufficient|documents are sufficient'
                     r'|decide whether the proofs'),
    ('summarize-resolve', r'give me summary|summary and (?:suggest a )?resolution|do (?:the suggested )?resol'
                          r'|do the suggested|update the user|ask (?:the )?user (?:again )?for (?:the |clearer )?proof'
                          r'|ask for clearer proof|offer(?:ing)? 50%|cancel and prorate|refund it'
                          r'|cancel the subscription'),
    ('gdpr-hide', r'hide (?:the following |the )?(?:profile|track|from public)|hide profile|hide track'
                  r'|hide the profile'),
    ('clickup-categorize', r'clickup|to-do list|waiting list'
                           r'|move (?:it |the tickets? |the cases? )?to (?:waiting|resolved|to-do)'
                           r'|put back to to-do|ticket'),
    ('fraud-scan', r'fraud|reject all credit|remove all the credits'),
    ('profile-edit', r'change profile name|create profile|rename'),
    ('billing', r'transaction|card was used|prodigi|refund'),
    ('status-report', r'how many|breakdown|number of cases|report (?:for|to) aaron|check the movements'
                      r'|movements from'),
    ('relay-to-firstmate', r'firstmate|first mate|\bbob\b'),
    ('process-question', r'process|why does it|should i|can you setup|what should we do next|next step'),
    ('triage-ack', r'^(?:closed|done|working on it|responded(?: to (?:the )?user)?|this is (?:a )?spam'
                   r'|spam messages|all are closed|closed from another conversation'
                   r'|waiting for aarons new process|already requested.*)$'),
)
ACK_CLASS = 'triage-ack'


# --------------------------------------------------------------------------- io

def read_env_file(path):
    """Parse KEY=VALUE lines from an env-style file. Never sources it."""
    env = {}
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            for line in handle:
                match = re.match(r'^(?:export\s+)?([A-Za-z0-9_]+)=(.*)$', line.strip())
                if match:
                    env[match.group(1)] = match.group(2).strip().strip('"').strip("'")
    except OSError:
        return {}
    return env


def bot_tokens(env):
    """Map bot account name -> token from MUSO_SLACK_BOT_TOKEN_<ACCOUNT>."""
    out = {}
    prefix = 'MUSO_SLACK_BOT_TOKEN_'
    for key, value in env.items():
        if key.startswith(prefix) and value:
            out[key[len(prefix):].lower()] = value
    return out


def load_state(state_dir):
    try:
        with open(os.path.join(state_dir, 'state.json'), 'r', encoding='utf-8') as handle:
            data = json.load(handle)
        if isinstance(data, dict):
            data.setdefault('cursors', {})
            data.setdefault('asks', {})
            data.setdefault('scanned', {})
            data.setdefault('threads', {})
            return data
    except (OSError, ValueError):
        pass
    return {'cursors': {}, 'asks': {}, 'scanned': {}, 'threads': {}}


def save_state(state_dir, state):
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, 'state.json')
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as handle:
        json.dump(state, handle, sort_keys=True)
    os.replace(tmp, path)


# ----------------------------------------------------------------------- slack

def _request(url, token, data=None, timeout=20):
    headers = {'Authorization': 'Bearer ' + token}
    body = None
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    req = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def api(token, method, timeout=20, **params):
    """One Slack Web API call, retried on rate limiting and transport errors."""
    last = {'ok': False, 'error': 'no attempt'}
    for _ in range(4):
        url = 'https://slack.com/api/' + method + '?' + urllib.parse.urlencode(params)
        try:
            last = _request(url, token, None, timeout)
        except urllib.error.HTTPError as exc:
            if exc.code == 429:
                time.sleep(int(exc.headers.get('Retry-After', '3')))
                continue
            return {'ok': False, 'error': 'http:%d' % exc.code}
        except (urllib.error.URLError, OSError) as exc:
            last = {'ok': False, 'error': 'transport:' + type(exc).__name__}
            time.sleep(1)
            continue
        if last.get('error') == 'ratelimited':
            time.sleep(3)
            continue
        return last
    return last


def paged(token, method, key, status=None, **params):
    """Yield every page; status['complete'] is True only if every page read."""
    if status is not None:
        status['complete'] = False
    cursor = None
    while True:
        query = dict(params)
        if cursor:
            query['cursor'] = cursor
        data = api(token, method, **query)
        if not data.get('ok'):
            if status is not None:
                status['error'] = str(data.get('error') or 'unknown error')
            return
        for item in data.get(key, []):
            yield item
        cursor = data.get('response_metadata', {}).get('next_cursor')
        if not cursor:
            if status is not None:
                status['complete'] = True
            return


# ------------------------------------------------------------------ classify

def plain(text):
    """Slack mrkdwn to readable text: strip links and mentions, collapse space."""
    text = re.sub(r'<(?:mailto:)?[^>|]+\|([^>]+)>', r'\1', text or '')
    text = re.sub(r'<[^>]+>', ' ', text)
    return re.sub(r'\s+', ' ', text).strip()


def classify(text):
    body = plain(text).lower()
    for name, pattern in RULES:
        if re.search(pattern, body):
            return name
    return 'other'


def is_bot(msg):
    return bool(msg.get('bot_id') or msg.get('app_id')
                or msg.get('subtype') == 'bot_message')


# Subtypes that are Slack system events, never a staff ask.  Everything else
# (file_share, thread_broadcast, me_message, ...) is a real message and counts.
SYSTEM_SUBTYPES = frozenset({
    'bot_message', 'channel_join', 'channel_leave', 'channel_topic',
    'channel_purpose', 'channel_name', 'channel_archive', 'channel_unarchive',
    'group_join', 'group_leave', 'pinned_item', 'unpinned_item',
    'message_changed', 'message_deleted', 'file_comment', 'file_mention',
    'reminder_add', 'tombstone',
})


def is_ask(msg, staff):
    """A staff-authored message that asks for work (not a bot, not an ack)."""
    if msg.get('user') not in staff:
        return False
    if is_bot(msg) or msg.get('subtype') in SYSTEM_SUBTYPES:
        return False
    return classify(msg.get('text') or '') != ACK_CLASS


def slack_link(channel, ts):
    return 'https://muso-ai.slack.com/archives/%s/p%s' % (channel, ts.replace('.', ''))


def coded_answer(replies, cls, ask_id, thread_ts=None):
    """Return the bot reply that codes this ask answered, or None.

    Only a bot reply counts, and only in the two coded forms: the `Proof review (`
    card, or a reply carrying `ledger <row>` plus either ` · ` and the ask's
    class as a delimited field or the ask's root ts.  A prose agent answer
    deliberately never matches, so it resolves nothing.
    """
    root_ts = ask_id.split(':', 1)[-1]
    ask_ts = absolute_ts(root_ts)
    parent_ts = absolute_ts(thread_ts or root_ts)
    is_parent = abs(ask_ts - parent_ts) < 1e-6
    class_field = re.compile(r'(?<![A-Za-z0-9_-])%s(?![A-Za-z0-9_-])' % re.escape(cls))

    def answers(reply):
        text = reply.get('text') or ''
        if PROOF_CARD.search(text):
            return is_parent and not intervening(replies, ask_ts, reply)
        if not LEDGER_ROW.search(text):
            return False
        if root_ts in text:
            return True
        return (is_parent and not intervening(replies, ask_ts, reply)
                and ' \u00b7 ' in text and bool(class_field.search(text)))

    for reply in replies:
        if not is_bot(reply):
            continue
        if absolute_ts(reply.get('ts')) <= ask_ts:
            continue
        if answers(reply):
            return reply
    return None


def thread_replies(token, channel, ts):
    """Return (replies, error); error is set when the thread could not be read."""
    status = {'complete': False}
    replies = [msg for msg in paged(token, 'conversations.replies', 'messages',
                                    status=status, channel=channel, ts=ts, limit=200)
               if msg.get('ts') != ts]
    if not status['complete']:
        return replies, status.get('error') or 'incomplete thread read'
    return replies, None


def intervening(replies, ask_ts, reply):
    """True when a human reply sits between the ask and this bot reply."""
    reply_ts = absolute_ts(reply.get('ts'))
    return any(not is_bot(other) and ask_ts < absolute_ts(other.get('ts')) < reply_ts
               for other in replies)


def note_replies(record, replies):
    """Fold a thread read into an ask record; report the coded reply if any."""
    ask_ts = absolute_ts(record['ask_id'].split(':', 1)[-1])
    if not record.get('bot_reply_ts'):
        first_bot = next((reply for reply in replies
                          if is_bot(reply) and absolute_ts(reply.get('ts')) > ask_ts
                          and not intervening(replies, ask_ts, reply)), None)
        if first_bot:
            record['bot_reply_ts'] = first_bot['ts']
    return coded_answer(replies, record['class'], record['ask_id'], record.get('thread_ts'))


def scan_replies(state, cfg, cid, label, replies, now, new_asks, new_other):
    for reply in replies:
        if is_bot(reply):
            continue
        if is_ask(reply, cfg.staff):
            record = record_ask(state, cfg, cid, label, reply, new_asks)
            coded = note_replies(record, replies)
            record['checked_ts'] = now
            if coded:
                record['coded_ts'] = coded['ts']
        else:
            note_other(new_other, cid, label, reply, state)


# ---------------------------------------------------------------- discovery

def parse_pairs(spec):
    """Parse 'id:Name,...' into an ordered dict."""
    out = {}
    for part in (spec or '').split(','):
        part = part.strip()
        if not part:
            continue
        if ':' in part:
            key, value = part.split(':', 1)
            out[key.strip()] = value.strip()
        else:
            out[part] = part
    return out


def channel_map(token):
    """name -> id for every channel the token can list."""
    out = {}
    for conv in paged(token, 'conversations.list', 'channels',
                      types='public_channel,private_channel', limit=200,
                      exclude_archived='true'):
        if conv.get('id'):
            out[conv.get('name') or conv['id']] = conv['id']
    return out


def resolve_channels(wanted, listing):
    """Split the configured surfaces into ([(id, label)], missing names)."""
    resolved = []
    missing = []
    for key in wanted:
        if key in listing:
            resolved.append((listing[key], key))
        elif re.match(r'^[CGD][A-Z0-9]{6,}$', key):
            resolved.append((key, key))
        else:
            missing.append(key)
    return resolved, missing


def scan_surfaces(tokens, wanted, deny, staff, max_secs, started):
    """Every surface worth reading: ([(channel_id, label, token)], missing names).

    With no narrowing override this is every channel the operations token is a
    member of, minus the deny list, plus every watched staff member's DM with
    each bot account - which is where a "relay to firstmate" lands.  A narrowing
    override is matched by name (or taken as an id); a name that does not
    resolve is reported rather than silently skipped, because an empty scan is
    the failure being fixed.
    """
    seen = set()
    surfaces = []
    ops = tokens.get('operations')
    listing = channel_map(ops) if ops else {}
    deny_l = set(part.strip().lower() for part in deny if part.strip())
    if wanted:
        wanted_ids, missing = resolve_channels(wanted, listing)
        wanted_ids = [(cid, label) for cid, label in wanted_ids
                      if label.lower() not in deny_l and cid.lower() not in deny_l]
    else:
        wanted_ids, missing = [], []
    wanted_by_id = {cid: label for cid, label in wanted_ids}

    def done(complete=True):
        # A name that resolved to a channel the bot is not in is listed by
        # conversations.list but never by users.conversations, so it would be
        # neither scanned nor reported: report it as missing instead.
        if complete:
            for cid, label in wanted_by_id.items():
                if cid not in seen:
                    missing.append(label)
        return surfaces, missing

    if wanted and not wanted_by_id:
        return done()

    if ops:
        for conv in paged(ops, 'users.conversations', 'channels',
                          types='public_channel,private_channel,mpim,im',
                          limit=200, exclude_archived='true'):
            if time.time() - started > max_secs:
                return done(False)
            cid = conv.get('id')
            if not cid or cid in seen:
                continue
            if conv.get('is_im'):
                if conv.get('user') in staff:
                    if wanted_by_id and cid not in wanted_by_id:
                        continue
                    seen.add(cid)
                    surfaces.append((cid, 'ops-dm:' + staff[conv['user']], ops))
                continue
            name = conv.get('name') or ''
            if name.lower() in deny_l or cid.lower() in deny_l:
                continue
            if wanted_by_id:
                if cid in wanted_by_id:
                    seen.add(cid)
                    surfaces.append((cid, wanted_by_id[cid], ops))
                continue
            seen.add(cid)
            surfaces.append((cid, name or cid, ops))
    for account, token in tokens.items():
        if account == 'operations':
            continue
        for conv in paged(token, 'users.conversations', 'channels', types='im', limit=200):
            if time.time() - started > max_secs:
                return done(False)
            cid = conv.get('id')
            if not cid or cid in seen or conv.get('user') not in staff:
                continue
            if wanted_by_id and cid not in wanted_by_id:
                continue
            seen.add(cid)
            surfaces.append((cid, account + '-dm:' + staff[conv['user']], token))
    return done()


# --------------------------------------------------------------------- scan

def absolute_ts(value):
    if not value:
        return 0.0
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def token_for(surfaces, cid):
    for channel, _label, token in surfaces:
        if channel == cid:
            return token
    return None


def record_ask(state, cfg, cid, label, msg, new_asks):
    ask_id = '%s:%s' % (cid, msg['ts'])
    record = state['asks'].get(ask_id)
    cls = classify(msg.get('text') or '')
    if record is None:
        record = {
            'ask_id': ask_id,
            'who': cfg.staff[msg['user']],
            'who_id': msg['user'],
            'conv': label,
            'ts': msg['ts'],
            'thread_ts': msg.get('thread_ts') or msg['ts'],
            'class': cls,
            'text': plain(msg.get('text') or '')[:160],
            'link': slack_link(cid, msg['ts']),
            'bot_reply_ts': None,
            'coded_ts': None,
            'emitted_ts': None,
            'checked_ts': 0,
        }
        state['asks'][ask_id] = record
        new_asks.append(record)
    else:
        record['text'] = plain(msg.get('text') or '')[:160]
        record['class'] = cls
    return record


def note_other(new_other, cid, label, msg, state):
    if not msg.get('thread_ts'):
        return
    parent = '%s:%s' % (cid, msg['thread_ts'])
    if parent in state['asks']:
        new_other.append({
            'ask_id': parent,
            'conv': label,
            'ts': msg['ts'],
            'who_id': msg.get('user') or '',
            'text': plain(msg.get('text') or '')[:160],
            'link': slack_link(cid, msg['ts']),
        })


def read_surface(state, cfg, surfaces, now, started):
    """Read every new message and thread reply; return (asks, other, gaps, truncated, scanned).

    `other` is a non-staff human writing in a staff ask's thread: it is logged
    and never attributed to the staff member.  `gaps` names every thread that
    could not be read, so a missing scope or a deleted thread is recorded
    rather than silently skipped.
    """
    new_asks = []
    new_other = []
    gaps = []
    truncated = False
    scanned = 0
    rechecked = 0
    threads = state.setdefault('threads', {})
    # Least recently scanned first: with every readable channel in scope a poll
    # cannot read them all inside --max-secs, and a fixed order would starve the
    # tail forever.  A channel with no new messages still records its scan, so
    # a quiet channel cannot hold the front of the queue.
    order = sorted(surfaces, key=lambda item: state['scanned'].get(item[0], 0))
    for cid, label, token in order:
        if time.time() - started > cfg.max_secs:
            truncated = True
            break
        scanned += 1
        since = absolute_ts(state['cursors'].get(cid))
        floor = now - cfg.lookback_hours * 3600 if cfg.lookback_hours else 0
        oldest = max(since, floor)
        params = {'channel': cid, 'limit': 200}
        if oldest:
            params['oldest'] = '%.6f' % oldest
        latest = None
        read_threads = set()
        status = {'complete': False}
        for msg in paged(token, 'conversations.history', 'messages', status=status, **params):
            ts = absolute_ts(msg.get('ts'))
            if ts:
                latest = ts if latest is None else max(latest, ts)
            if ts <= since:
                continue
            record = None
            if not is_bot(msg):
                if is_ask(msg, cfg.staff):
                    record = record_ask(state, cfg, cid, label, msg, new_asks)
                else:
                    note_other(new_other, cid, label, msg, state)
            # Thread replies are not returned by conversations.history, so a
            # staff ask written inside a thread is only visible here.  Read
            # only threads whose parent is inside the scan window, so the work
            # stays proportional to new threads rather than channel history.
            if not msg.get('reply_count') or ts < oldest:
                continue
            if time.time() - started > cfg.max_secs:
                truncated = True
                break
            thread_ts = msg.get('thread_ts') or msg['ts']
            read_threads.add(thread_ts)
            key = cid + ':' + thread_ts
            replies, error = thread_replies(token, cid, thread_ts)
            if error:
                gaps.append({'channel': cid, 'thread_ts': thread_ts, 'error': error})
                entry = threads.setdefault(key, {'read_ts': now, 'failures': 0})
                entry['failures'] = entry.get('failures', 0) + 1
                entry['read_ts'] = now
                continue
            threads[key] = {'read_ts': now, 'failures': 0}
            if record is not None:
                coded = note_replies(record, replies)
                record['checked_ts'] = now
                if coded:
                    record['coded_ts'] = coded['ts']
            scan_replies(state, cfg, cid, label, replies, now, new_asks, new_other)
        # A thread whose parent is behind the cursor is never returned by
        # conversations.history again, so a new staff ask written there is only
        # visible by re-reading the threads already seen.  Least recently read
        # first, capped so a busy channel cannot spend the whole poll here.
        tracked = [key for key in threads if key.startswith(cid + ':')]
        tracked.sort(key=lambda key: threads[key].get('read_ts') or 0)
        for key in tracked:
            thread_ts = key.split(':', 1)[1]
            if thread_ts in read_threads:
                continue
            entry = threads[key]
            if entry.get('failures', 0) >= THREAD_FAIL_LIMIT:
                continue
            if rechecked >= THREAD_RECHECK_LIMIT:
                break
            if time.time() - started > cfg.max_secs:
                truncated = True
                break
            rechecked += 1
            replies, error = thread_replies(token, cid, thread_ts)
            if error:
                gaps.append({'channel': cid, 'thread_ts': thread_ts, 'error': error})
                entry['failures'] = entry.get('failures', 0) + 1
                entry['read_ts'] = now
                continue
            entry['read_ts'] = now
            entry['failures'] = 0
            scan_replies(state, cfg, cid, label, replies, now, new_asks, new_other)
        # A history page that did not fully read must not move the cursor past
        # the unread tail: leave it where it was so the next poll re-reads it.
        # A failed thread re-read is not a history failure; that thread stays
        # tracked and is retried separately.
        if status['complete']:
            state['scanned'][cid] = now
            if latest is not None:
                state['cursors'][cid] = '%.6f' % latest
        if truncated:
            break
    return new_asks, new_other, gaps, truncated, scanned


def scan(cfg, state, started):
    tokens = bot_tokens(read_env_file(cfg.env_file))
    if not tokens:
        return {'ok': False, 'error': 'no bot token in ' + cfg.env_file}
    if 'operations' not in tokens:
        return {'ok': False, 'error': 'no operations bot token'}
    now = time.time()
    surfaces, missing = scan_surfaces(tokens, parse_pairs(cfg.channels), cfg.deny,
                                      cfg.staff, cfg.max_secs, started)
    new_asks, new_other, gaps, truncated, scanned = read_surface(state, cfg, surfaces, now, started)

    # Tracked threads age out with the scan window, or after a week when no
    # lookback is set, so the re-read set stays bounded.
    retention = cfg.lookback_hours * 3600 if cfg.lookback_hours else CLOSED_TTL
    for key in list(state['threads']):
        if now - absolute_ts(key.split(':', 1)[1]) > retention:
            del state['threads'][key]

    # Round-robin recheck of open asks: a coded answer that landed in the thread
    # is what closes an ask, and only a bounded few can be read per poll, so the
    # least recently checked go first.
    closed = []
    open_ids = [ask_id for ask_id, record in state['asks'].items() if not record.get('coded_ts')]
    open_ids.sort(key=lambda ask_id: (state['asks'][ask_id].get('checked_ts') or 0,
                                      absolute_ts(state['asks'][ask_id]['ts'])))
    for ask_id in open_ids[:cfg.recheck_limit]:
        if time.time() - started > cfg.max_secs:
            truncated = True
            break
        record = state['asks'][ask_id]
        cid = ask_id.split(':', 1)[0]
        thread_ts = record.get('thread_ts') or record['ts']
        replies, error = thread_replies(token_for(surfaces, cid) or tokens['operations'],
                                        cid, thread_ts)
        record['checked_ts'] = now
        if error:
            gaps.append({'channel': cid, 'thread_ts': thread_ts, 'error': error})
            continue
        coded = note_replies(record, replies)
        scan_replies(state, cfg, cid, record.get('conv') or cid, replies, now,
                     new_asks, new_other)
        if coded:
            record['coded_ts'] = coded['ts']
            closed.append({
                'ask_id': ask_id,
                'ts': coded['ts'],
                'text': plain(coded.get('text') or '')[:160],
                'link': slack_link(cid, coded['ts']),
            })

    # An ask is handed to firstmate once, but the handoff is re-offered after
    # --emit-cooldown-secs while it is still uncoded: if the firstmate side died
    # between the scan and its ledger write, that lost answer heals on a later
    # poll instead of being suppressed forever. The ledger's ask-id dedupe keeps
    # the re-offer silent whenever the write did land.
    queue = []
    for record in state['asks'].values():
        if record.get('coded_ts'):
            continue
        if record.get('emitted_ts') and now - absolute_ts(record['emitted_ts']) < cfg.emit_cooldown:
            continue
        if (now - absolute_ts(record['ts'])) / 60 < cfg.grace_min:
            continue
        queue.append(record)
    queue.sort(key=lambda record: absolute_ts(record['ts']))
    for record in queue:
        record['emitted_ts'] = now

    # Closed records are kept a week so a re-read cannot resurrect one. An open
    # ask is never dropped here: it is a firstmate decision, and the ledger, not
    # this scanner, is what guarantees it is still filed.
    for ask_id in list(state['asks']):
        record = state['asks'][ask_id]
        if record.get('coded_ts') and now - absolute_ts(record['coded_ts']) > CLOSED_TTL:
            del state['asks'][ask_id]

    unique_gaps = []
    seen_gaps = set()
    for gap in gaps:
        key = (gap['channel'], gap['thread_ts'])
        if key in seen_gaps:
            continue
        seen_gaps.add(key)
        unique_gaps.append(gap)

    return {
        'ok': True,
        'tool': 'jan-asks-watch',
        'mode': 'scan',
        'now': int(now),
        'convs': scanned,
        'surfaces': len(surfaces),
        'channels': [label for _cid, label, _token in surfaces],
        'deny': sorted(cfg.deny),
        'truncated': truncated,
        'missing_channels': missing,
        'new': new_asks,
        'other': new_other,
        'gaps': unique_gaps,
        'queue': queue,
        'closed': closed,
        'open': len([1 for r in state['asks'].values() if not r.get('coded_ts')]),
    }


# --------------------------------------------------------------------- main

class Config(object):
    """Plain carrier for the parsed command line."""


def build_config(args):
    cfg = Config()
    cfg.env_file = args.env_file
    cfg.state = args.state
    cfg.staff = parse_pairs(args.staff)
    cfg.channels = args.channels
    cfg.deny = [part.strip() for part in (args.deny_channels or '').split(',') if part.strip()]
    cfg.grace_min = float(args.grace_min)
    cfg.recheck_limit = int(args.recheck_limit)
    cfg.emit_cooldown = float(args.emit_cooldown_secs)
    cfg.max_secs = float(args.max_secs)
    cfg.lookback_hours = float(args.lookback_hours or 0)
    return cfg


def parse_args(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--scan', action='store_true')
    parser.add_argument('--seed-cursor', action='store_true')
    parser.add_argument('--env-file', default=os.environ.get('JAN_WATCH_ENV', DEFAULT_ENV))
    parser.add_argument('--state', default=os.environ.get('JAN_WATCH_STATE', DEFAULT_STATE))
    parser.add_argument('--staff', default=os.environ.get('JAN_WATCH_STAFF', DEFAULT_STAFF))
    parser.add_argument('--channels', default=os.environ.get('JAN_WATCH_CHANNELS', DEFAULT_CHANNELS),
                        help='narrow the scan to these channels; empty means every readable one')
    parser.add_argument('--deny-channels',
                        default=os.environ.get('JAN_WATCH_DENY_CHANNELS', DEFAULT_DENY),
                        help='channels never scanned, whatever the scope')
    parser.add_argument('--grace-min', default=os.environ.get('JAN_WATCH_GRACE_MIN', '30'))
    parser.add_argument('--recheck-limit', default=os.environ.get('JAN_WATCH_RECHECK_LIMIT', '12'))
    parser.add_argument('--emit-cooldown-secs',
                        default=os.environ.get('JAN_WATCH_EMIT_COOLDOWN_SECS',
                                               str(DEFAULT_EMIT_COOLDOWN)))
    parser.add_argument('--max-secs', default=os.environ.get('JAN_WATCH_MAX_SECS', '20'))
    parser.add_argument('--lookback-hours', default=os.environ.get('JAN_WATCH_LOOKBACK_HOURS', ''))
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--help', '-h', action='store_true')
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    if args.help:
        print(__doc__)
        return 0
    cfg = build_config(args)
    started = time.time()
    state = load_state(cfg.state)

    if args.seed_cursor:
        stamp = '%.6f' % started
        tokens = bot_tokens(read_env_file(cfg.env_file))
        if not tokens.get('operations'):
            print('seed failed: no operations bot token in %s' % cfg.env_file, file=sys.stderr)
            return 1
        surfaces, _missing = scan_surfaces(tokens, parse_pairs(cfg.channels), cfg.deny,
                                          cfg.staff, cfg.max_secs, started)
        for cid, _label, _token in surfaces:
            state['cursors'][cid] = stamp
        state['asks'] = {}
        state['threads'] = {}
        if not args.dry_run:
            save_state(cfg.state, state)
        print('seeded %d conversation cursor(s) at %s' % (len(surfaces), stamp))
        return 0

    result = scan(cfg, state, started)
    if not args.dry_run:
        save_state(cfg.state, state)
    json.dump(result, sys.stdout, sort_keys=True)
    sys.stdout.write('\n')
    return 0 if result.get('ok') else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
