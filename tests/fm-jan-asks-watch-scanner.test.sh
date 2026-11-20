#!/usr/bin/env bash
# tests/fm-jan-asks-watch-scanner.test.sh - the Slack-side scanner and the
# ledger/board formats it feeds. The failure this pins: the watch it replaced
# saw 3 of Jan's 387 messages, so a dozen asks a day died in a thread with a
# prose answer and nothing was ever filed.
#
# The scanner is proven here rather than through the wrapper because it is the
# half that decides what counts as an ask, what counts as a coded answer, and
# which channels are in scope - the judgements a reviewer has to be able to
# read on their own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REMOTE="$ROOT/bin/fm-jan-asks-watch-remote.py"
LIB="$ROOT/bin/fm-jan-asks-watch-lib.py"

python3 - "$REMOTE" <<'PY' || fail 'the scanner classifies, attributes, closes, and pages correctly'
import importlib.util, os, sys, tempfile, time

spec = importlib.util.spec_from_file_location('jan_remote', sys.argv[1])
jw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jw)

# classification
assert jw.classify('Please review the proof of the user provided for his/her credits') == 'proof-review'
assert jw.classify('hide the profile from public') == 'gdpr-hide'
assert jw.classify('put it back to-do in clickup') == 'clickup-categorize'
assert jw.classify('Closed') == 'triage-ack'
assert jw.classify('hello there') == 'other'

# a coded answer is the card, or a bot reply naming the ledger row; prose is not
ask_id = 'C0APB2CMM7C:1793824709.431389'
after = '1793824800.000000'
card = [{'ts': after, 'bot_id': 'B1', 'text': 'Proof review (user 42, credits 3)'}]
ledger = [{'ts': after, 'bot_id': 'B1', 'text': 'proof-review - %s - user 42 - ledger ab12cd' % ask_id}]
prose = [{'ts': after, 'bot_id': 'B1', 'text': 'I reviewed the proof and approved it, all good.'}]
human = [{'ts': after, 'user': 'U0AGENT', 'text': 'ledger ab12cd - done'}]
assert jw.coded_answer(card, 'proof-review', ask_id) is card[0]
assert jw.coded_answer(ledger, 'proof-review', ask_id) is ledger[0]
assert jw.coded_answer(prose, 'proof-review', ask_id) is None
assert jw.coded_answer(human, 'proof-review', ask_id) is None
# the class must be a delimited field, not a substring: "another" must not
# close an ask classified "other"
not_coded = [{'ts': after, 'bot_id': 'B1', 'text': 'ledger ab12cd \u00b7 moved to another queue'}]
assert jw.coded_answer(not_coded, 'other', ask_id) is None
dotted = [{'ts': after, 'bot_id': 'B1', 'text': 'ledger ab12cd \u00b7 proof-review \u00b7 user 42'}]
assert jw.coded_answer(dotted, 'proof-review', ask_id) is dotted[0]
# a bot reply that predates the ask cannot code it: a staff ask written as a
# reply in a thread that already carries a coded answer for the parent must
# still be filed.
staff_reply = 'C1:1793824709.431389'
trace = [{'ts': '1793824000.000000', 'user': 'U038BM16T7W',
          'text': 'review the proof for the user 1'},
         {'ts': '1793824100.000000', 'bot_id': 'B1',
          'text': 'ledger ab12cd \u00b7 proof-review \u00b7 user 1'},
         {'ts': '1793824709.431389', 'user': 'U038BM16T7W',
          'text': 'also review the proof for the user 12345'}]
assert jw.coded_answer(trace, 'proof-review', staff_reply) is None
# a proof card for an earlier ask must not close a later ask in the same thread
parent = 'C1:1793824000.000000'
later = 'C1:1793824200.000000'
card_trace = [{'ts': '1793824000.000000', 'user': 'U038BM16T7W',
               'text': 'review the proof for the user 1'},
              {'ts': '1793824200.000000', 'user': 'U038BM16T7W',
               'text': 'also review the proof for the user 2'},
              {'ts': '1793824300.000000', 'bot_id': 'B1',
               'text': 'Proof review (user 1, credits 3)'}]
