#!/usr/bin/env python3
"""fm-jan-asks-watch-lib.py - the ledger, board, and wake text of the staff-asks watch.

bin/fm-jan-asks-watch.sh owns scheduling, config, and the check plumbing; this
file owns the durable text, so the formats live in exactly one place.

  render   fold one scanner answer into the raw log, the ledger, and the board,
           then print the wake block (nothing when there is nothing to say)
  board    rewrite the board section from the ledger alone (no network)
  status   print the local read-only summary

THE LEDGER (`data/asks/jan-backlog.md`) is append-only and is the escalation
memory.  It records two shapes, and nothing else:

  - <stamp> [ask <ask-id>] need firstmate: task <title> | <class> | <link> | <who> | <conv> | <age>min | <answered>
  - <stamp> [resolved <ask-id>] <why>

An ask is filed at most once: the id is the memory, so a repeated poll, a lost
scanner state, or a firstmate restart can neither double-file nor forget it.
Anything carrying the ask id and reading as a resolution closes it - the
`resolve` command, or a hand-written `resolved: <ask-id> ...` line.

The wake line firstmate sees is the first three fields of the ask line, so the
`need firstmate: task <title> | <class> | <link>` shape stays exactly as the
ledger's own format defines it.  The trailing fields exist so the board never
has to guess context out of prose.
"""
import argparse
import calendar
import html
import json
import os
import re
import sys
import time

ASK_RE = re.compile(r'\[ask ([^\]]+)\]')
RESOLVED_RE = re.compile(r'^\s*-\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}Z \[resolved ([^\]]+)\]')
# A free-form resolution line: it must OPEN the line (a list bullet is fine),
# so the ledger's own header prose about resolved: records never closes one.
BARE_RESOLVED_RE = re.compile(r'^\s*(?:-\s+)?resolved\b[:\s]', re.I)
ASK_ID_RE = re.compile(r'\b([CGD][A-Z0-9]{5,}:\d{10}\.\d{6})\b')
LEDGER_STAMP_RE = re.compile(r'^-\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}Z)')
SEPARATOR = ' | '
STALE_DAYS = 14
LANE_FOR_CLASS = {
    'proof-review': 'j-p1',
    'progress': 'j-p1',
    'gdpr-hide': 'j-g1',
    'summarize-resolve': 'j-s1',
    'billing': 'j-s1',
    'profile-edit': 'j-s1',
    'clickup-categorize': 'j-k1',
}


def stamp(epoch):
    return time.strftime('%Y-%m-%d %H:%MZ', time.gmtime(epoch))


def day_of(epoch):
    return time.strftime('%Y-%m-%d', time.gmtime(epoch))


def parse_stamp(text):
    try:
        return float(calendar.timegm(time.strptime(text, '%Y-%m-%d %H:%MZ')))
    except (TypeError, ValueError):
        return 0.0


def ask_epoch(ask_id):
    try:
        return float(ask_id.split(':', 1)[1])
    except (IndexError, ValueError):
        return 0.0


def clean_text(text, limit=70):
    text = re.sub(r'\s+', ' ', text or '').strip()
    text = text.replace('|', '/')
    if len(text) > limit:
        text = text[:limit - 1].rstrip() + '...'
    return text or '(no text)'


def read_lines(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            return handle.read().splitlines()
    except OSError:
        return []


def append_lines(path, lines):
    if not lines:
        return
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, 'a', encoding='utf-8') as handle:
        for line in lines:
            handle.write(line + '\n')


# ---------------------------------------------------------------------- ledger