assert jw.coded_answer(card_trace, 'proof-review', later, parent) is None
assert jw.coded_answer(card_trace, 'proof-review', parent, parent) is None
# a ledger row for an earlier ask must not close a later ask by class
ledger_trace = [{'ts': '1793824000.000000', 'user': 'U038BM16T7W',
                 'text': 'review the proof for the user 1'},
                {'ts': '1793824200.000000', 'user': 'U038BM16T7W',
                 'text': 'also review the proof for the user 2'},
                {'ts': '1793824300.000000', 'bot_id': 'B1',
                 'text': 'ledger ab12cd \u00b7 proof-review \u00b7 user 1'}]
assert jw.coded_answer(ledger_trace, 'proof-review', later, parent) is None
assert jw.coded_answer(ledger_trace, 'proof-review', parent, parent) is None
# a ledger row carrying the reply ask's own ts still closes it
own_row = [{'ts': '1793824300.000000', 'bot_id': 'B1',
            'text': 'ledger ab12cd \u00b7 proof-review \u00b7 %s' % later}]
assert jw.coded_answer(own_row, 'proof-review', later, parent) is own_row[0]
# a bot card that predates the ask is not its answer
rec = {'ask_id': later, 'class': 'proof-review', 'bot_reply_ts': None}
jw.note_replies(rec, [{'ts': '1793824000.000000', 'bot_id': 'B1',
                       'text': 'Proof review (user 1, credits 3)'}])
assert rec['bot_reply_ts'] is None

# identity is the user id, never a name
staff = jw.parse_pairs(jw.DEFAULT_STAFF)
assert 'U038BM16T7W' in staff
assert not jw.is_ask({'user': 'U0NOTSTAFF', 'text': 'Jan said review the proof'}, staff)
assert jw.is_ask({'user': 'U038BM16T7W', 'text': 'review the proof of the user'}, staff)
# A staff ask posted with an attachment or as a thread broadcast is still an
# ask; only Slack's system events are skipped.
assert jw.is_ask({'user': 'U038BM16T7W', 'subtype': 'file_share',
                  'text': 'review the proof of the user'}, staff)
assert jw.is_ask({'user': 'U038BM16T7W', 'subtype': 'thread_broadcast',
                  'text': 'hide the profile from public'}, staff)
assert not jw.is_ask({'user': 'U038BM16T7W', 'subtype': 'channel_join',
                      'text': 'review the proof of the user'}, staff)
assert not jw.is_ask({'user': 'U038BM16T7W', 'subtype': 'bot_message',
                      'text': 'review the proof of the user'}, staff)

# A configured channel the bot can list but has not joined is reported, not
# silently dropped from the scan.
def surfaces_api(token, method, timeout=20, **params):
    if method == 'conversations.list':
        return {'ok': True, 'channels': [{'id': 'CJOINED', 'name': 'joined'},
                                         {'id': 'CNOTJOINED', 'name': 'notjoined'}]}
    if method == 'users.conversations':
        return {'ok': True, 'channels': [{'id': 'CJOINED', 'name': 'joined'}]}
    return {'ok': True}


saved_api = jw.api
jw.api = surfaces_api
surfaces, missing = jw.scan_surfaces({'operations': 'x'}, {'notjoined': 1}, [], {}, 10, time.time())
assert surfaces == [], surfaces
assert missing == ['notjoined'], missing

# A truncated enumeration has not reached every channel, so it must not report
# the ones it had no time to visit as missing; an unresolvable name still is.
truncated, truncated_missing = jw.scan_surfaces(
    {'operations': 'x'}, {'notjoined': 1, 'nope': 1}, [], {}, -1, time.time())
assert truncated == [], truncated
assert truncated_missing == ['nope'], truncated_missing

# The default scope is every channel the token can read, not a hardcoded pair:
# a channel nobody listed in code is scanned, and the deny list is honoured.
def wide_api(token, method, timeout=20, **params):
    if method == 'conversations.list':
        return {'ok': True, 'channels': [{'id': 'C1', 'name': 'credit-verification'},
                                         {'id': 'C2', 'name': 'cs_priority'},
                                         {'id': 'C3', 'name': 'brand-new-channel'},
                                         {'id': 'C4', 'name': 'random'}]}
    if method == 'users.conversations':
        return {'ok': True, 'channels': [{'id': 'C1', 'name': 'credit-verification'},
                                         {'id': 'C2', 'name': 'cs_priority'},
                                         {'id': 'C3', 'name': 'brand-new-channel'},
                                         {'id': 'C4', 'name': 'random'}]}
    return {'ok': True}