def parse_ledger(lines):
    """Return ({ask_id: record}, {ask_id: resolution line}, [ids in order])."""
    opened = {}
    resolved = {}
    order = []
    for line in lines:
        match = RESOLVED_RE.search(line)
        if match:
            resolved[match.group(1)] = line.strip()
            continue
        if BARE_RESOLVED_RE.match(line):
            for ask_id in ASK_ID_RE.findall(line):
                resolved.setdefault(ask_id, line.strip())
            continue
        match = ASK_RE.search(line)
        if not match:
            continue
        ask_id = match.group(1)
        if ask_id in opened:
            continue
        parts = line.split('need firstmate: task ', 1)[-1].split(SEPARATOR)
        stamp_match = LEDGER_STAMP_RE.match(line)
        filed_ts = parse_stamp(stamp_match.group(1)) if stamp_match else ask_epoch(ask_id)
        opened[ask_id] = {
            'ask_id': ask_id,
            'line': line.strip(),
            'title': parts[0].strip(),
            'class': parts[1].strip() if len(parts) > 1 else 'other',
            'link': parts[2].strip() if len(parts) > 2 else '',
            'who': parts[3].strip() if len(parts) > 3 else '',
            'conv': parts[4].strip() if len(parts) > 4 else '',
            'answered': parts[6].strip() if len(parts) > 6 else '',
            'ts': ask_epoch(ask_id),
            'filed_ts': filed_ts,
        }
        order.append(ask_id)
    return opened, resolved, order


def ask_line(record, epoch):
    """The ledger line for one newly filed ask."""
    age = int((epoch - ask_epoch(record['ask_id'])) / 60)
    answered = 'bot replied' if record.get('bot_reply_ts') else 'NO reply'
    fields = [
        clean_text(record.get('text') or ''),
        record.get('class') or 'other',
        record.get('link') or '',
        record.get('who') or '',
        record.get('conv') or '',
        '%dmin' % age,
        answered,
    ]
    return '- %s [ask %s] need firstmate: task %s' % (
        stamp(epoch), record['ask_id'], SEPARATOR.join(fields))


def wake_echo(record):
    """The three fields firstmate's own task shape reads."""
    return 'need firstmate: task %s | %s | %s' % (
        clean_text(record.get('text') or ''),
        record.get('class') or 'other',
        record.get('link') or '')


def resolve_line(ask_id, note, epoch):
    return '- %s [resolved %s] %s' % (stamp(epoch), ask_id, clean_text(note, 200))


# ----------------------------------------------------------------------- board