jw.api = wide_api
wide, wide_missing = jw.scan_surfaces({'operations': 'x'}, {}, ['random'], {}, 10, time.time())
wide_ids = [cid for cid, _label, _token in wide]
assert len(wide_ids) > 2, 'the default scope must exceed the old hardcoded pair: %r' % (wide_ids,)
assert 'C3' in wide_ids, 'a channel named nowhere in code must still be scanned: %r' % (wide_ids,)
assert 'C4' not in wide_ids, 'the deny list must be honoured: %r' % (wide_ids,)
assert wide_missing == [], wide_missing

# A narrowing override still narrows, and the deny list still wins over it.
narrow, _ = jw.scan_surfaces({'operations': 'x'}, {'brand-new-channel': 1, 'random': 1},
                             ['random'], {}, 10, time.time())
assert [cid for cid, _l, _t in narrow] == ['C3'], narrow

# A narrowing that resolves to nothing must fail closed, not fall through to
# every readable channel.
closed, closed_missing = jw.scan_surfaces({'operations': 'x'}, {'credit-verificaton': 1},
                                          [], {}, 10, time.time())
assert closed == [], closed
assert closed_missing == ['credit-verificaton'], closed_missing

# A D-prefixed DM channel id is a channel id, not an unresolvable name.
def dm_api(token, method, timeout=20, **params):
    if method == 'conversations.list':
        return {'ok': True, 'channels': []}
    if method == 'users.conversations':
        return {'ok': True, 'channels': [{'id': 'D0ABC123', 'name': 'dm-with-jan'}]}
    return {'ok': True}


jw.api = dm_api
dm, dm_missing = jw.scan_surfaces({'operations': 'x'}, {'D0ABC123': 1}, [], {}, 10, time.time())
assert [cid for cid, _l, _t in dm] == ['D0ABC123'], dm
assert dm_missing == [], dm_missing

# A narrowing override narrows the DM surfaces too: a DM the operator did not
# name is not scanned, and naming it scans only it.
def dm_scope_api(token, method, timeout=20, **params):
    if method == 'conversations.list':
        return {'ok': True, 'channels': [{'id': 'C1', 'name': 'credit-verification'}]}
    if method == 'users.conversations':
        return {'ok': True, 'channels': [
            {'id': 'C1', 'name': 'credit-verification'},
            {'id': 'D0JAN123', 'is_im': True, 'user': 'U038BM16T7W'}]}
    return {'ok': True}


jw.api = dm_scope_api
staff_map = jw.parse_pairs(jw.DEFAULT_STAFF)
narrowed, _ = jw.scan_surfaces({'operations': 'x'}, {'credit-verification': 1}, [],
                               staff_map, 10, time.time())
assert [cid for cid, _l, _t in narrowed] == ['C1'], narrowed
only_dm, _ = jw.scan_surfaces({'operations': 'x'}, {'D0JAN123': 1}, [],
                              staff_map, 10, time.time())
assert [cid for cid, _l, _t in only_dm] == ['D0JAN123'], only_dm
jw.api = saved_api

# --- a driven scan: filed once, closed by a coded card, then never refiled ---
now = time.time()
channel = 'C0APB2CMM7C'
history = {'messages': []}
thread = {'messages': []}


def fake_api(token, method, timeout=20, **params):
    if method in ('conversations.list', 'users.conversations'):
        return {'ok': True, 'channels': [{'id': channel, 'name': 'credit-verification'},
                                         {'id': 'CDEVOPS', 'name': 'clio_devops'}]}
    if method == 'conversations.history':
        return {'ok': True, 'messages': list(history['messages'])}
    if method == 'conversations.replies':
        return {'ok': True, 'messages': list(thread['messages'])}
    return {'ok': True}


jw.api = fake_api
tmp = tempfile.mkdtemp()
env = os.path.join(tmp, 'main.env')
open(env, 'w').write('MUSO_SLACK_BOT_TOKEN_OPERATIONS=xoxb-ops\n')
# Narrowed to one channel on purpose: the default scope is every readable
# channel, and this fixture serves the same message on two of them.
cfg = jw.build_config(jw.parse_args(['--env-file', env, '--state', os.path.join(tmp, 'state'),
                                     '--channels', 'credit-verification',
                                     '--grace-min', '30', '--recheck-limit', '5']))

ask_ts = '%.6f' % (now - 3600)
history['messages'] = [{'ts': ask_ts, 'user': 'U038BM16T7W', 'reply_count': 1,
                        'text': 'hide the profile from public'}]
thread['messages'] = [{'ts': ask_ts, 'user': 'U038BM16T7W', 'text': 'hide the profile from public'},
                      {'ts': '%.6f' % (now - 60), 'bot_id': 'B1', 'text': 'working on it'}]
state = jw.load_state(cfg.state)
first = jw.scan(cfg, state, time.time())
assert first['ok'], first
assert [r['ask_id'] for r in first['queue']] == ['%s:%s' % (channel, ask_ts)], first['queue']
assert first['queue'][0]['class'] == 'gdpr-hide'
assert first['queue'][0]['bot_reply_ts'] == '%.6f' % (now - 60)

second = jw.scan(cfg, state, time.time())
assert second['queue'] == [], 'an ask is queued exactly once: %r' % (second['queue'],)

# A lost handoff heals: once the cooldown lapses the still-uncoded ask is
# offered again, and the ledger dedupe is what keeps that silent.
# An answered ask in a class no coded answerer covers is still filed: the prose
# reply is not a handoff, so filing it is the whole point of the lane.
answer_ts = '%.6f' % (now - 1800)
history['messages'] = [{'ts': answer_ts, 'user': 'U038BM16T7W', 'reply_count': 1,
                        'text': 'please issue a refund for this card transaction'}]
thread['messages'] = [{'ts': answer_ts, 'user': 'U038BM16T7W',
                        'text': 'please issue a refund for this card transaction'},
                       {'ts': '%.6f' % (now - 1700), 'bot_id': 'B1',
                        'text': 'Refunded it, all good.'}]
answered = jw.scan(cfg, state, time.time())
assert [r['ask_id'] for r in answered['queue']] == ['%s:%s' % (channel, answer_ts)], answered['queue']
assert answered['queue'][0]['class'] == 'billing', answered['queue']
assert answered['queue'][0]['bot_reply_ts'], 'the answered ask is still filed'

cooldown_cfg = jw.build_config(jw.parse_args(['--env-file', env,
                                              '--state', os.path.join(tmp, 'state'),
                                              '--channels', 'credit-verification',
                                              '--grace-min', '30', '--recheck-limit', '5',
                                              '--emit-cooldown-secs', '0']))
reoffered = jw.scan(cooldown_cfg, state, time.time())
assert [r['ask_id'] for r in reoffered['queue']] == ['%s:%s' % (channel, ask_ts),
                                                     '%s:%s' % (channel, answer_ts)], reoffered['queue']

thread['messages'].append({'ts': '%.6f' % (now - 30), 'bot_id': 'B1',
                           'text': 'gdpr-hide - %s:%s - profile 42 - ledger zz9y' % (channel, ask_ts)})
third = jw.scan(cfg, state, time.time())
assert [c['ask_id'] for c in third['closed']] == ['%s:%s' % (channel, ask_ts)], third['closed']

# --- a partial page must not advance the cursor past the unread tail --------
# conversations.history is newest-first, so a failed second page leaves older
# messages unread. Advancing the cursor to the newest ts would skip them for
# good, which is exactly the ask loss this watch forbids.
partial_calls = {'n': 0}