BOARD_HEAD = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Staff asks awaiting a firstmate task</title>
<style>
:root{--bg:#0f1115;--card:#171a21;--line:#262b36;--fg:#e8eaf0;--mute:#9aa3b2;--gold:#d4a83a;--red:#e0585b;--green:#3fbf7f}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:13px/1.4 -apple-system,Segoe UI,Inter,Roboto,sans-serif;padding:14px 18px}
h1{font-size:18px;margin:0 0 2px}h2{font-size:13px;margin:16px 0 6px;color:var(--gold);letter-spacing:.04em;text-transform:uppercase}
.sub{color:var(--mute);margin-bottom:8px}table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line)}
th,td{padding:5px 7px;border-bottom:1px solid var(--line);vertical-align:top;text-align:left}
th{color:var(--mute);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
td.c{white-space:nowrap}td.n{text-align:right;white-space:nowrap}
.t{color:var(--red);font-weight:700}.g{color:var(--green)}.stale{color:var(--mute)}
a{color:#8fb6ff;text-decoration:none}code{background:#0b0d11;padding:0 4px;border-radius:3px}
.foot{color:var(--mute);margin-top:12px;font-size:12px}
</style></head><body>
"""


def human_age(minutes):
    if minutes < 90:
        return '%d min' % minutes
    if minutes < 2880:
        return '%.1f h' % (minutes / 60.0)
    return '%.1f d' % (minutes / 1440.0)


def count_filed_today(opened, order, now):
    today = day_of(now)
    return len([1 for ask_id in order
                if day_of(opened[ask_id].get('filed_ts') or opened[ask_id]['ts']) == today])


def build_board_json(opened, resolved, order, now, budget, ledger_path, json_path):
    """Assemble the board model from the ledger: open rows, per-class counts, ages."""
    rows = []
    for ask_id in order:
        if ask_id in resolved:
            continue
        record = opened[ask_id]
        rows.append({
            'ask_id': ask_id,
            'who': record['who'],
            'class': record['class'],
            'title': record['title'],
            'link': record['link'],
            'conv': record['conv'],
            'answered': record['answered'],
            'ts': record['ts'],
            'age_min': max(0, int((now - record['ts']) / 60)) if record['ts'] else 0,
        })
    counts = {}
    for row in rows:
        name = row['class'] or 'other'
        bucket = counts.setdefault(name, {'open': 0, 'oldest': '', 'oldest_min': -1})
        bucket['open'] += 1
        if row['age_min'] > bucket['oldest_min']:
            bucket['oldest_min'] = row['age_min']
            bucket['oldest'] = stamp(row['ts'])[:16]
    for bucket in counts.values():
        bucket.pop('oldest_min', None)
    return {
        'generated': stamp(now),
        'now': int(now),
        'budget': budget,
        'open': rows,
        'counts': counts,
        'today': count_filed_today(opened, order, now),
        'oldest': stamp(min(row['ts'] for row in rows))[:16] if rows else '',
        'ledger': ledger_path,
        'json_path': json_path,
    }


def render_board(board, budget, now):
    """Write the section: counts per class, then open asks by staff, oldest first."""
    open_rows = board['open']
    counts = board['counts']
    out = [BOARD_HEAD]
    out.append('<h1>Staff asks awaiting a firstmate task</h1>')
    out.append('<div class="sub">Every staff ask in every channel the bot tokens can read '
               '(minus the deny list) and the Ops/staff DMs with no <b>coded</b> answer '
               '(the <code>Proof review (</code> card, '
               'or a bot reply carrying <code>ledger &lt;row&gt;</code>). Filed once per ask id, '
               'closed only by a <code>resolved:</code> record carrying that id.</div>')
    over = ' class="t"' if board['today'] > budget else ''
    out.append('<div class="sub">%d open - <b%s>%d filed today (budget %d)</b> - oldest open %s - '
               'ledger <code>%s</code></div>'
               % (len(open_rows), over, board['today'], budget,
                  html.escape(board['oldest'] or '-'), html.escape(board['ledger'])))
    out.append('<h2>Counts per class (lane priority reads off this)</h2><table><tr>'
               '<th>class</th><th>open</th><th>oldest open</th><th>lane</th></tr>')
    for name in sorted(counts, key=lambda key: (-counts[key]['open'], key)):
        row = counts[name]
        out.append('<tr><td class="c">%s</td><td class="n">%d</td><td class="c">%s</td>'
                   '<td class="c">%s</td></tr>'
                   % (html.escape(name), row['open'], html.escape(row['oldest'] or '-'),
                      html.escape(LANE_FOR_CLASS.get(name, '-'))))
    out.append('</table>')
    by_staff = {}
    for row in open_rows:
        by_staff.setdefault(row['who'] or 'unknown', []).append(row)
    for who in sorted(by_staff):
        out.append('<h2>%s</h2><table><tr><th>asked</th><th>class</th><th>ask</th>'
                   '<th>reply</th><th>age</th><th>id</th></tr>' % html.escape(who))
        for row in by_staff[who]:
            cls = ' class="stale"' if row['age_min'] / 1440.0 >= STALE_DAYS else ''
            reply = ('answered, not coded' if row['answered'] == 'bot replied'
                     else '<span class="t">no reply</span>')
            out.append('<tr%s><td class="c">%s</td><td class="c">%s</td>'
                       '<td><a href="%s">%s</a><br><span class="stale">%s</span></td>'
                       '<td class="c">%s</td><td class="n">%s</td><td class="c"><code>%s</code></td></tr>'
                       % (cls, stamp(row['ts'])[:16], html.escape(row['class']),
                          html.escape(row['link'] or '#'), html.escape(row['title']),
                          html.escape(row['conv']), reply, human_age(row['age_min']),
                          html.escape(row['ask_id'])))
        out.append('</table>')
    if not open_rows:
        out.append('<p class="g">Nothing open.</p>')
    stale = [row for row in open_rows if row['age_min'] / 1440.0 >= STALE_DAYS]
    if stale:
        out.append('<p class="foot">%d entr(y/ies) older than %d days: still open, still yours to '
                   'close with <code>resolved: &lt;ask-id&gt;</code> or finish.</p>'
                   % (len(stale), STALE_DAYS))
    out.append('<p class="foot">Rendered %s by <code>bin/fm-jan-asks-watch.sh</code>. '
               'Machine-readable copy: <code>%s</code>.</p></body></html>'
               % (stamp(now), html.escape(board['json_path'])))
    return '\n'.join(out) + '\n'


def absolute_now(data):
    try:
        return float(data.get('now') or 0) or time.time()
    except (TypeError, ValueError):
        return time.time()


def write_if_changed(path, text):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    try:
        with open(path, 'r', encoding='utf-8') as handle:
            if handle.read() == text:
                return
    except OSError:
        pass
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as handle:
        handle.write(text)
    os.replace(tmp, path)


def write_board(ledger_path, html_path, json_path, budget, now):
    """Rewrite the board section from the ledger alone (no scan needed)."""
    opened, resolved, order = parse_ledger(read_lines(ledger_path))
    board = build_board_json(opened, resolved, order, now, int(budget), ledger_path, json_path)
    write_if_changed(html_path, render_board(board, int(budget), now))
    write_if_changed(json_path, json.dumps(board, indent=1, sort_keys=True) + '\n')
    return board


# ---------------------------------------------------------------------- render

def cmd_render(args):
    try:
        with open(args.json, 'r', encoding='utf-8') as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        print('fm-jan-asks-watch: cannot read the scanner answer (%s)' % exc, file=sys.stderr)
        return 1
    if not data.get('ok'):
        return 1
    # The ledger is stamped with the moment the scan was taken, not the moment
    # this render ran: one clock per record, and a slow render cannot move an
    # entry into the next day's budget.
    now = float(args.now) if args.now else absolute_now(data)
    opened, resolved, order = parse_ledger(read_lines(args.ledger))
    raw_lines = read_lines(args.raw)
    raw_seen = set()
    raw_other_seen = set()
    for line in raw_lines:
        seen_match = re.match(r'^## .* \(seen\) (\S+) ', line)
        if seen_match:
            raw_seen.add(seen_match.group(1))
        other_match = re.match(r'^## .* \(other\) (\S+) (\S+) ', line)
        if other_match:
            raw_other_seen.add('%s:%s' % (other_match.group(1), other_match.group(2)))
    seen_before = set(opened) | set(resolved) | raw_seen
    budget = int(args.budget)
    # The resolved channel scope is reported once per run: the count on the wake
    # line and the full list in the audit log, so what was actually scanned is
    # visible without reading the scanner.  It is written only when it changes,
    # because a per-poll line would wake firstmate for nothing.
    channels = [str(name) for name in (data.get('channels') or [])]
    deny = [str(name) for name in (data.get('deny') or [])]
    scope_body = '%d channel(s) (deny: %s): %s' % (
        len(channels), ', '.join(deny) or 'none', ', '.join(channels) or 'none')
    scope = '## scope %s %s' % (stamp(now), scope_body)
    last_scope = next((line for line in reversed(raw_lines) if line.startswith('## scope ')), '')
    last_scope_body = re.sub(r'^## scope \S+ \S+ ', '', last_scope)
    scope_changed = last_scope_body != scope_body
    missing = [str(name) for name in (data.get('missing_channels') or [])]
    missing_body = ', '.join(missing) or 'none'
    last_missing = next((line for line in reversed(raw_lines) if line.startswith('## missing ')), '')
    last_missing_body = re.sub(r'^## missing \S+ \S+ ', '', last_missing)
    missing_changed = last_missing_body != missing_body
    gaps = [str(gap.get('channel') or '?') + ':' + str(gap.get('thread_ts') or '?')
            + ' (' + str(gap.get('error') or 'unreadable') + ')'
            for gap in (data.get('gaps') or [])]
    gaps_body = ', '.join(gaps) or 'none'
    last_gap = next((line for line in reversed(raw_lines) if line.startswith('## gap ')), '')
    last_gap_body = re.sub(r'^## gap \S+ \S+ ', '', last_gap)
    gap_changed = last_gap_body != gaps_body

    # 1. raw log: the audit trail of what the scanner saw, staff and other alike.
    raw = []
    for record in data.get('new') or []:
        if record['ask_id'] in raw_seen:
            continue
        raw.append('## %s (seen) %s %s in %s [%s]' % (stamp(now), record['ask_id'],
                                                     record.get('who') or '?',
                                                     record.get('conv') or '?',
                                                     record.get('class') or 'other'))
        raw.append(record.get('text') or '')
        raw.append(record.get('link') or '')
        raw.append('')
        raw_seen.add(record['ask_id'])
    for other in data.get('other') or []:
        key = '%s:%s' % (other.get('ask_id') or '', other.get('ts') or '')
        if key in raw_other_seen:
            continue
        raw.append('## %s (other) %s %s %s in %s - not attributed to staff'
                   % (stamp(now), other.get('ask_id') or '', other.get('ts') or '',
                      other.get('who_id') or 'unknown', other.get('conv') or '?'))
        raw.append(other.get('text') or '')
        raw.append(other.get('link') or '')
        raw.append('')
        raw_other_seen.add(key)
    if scope_changed:
        raw.append(scope)
        raw.append('')
    if missing_changed:
        raw.append('## missing %s %s' % (stamp(now), missing_body))
        raw.append('')
    if gap_changed:
        raw.append('## gap %s %s' % (stamp(now), gaps_body))
        raw.append('')
    append_lines(args.raw, raw)

    # 2. closures: a coded answer seen in the thread.
    ledger_new = []
    for close in data.get('closed') or []:
        ask_id = close.get('ask_id') or ''
        if not ask_id or ask_id in resolved or ask_id not in opened:
            continue
        ledger_new.append(resolve_line(ask_id, 'coded answer in thread: %s'
                                       % (close.get('text') or ''), now))
        resolved[ask_id] = 'coded'

    # 3. filings: exactly once per ask id.
    filed = []
    for record in data.get('queue') or []:
        ask_id = record.get('ask_id') or ''
        if not ask_id or ask_id in opened or ask_id in resolved:
            continue
        line = ask_line(record, now)
        ledger_new.append(line)
        opened[ask_id] = {'ask_id': ask_id, 'line': line,
                          'title': clean_text(record.get('text') or ''),
                          'class': record.get('class') or 'other',
                          'link': record.get('link') or '',
                          'who': record.get('who') or '',
                          'conv': record.get('conv') or '',
                          'answered': 'bot replied' if record.get('bot_reply_ts') else 'NO reply',
                          'ts': ask_epoch(ask_id), 'filed_ts': now}
        order.append(ask_id)
        filed.append(record)
    if ledger_new:
        if not os.path.exists(args.ledger):
            append_lines(args.ledger,
                         ['# Staff asks backlog - one line per ask; close with a resolved: record '
                          'carrying the ask id'])
        append_lines(args.ledger, ledger_new)

    # 4. the board, rewritten in place (only on a content change, so no churn).
    board = write_board(args.ledger, args.board_html, args.board_json, budget, now)

    # 5. the wake block. Only asks this ledger had never seen are "new": a
    # scanner that repeats itself (lost state, replayed answer) must not wake
    # firstmate twice for the same ask.
    new_asks = []
    for record in data.get('new') or []:
        ask_id = record.get('ask_id') or ''
        if ask_id and ask_id not in seen_before:
            new_asks.append(record)
    if new_asks or filed:
        print('jan-asks-watch: %d new staff ask(s) - %d filed - %d open - %d filed today (budget %d)%s'
              % (len(new_asks), len(filed), len(board['open']), board['today'], budget,
                 '' if board['today'] <= budget else ' - OVER BUDGET'))
    for record in sorted(new_asks, key=lambda item: -ask_epoch(item['ask_id']))[:6]:
        age = int((now - ask_epoch(record['ask_id'])) / 60)
        print('ask %s/%s %dmin "%s" %s' % (record.get('who') or '?',
                                           record.get('class') or 'other', age,
                                           clean_text(record.get('text') or '', 100),
                                           record.get('link') or ''))
    for record in filed:
        print(wake_echo(record))
    if scope_changed:
        print('jan-asks-watch: scope is now %d channel(s) (deny: %s)'
              % (len(channels), ', '.join(deny) or 'none'))
    if missing_changed and missing:
        print('jan-asks-watch: the scanner cannot see configured channel(s): %s '
              '(check the channel name and the bot membership)' % ', '.join(missing))
    if gap_changed and gaps:
        print('jan-asks-watch: %d thread(s) could not be read: %s'
              % (len(gaps), ', '.join(gaps)))
    return 0


# ---------------------------------------------------------------------- status

def cmd_status(args):
    now = time.time()
    opened, resolved, order = parse_ledger(read_lines(args.ledger))
    rows = []
    for ask_id in order:
        if ask_id in resolved:
            continue
        record = opened[ask_id]
        rows.append((record, int((now - record['ts']) / 60) if record['ts'] else 0))
    counts = {}
    for record, _age in rows:
        counts[record['class'] or 'other'] = counts.get(record['class'] or 'other', 0) + 1
    print('ledger: %s (%d open, %d resolved)' % (args.ledger, len(rows), len(resolved)))
    for name in sorted(counts, key=lambda key: (-counts[key], key)):
        print('  %-20s %d' % (name, counts[name]))
    print('filed today: %d (budget %s)' % (count_filed_today(opened, order, now), args.budget))
    if rows:
        record, age = max(rows, key=lambda item: item[1])
        print('oldest open: %d min  %s  %s' % (age, record['class'], record['ask_id']))
    stale = [record for record, age in rows if age >= STALE_DAYS * 1440]
    if stale:
        print('older than %d days: %d (still open; close with resolve)' % (STALE_DAYS, len(stale)))
    try:
        with open(args.last_json, 'r', encoding='utf-8') as handle:
            last = json.load(handle)
        print('last scan: %s  convs=%s/%s truncated=%s'
              % (stamp(float(last.get('now') or 0)), last.get('convs', '?'),
                 last.get('surfaces', '?'), 'yes' if last.get('truncated') else 'no'))
        if last.get('channels') is not None:
            print('scope: %d channel(s) (deny: %s)'
                  % (len(last.get('channels') or []),
                     ', '.join(last.get('deny') or []) or 'none'))
        if last.get('missing_channels'):
            print('missing channels: %s' % ', '.join(last['missing_channels']))
    except (OSError, ValueError):
        print('last scan: none recorded')
    try:
        with open(args.fails, 'r', encoding='utf-8') as handle:
            print('consecutive poll failures: %s' % handle.read().strip())
    except OSError:
        print('consecutive poll failures: 0')
    if os.path.exists(args.dark):
        print('DARK: alarmed, the scanner has been unreachable')
    return 0


def main(argv):
    parser = argparse.ArgumentParser(add_help=True)
    sub = parser.add_subparsers(dest='cmd')
    render = sub.add_parser('render')
    render.add_argument('--json', required=True)
    render.add_argument('--ledger', required=True)
    render.add_argument('--raw', required=True)
    render.add_argument('--board-html', required=True)
    render.add_argument('--board-json', required=True)
    render.add_argument('--budget', default='30')
    render.add_argument('--now', default='')
    board = sub.add_parser('board')
    board.add_argument('--ledger', required=True)
    board.add_argument('--board-html', required=True)
    board.add_argument('--board-json', required=True)
    board.add_argument('--budget', default='30')
    status = sub.add_parser('status')
    status.add_argument('--ledger', required=True)
    status.add_argument('--last-json', required=True)
    status.add_argument('--fails', required=True)
    status.add_argument('--dark', required=True)
    status.add_argument('--budget', default='30')
    args = parser.parse_args(argv)
    if args.cmd == 'render':
        return cmd_render(args)
    if args.cmd == 'board':
        write_board(args.ledger, args.board_html, args.board_json, args.budget, time.time())
        return 0
    if args.cmd == 'status':
        return cmd_status(args)
    parser.print_help()
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