def partial_api(token, method, timeout=20, **params):
    if method in ('conversations.list', 'users.conversations'):
        return {'ok': True, 'channels': [{'id': channel, 'name': 'credit-verification'}]}
    if method == 'conversations.history':
        partial_calls['n'] += 1
        if partial_calls['n'] == 1:
            return {'ok': True,
                    'messages': [{'ts': '%.6f' % (now - 3600), 'user': 'U038BM16T7W',
                                  'text': 'review the proof of the user'}],
                    'response_metadata': {'next_cursor': 'page-2'}}
        return {'ok': False, 'error': 'ratelimited'}
    return {'ok': True}


jw.api = partial_api
partial_cfg = jw.build_config(jw.parse_args(['--env-file', env,
                                             '--state', os.path.join(tmp, 'partial'),
                                             '--channels', 'credit-verification',
                                             '--grace-min', '30']))
partial_state = jw.load_state(partial_cfg.state)
old_cursor = '%.6f' % (now - 7200)
partial_state['cursors'][channel] = old_cursor
jw.scan(partial_cfg, partial_state, time.time())
assert partial_state['cursors'][channel] == old_cursor, partial_state['cursors']
assert channel not in partial_state['scanned'], partial_state['scanned']

# --- a staff ask written as a thread reply is filed ------------------------
# conversations.history returns only top-level messages, so an ask inside a
# thread is invisible unless the thread is read. This is the case the intent
# names: an ask can never be lost in a thread.
reply_history = {'messages': []}
reply_thread = {'messages': []}


def reply_api(token, method, timeout=20, **params):
    if method in ('conversations.list', 'users.conversations'):
        return {'ok': True, 'channels': [{'id': channel, 'name': 'credit-verification'}]}
    if method == 'conversations.history':
        return {'ok': True, 'messages': list(reply_history['messages'])}
    if method == 'conversations.replies':
        return {'ok': True, 'messages': list(reply_thread['messages'])}
    return {'ok': True}


jw.api = reply_api
parent_ts = '%.6f' % (now - 2400)
reply_ts = '%.6f' % (now - 2300)
reply_history['messages'] = [{'ts': parent_ts, 'user': 'U0NOTSTAFF', 'reply_count': 1,
                              'text': 'here is the proof'}]
reply_thread['messages'] = [{'ts': parent_ts, 'user': 'U0NOTSTAFF', 'text': 'here is the proof'},
                            {'ts': reply_ts, 'user': 'U038BM16T7W', 'subtype': 'file_share',
                             'text': 'also review the proof for the user 12345'}]
reply_cfg = jw.build_config(jw.parse_args(['--env-file', env,
                                           '--state', os.path.join(tmp, 'reply'),
                                           '--channels', 'credit-verification',
                                           '--grace-min', '30']))
reply_state = jw.load_state(reply_cfg.state)
reply_scan = jw.scan(reply_cfg, reply_state, time.time())
assert [r['ask_id'] for r in reply_scan['queue']] == ['%s:%s' % (channel, reply_ts)], reply_scan['queue']
assert reply_scan['queue'][0]['class'] == 'proof-review', reply_scan['queue']

# --- the recheck reads a reply ask's parent thread, not the child ts -------
# conversations.replies with a child ts returns only that message, so reading
# by record ts would hide a later ask posted in the same thread.
recheck_history = {'messages': []}
recheck_thread = {'messages': []}
recheck_calls = []


def recheck_api(token, method, timeout=20, **params):
    if method in ('conversations.list', 'users.conversations'):
        return {'ok': True, 'channels': [{'id': channel, 'name': 'credit-verification'}]}
    if method == 'conversations.history':
        return {'ok': True, 'messages': list(recheck_history['messages'])}
    if method == 'conversations.replies':
        recheck_calls.append(params.get('ts'))
        if params.get('ts') == parent_ts:
            return {'ok': True, 'messages': list(recheck_thread['messages'])}
        return {'ok': True, 'messages': [m for m in recheck_thread['messages']
                                         if m['ts'] == params.get('ts')]}
    return {'ok': True}


jw.api = recheck_api
recheck_cfg = jw.build_config(jw.parse_args(['--env-file', env,
                                             '--state', os.path.join(tmp, 'recheck'),
                                             '--channels', 'credit-verification',
                                             '--grace-min', '30']))
recheck_state = jw.load_state(recheck_cfg.state)
recheck_history['messages'] = [{'ts': parent_ts, 'user': 'U0NOTSTAFF', 'reply_count': 1,
                                'text': 'here is the proof'}]
recheck_thread['messages'] = [{'ts': parent_ts, 'user': 'U0NOTSTAFF', 'text': 'here is the proof'},
                              {'ts': reply_ts, 'thread_ts': parent_ts, 'user': 'U038BM16T7W',
                               'subtype': 'file_share',
                               'text': 'also review the proof for the user 12345'}]
first_recheck = jw.scan(recheck_cfg, recheck_state, time.time())
assert [r['ask_id'] for r in first_recheck['queue']] == ['%s:%s' % (channel, reply_ts)], first_recheck['queue']
# the parent falls out of the history window; a new ask arrives in its thread
later_ts = '%.6f' % (now - 2000)
recheck_history['messages'] = []
recheck_thread['messages'].append({'ts': later_ts, 'thread_ts': parent_ts,
                                   'user': 'U038BM16T7W',
                                   'text': 'review the proof for the user 999'})
second_recheck = jw.scan(recheck_cfg, recheck_state, time.time())
assert [r['ask_id'] for r in second_recheck['queue']] == ['%s:%s' % (channel, later_ts)], second_recheck['queue']
assert reply_ts not in recheck_calls, recheck_calls

# --- a thread that cannot be read is recorded as a gap, not skipped --------
def gap_api(token, method, timeout=20, **params):
    if method in ('conversations.list', 'users.conversations'):
        return {'ok': True, 'channels': [{'id': channel, 'name': 'credit-verification'}]}
    if method == 'conversations.history':
        return {'ok': True, 'messages': [{'ts': parent_ts, 'user': 'U0NOTSTAFF',
                                          'reply_count': 1, 'text': 'here is the proof'}]}
    if method == 'conversations.replies':
        return {'ok': False, 'error': 'missing_scope'}
    return {'ok': True}


jw.api = gap_api
gap_cfg = jw.build_config(jw.parse_args(['--env-file', env,
                                         '--state', os.path.join(tmp, 'gap'),
                                         '--channels', 'credit-verification',
                                         '--grace-min', '30']))
gap_state = jw.load_state(gap_cfg.state)
gap_scan = jw.scan(gap_cfg, gap_state, time.time())
assert gap_scan['gaps'] == [{'channel': channel, 'thread_ts': parent_ts,
                             'error': 'missing_scope'}], gap_scan['gaps']

# --- a failed thread read is retried without pinning the channel -----------
# The history page was fully read, so the cursor advances; the failed thread
# stays tracked and is retried on the next poll.
fail_calls = {'n': 0}


def fail_api(token, method, timeout=20, **params):
    if method in ('conversations.list', 'users.conversations'):
        return {'ok': True, 'channels': [{'id': channel, 'name': 'credit-verification'}]}
    if method == 'conversations.history':
        return {'ok': True, 'messages': [{'ts': parent_ts, 'user': 'U0NOTSTAFF',
                                          'reply_count': 1, 'text': 'here is the proof'}]}
    if method == 'conversations.replies':
        fail_calls['n'] += 1
        if fail_calls['n'] == 1:
            return {'ok': False, 'error': 'missing_scope'}
        return {'ok': True, 'messages': [
            {'ts': parent_ts, 'user': 'U0NOTSTAFF', 'text': 'here is the proof'},
            {'ts': reply_ts, 'thread_ts': parent_ts, 'user': 'U038BM16T7W',
             'subtype': 'file_share',
             'text': 'also review the proof for the user 12345'}]}
    return {'ok': True}


jw.api = fail_api
fail_cfg = jw.build_config(jw.parse_args(['--env-file', env,
                                          '--state', os.path.join(tmp, 'fail'),
                                          '--channels', 'credit-verification',
                                          '--grace-min', '30']))
fail_state = jw.load_state(fail_cfg.state)
old_cursor = '%.6f' % (now - 7200)
fail_state['cursors'][channel] = old_cursor
first_fail = jw.scan(fail_cfg, fail_state, time.time())
assert first_fail['gaps'] == [{'channel': channel, 'thread_ts': parent_ts,
                               'error': 'missing_scope'}], first_fail['gaps']
assert fail_state['cursors'][channel] == parent_ts, fail_state['cursors']
assert fail_state['threads']['%s:%s' % (channel, parent_ts)]['failures'] == 1, fail_state['threads']
second_fail = jw.scan(fail_cfg, fail_state, time.time())
assert [r['ask_id'] for r in second_fail['queue']] == ['%s:%s' % (channel, reply_ts)], second_fail['queue']
assert fail_state['threads']['%s:%s' % (channel, parent_ts)]['failures'] == 0, fail_state['threads']

# --- a permanently unreadable thread is retried a bounded number of times --
always_calls = {'n': 0}


def always_fail_api(token, method, timeout=20, **params):
    if method in ('conversations.list', 'users.conversations'):
        return {'ok': True, 'channels': [{'id': channel, 'name': 'credit-verification'}]}
    if method == 'conversations.history':
        return {'ok': True, 'messages': [{'ts': parent_ts, 'user': 'U0NOTSTAFF',
                                          'reply_count': 1, 'text': 'here is the proof'}]}
    if method == 'conversations.replies':
        always_calls['n'] += 1
        return {'ok': False, 'error': 'thread_not_found'}
    return {'ok': True}


jw.api = always_fail_api
bounded_cfg = jw.build_config(jw.parse_args(['--env-file', env,
                                             '--state', os.path.join(tmp, 'bounded'),
                                             '--channels', 'credit-verification',
                                             '--grace-min', '30']))
bounded_state = jw.load_state(bounded_cfg.state)
for _ in range(jw.THREAD_FAIL_LIMIT):
    bounded = jw.scan(bounded_cfg, bounded_state, time.time())
    assert bounded['gaps'] == [{'channel': channel, 'thread_ts': parent_ts,
                                'error': 'thread_not_found'}], bounded['gaps']
after_limit = jw.scan(bounded_cfg, bounded_state, time.time())
assert after_limit['gaps'] == [], after_limit['gaps']
assert always_calls['n'] == jw.THREAD_FAIL_LIMIT, always_calls
assert bounded_state['threads']['%s:%s' % (channel, parent_ts)]['failures'] == jw.THREAD_FAIL_LIMIT

# --- a new reply in a thread older than the cursor is still read -----------
# conversations.history never returns a reply, and the parent is behind the
# cursor, so the thread must be tracked and re-polled or the ask is lost.
tracked_history = {'messages': []}
tracked_thread = {'messages': []}


def tracked_api(token, method, timeout=20, **params):
    if method in ('conversations.list', 'users.conversations'):
        return {'ok': True, 'channels': [{'id': channel, 'name': 'credit-verification'}]}
    if method == 'conversations.history':
        return {'ok': True, 'messages': list(tracked_history['messages'])}
    if method == 'conversations.replies':
        return {'ok': True, 'messages': list(tracked_thread['messages'])}
    return {'ok': True}


jw.api = tracked_api
tracked_cfg = jw.build_config(jw.parse_args(['--env-file', env,
                                             '--state', os.path.join(tmp, 'tracked'),
                                             '--channels', 'credit-verification',
                                             '--grace-min', '30']))
tracked_state = jw.load_state(tracked_cfg.state)
coded_ts = '%.6f' % (now - 2300)
tracked_history['messages'] = [{'ts': parent_ts, 'user': 'U038BM16T7W', 'reply_count': 1,
                                'text': 'hide the profile from public'}]
tracked_thread['messages'] = [{'ts': parent_ts, 'user': 'U038BM16T7W',
                               'text': 'hide the profile from public'},
                              {'ts': coded_ts, 'thread_ts': parent_ts, 'bot_id': 'B1',
                               'text': 'gdpr-hide \u00b7 %s:%s \u00b7 ledger zz9y' % (channel, parent_ts)}]
first_tracked = jw.scan(tracked_cfg, tracked_state, time.time())
assert first_tracked['queue'] == [], first_tracked['queue']
assert tracked_state['asks']['%s:%s' % (channel, parent_ts)]['coded_ts'], tracked_state['asks']
# the parent is now behind the cursor and out of the history window
tracked_history['messages'] = []
later_ts = '%.6f' % (now - 2000)
tracked_thread['messages'].append({'ts': later_ts, 'thread_ts': parent_ts,
                                   'user': 'U038BM16T7W',
                                   'text': 'review the proof for the user 999'})
second_tracked = jw.scan(tracked_cfg, tracked_state, time.time())
assert [r['ask_id'] for r in second_tracked['queue']] == ['%s:%s' % (channel, later_ts)], second_tracked['queue']

# --- a bot reply to a later ask does not mark an earlier ask answered ------
# A's bot_reply_ts must stay empty when the bot answered B, not A.
note_record = {'ask_id': '%s:%s' % (channel, parent_ts), 'class': 'proof-review',
               'thread_ts': parent_ts, 'ts': parent_ts}
note_thread = [{'ts': parent_ts, 'user': 'U038BM16T7W', 'text': 'review the proof'},
               {'ts': reply_ts, 'thread_ts': parent_ts, 'user': 'U038BM16T7W',
                'text': 'review the proof for the user 999'},
               {'ts': '%.6f' % (now - 2200), 'thread_ts': parent_ts, 'bot_id': 'B1',
                'text': 'Proof review (user 999)'}]
assert jw.note_replies(note_record, note_thread) is None, note_record
assert not note_record.get('bot_reply_ts'), note_record
PY

# --- the ledger and board formats -------------------------------------------

python3 - "$LIB" <<'PY' || fail 'the ledger and board formats file once, close by ask id, and count by filing day'
import importlib.util, sys, time

spec = importlib.util.spec_from_file_location('jan_lib', sys.argv[1])
jl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jl)

ask_id = 'C0APB2CMM7C:1793824709.431389'
record = {'ask_id': ask_id, 'who': 'Jan', 'conv': 'credit-verification',
          'class': 'proof-review', 'text': 'review the proof',
          'link': 'https://muso-ai.slack.com/archives/C0APB2CMM7C/p1793824709431389',
          'age_min': 42, 'answered': 'no'}
line = jl.ask_line(record, 1793825000)
assert ask_id in line, line
assert 'need firstmate: task' in line, line
assert '| proof-review |' in line, line

# A line is closed only by a record carrying its ask id.
opened, resolved, order = jl.parse_ledger([line])
assert list(opened) == [ask_id], opened
assert resolved == {}, resolved
assert order == [ask_id], order
closed = jl.resolve_line(ask_id, 'coded card in thread', 1793826000)
opened, resolved, order = jl.parse_ledger([line, closed])
assert ask_id in resolved, resolved
assert order == [ask_id], order

# An ask whose staff text quotes a prior resolution is still an opened ask.
quoted = jl.ask_line(dict(record, text='see [resolved %s] for context' % ask_id), 1793825000)
opened, resolved, order = jl.parse_ledger([quoted])
assert list(opened) == [ask_id], opened
assert resolved == {}, resolved
assert order == [ask_id], order

# "filed today" counts the ledger stamp, not the ask's Slack arrival: an ask
# that arrives at 23:50 and is filed by the 00:20 poll belongs to today.
arrival = 1793836200   # 2026-11-04 23:50Z
filed = 1793838000     # 2026-11-05 00:20Z, the poll that filed it
opened = {ask_id: {'ts': arrival, 'filed_ts': filed}}
assert jl.count_filed_today(opened, [ask_id], filed) == 1
assert jl.count_filed_today(opened, [ask_id], arrival) == 0, 'counting by arrival would miss it'

# The board groups by staff then class, oldest first, and reports the budget.
parsed, _, parsed_order = jl.parse_ledger([line])
board = jl.build_board_json(parsed, {}, parsed_order, filed, 30, '/tmp/ledger', '/tmp/board.json')
assert board['budget'] == 30, board
assert board['counts']['proof-review']['open'] == 1, board
assert board['open'][0]['who'] == 'Jan', board
html = jl.render_board(board, 30, filed)
assert 'proof-review' in html, html
assert 'Jan' in html, html
PY

pass 'the scanner classifies, attributes, and closes correctly, and the ledger and board formats hold'
