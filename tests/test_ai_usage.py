import importlib.util
import json
import sqlite3
from datetime import datetime
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    'sea_ai_usage', ROOT / 'quickshell/scripts/system/sea-ai-usage.py')
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


class AiUsageTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.home = Path(self.dir.name)
        self.now = datetime.now().astimezone()
        self.day = self.now.date()
        self.claude = self.home / 'claude'
        self.codex = self.home / 'sessions' / f'{self.day.year:04d}' / f'{self.day.month:02d}' / f'{self.day.day:02d}'
        self.claude.mkdir()
        self.codex.mkdir(parents=True)
        self.index = self.home / 'index.json'
        self.db = self.home / 'cursor.db'

    def _collect(self):
        return usage.collect(self.claude, self.codex, self.db, self.index, now=self.now)

    def test_claude_tokens_and_codex_turns_stay_in_their_own_units(self):
        stamp = self.now.isoformat()
        (self.claude / 'session.jsonl').write_text(json.dumps({
            'type': 'assistant',
            'timestamp': stamp,
            'message': {
                'model': 'claude-opus',
                'usage': {
                    'input_tokens': 10,
                    'output_tokens': 5,
                    'cache_read_input_tokens': 100,
                    'cache_creation_input_tokens': 20,
                },
            },
        }) + '\n')
        (self.codex / 'rollout.jsonl').write_text(json.dumps({
            'type': 'token_usage_record',
            'payload': {'usage': {'total_tokens': 400, 'input_tokens': 300, 'output_tokens': 100}},
        }) + '\n')
        con = sqlite3.connect(self.db)
        con.execute('CREATE TABLE ai_code_hashes (hash TEXT, source TEXT, fileExtension TEXT, fileName TEXT, requestId TEXT, conversationId TEXT, timestamp INTEGER, model TEXT, createdAt INTEGER)')
        ms = int(self.now.timestamp() * 1000)
        con.execute('INSERT INTO ai_code_hashes VALUES (?,?,?,?,?,?,?,?,?)',
                    ('h1', 'composer', 'py', 'a.py', 'req-1', 'c', ms, 'composer-2.5', ms))
        con.execute('INSERT INTO ai_code_hashes VALUES (?,?,?,?,?,?,?,?,?)',
                    ('h2', 'composer', 'py', 'a.py', 'req-1', 'c', ms, 'composer-2.5', ms))
        con.execute('INSERT INTO ai_code_hashes VALUES (?,?,?,?,?,?,?,?,?)',
                    ('h3', 'composer', 'py', 'b.py', 'req-2', 'c', ms, 'grok-4.7', ms))
        con.commit()
        con.close()

        report = self._collect()
        by = {t['id']: t for t in report['tools']}
        self.assertEqual(by['claude']['today'], 135)
        self.assertEqual(by['claude']['unit'], 'tokens')
        self.assertEqual(by['claude']['todayLabel'], '135')
        self.assertEqual(by['codex']['today'], 400)
        self.assertEqual(by['codex']['unit'], 'tokens')
        # two hash rows, one request
        self.assertEqual(by['cursor']['today'], 1)
        self.assertEqual(by['cursor']['unit'], 'requests')
        self.assertEqual(by['cursor']['detail'], '')
        self.assertEqual(by['grok']['today'], 1)
        self.assertEqual(report['lead']['name'], 'Codex')

        again = self._collect()
        self.assertEqual(again['tools'][0]['today'], 135)

    def test_a_changed_log_is_counted_again(self):
        stamp = self.now.isoformat()
        path = self.claude / 'session.jsonl'
        path.write_text(json.dumps({
            'type': 'assistant', 'timestamp': stamp,
            'message': {'model': 'claude-opus', 'usage': {'input_tokens': 10, 'output_tokens': 0}},
        }) + '\n')
        self.assertEqual(self._collect()['tools'][0]['today'], 10)
        path.write_text(path.read_text() + json.dumps({
            'type': 'assistant', 'timestamp': stamp,
            'message': {'model': 'claude-opus', 'usage': {'output_tokens': 5}},
        }) + '\n')
        self.assertEqual(self._collect()['tools'][0]['today'], 15)

    def test_thousands_of_tokens_stay_short(self):
        self.assertEqual(usage.format_count(135, 'tokens'), '135')
        self.assertEqual(usage.format_count(1500, 'tokens'), '1.5k')
        self.assertEqual(usage.format_count(12_400_000, 'tokens'), '12.4M')
        self.assertEqual(usage.format_count(3, 'requests'), '3')


class PlanUsageTests(unittest.TestCase):
    def test_claude_remaining_is_the_tighter_window_and_names_its_reset(self):
        now = datetime(2026, 11, 4, 14, 0, tzinfo=datetime.now().astimezone().tzinfo)
        row = usage.parse_claude_usage({
            'five_hour': {'utilization': 0.20, 'resets_at': '2026-11-04T18:40:00+08:00'},
            'seven_day': {'utilization': 0.62, 'resets_at': '2026-11-10T08:00:00+08:00'},
        }, now)
        self.assertEqual(row['id'], 'claude')
        self.assertEqual(row['unit'], 'left')
        self.assertEqual(row['today'], 38)
        self.assertEqual(row['todayLabel'], '38%')
        self.assertEqual(row['model'], 'Weekly (7 day)')
        self.assertIn('Nov 10', row['weekLabel'])
        self.assertIn('Session (5hr) 80% left', row['detail'])
        self.assertEqual([w['label'] for w in row['windows']], ['Session (5hr)', 'Weekly (7 day)'])
        self.assertEqual(row['windows'][0]['used'], 20)
        self.assertEqual(row['windows'][1]['used'], 62)
        # Twenty minutes into the session is too little to call a pace.
        self.assertEqual(row['windows'][0]['pace'], '')
        # 62% across 1.25 days of a 7 day window, with 38% still left.
        self.assertEqual(row['windows'][1]['pace'], 'About 50% a day · full in 18 hr')
        self.assertEqual(row['pace'], row['windows'][1]['pace'])
        self.assertEqual(row['warn']['title'], 'Claude')
        self.assertIn('Weekly', row['warn']['body'])
        self.assertIn('18 hr', row['warn']['body'])

    def test_usage_past_80_and_95_percent_warns_once_per_level(self):
        week = {'label': 'Weekly', 'used': 83.5, 'resetAt': '2026-11-10T08:00:00+08:00',
                'reset': 'Resets Tue, Nov 10 at 8:00 am', 'fills': False}
        warn = usage._warn('cursor', 'Cursor', [week])
        self.assertTrue(warn['key'].endswith('|80'))
        self.assertEqual(warn['body'], 'Weekly is 83.5% used. Resets Tue, Nov 10 at 8:00 am.')
        paced = usage._warn('cursor', 'Cursor', [dict(week, fills=True, paceWhen='5 hr', fillsIn=18000)])
        self.assertIn('on track to fill in 5 hr', paced['body'])
        full = usage._warn('cursor', 'Cursor', [dict(week, used=96, fills=True, paceWhen='1 hr', fillsIn=3600)])
        self.assertTrue(full['key'].endswith('|95'))
        self.assertIsNone(usage._warn('cursor', 'Cursor', [dict(week, used=40)]))

    def test_cursor_and_grok_are_separate_allowances(self):
        now = datetime(2026, 11, 4, 14, 0, tzinfo=datetime.now().astimezone().tzinfo)
        cursor = usage.parse_cursor_usage(
            {'planUsage': {'totalPercentUsed': 23}},
            {'planInfo': {
                'includedUsagePeriod': 'WEEKLY',
                'includedUsageResetsAt': '2026-11-07T00:00:00+08:00',
            }},
            now,
        )
        grok = usage.parse_grok_usage(
            {
                'usagePercent': 10,
                'grokPlanLabel': 'SuperGrok',
                'nextResetTimestampUtc': '2026-11-08T00:00:00+08:00',
            },
            cursor['today'],
            now,
        )
        same = usage.parse_grok_usage({'usagePercent': 23}, cursor['today'], now)
        self.assertEqual(cursor['today'], 77)
        self.assertEqual(cursor['model'], 'weekly')
        self.assertIn('Nov 7', cursor['weekLabel'])
        self.assertEqual(cursor['pace'], 'About 5% a day · full in 15 days')
        self.assertIsNone(cursor['warn'])
        bars = usage.week_bars(40, '2026-11-08T14:00:00+08:00', 7 * 86400, {
            '2026-11-02': 1,
            '2026-11-03': 1,
            '2026-11-04': 2,
        }, now)
        self.assertEqual([b['label'] for b in bars], ['Su', 'Mo', 'Tu', 'We'])
        self.assertEqual([b['used'] for b in bars], [0.0, 10.0, 10.0, 20.0])
        self.assertTrue(bars[-1]['today'])
        self.assertIsNone(usage.session_id('cursor', b'/opt/cursor/cursor\0--type=renderer'))
        self.assertEqual(usage.session_id('node', b'cursor-agent\0/versions/cursor-agent/index.js'), 'cursor')
        self.assertEqual(usage.session_id('cursorsandbox'), 'cursor')
        self.assertTrue(usage.mark_running([{'id': 'cursor'}], {'cursor'})[0]['running'])
        self.assertEqual(grok['id'], 'grok')
        self.assertEqual(grok['today'], 90)
        self.assertEqual(grok['model'], 'SuperGrok')
        self.assertIsNone(same)
        merged = usage.merge_shared_pool([cursor, grok])
        self.assertEqual([t['id'] for t in merged], ['cursor'])
        self.assertEqual(merged[0]['name'], 'Cursor · Grok')
        self.assertEqual(merged[0]['with'], 'grok')
        self.assertEqual(merged[0]['today'], 77)
        marked = usage.mark_running(merged, {'claude'})
        self.assertTrue(marked[0].get('running') is False)
        claude = usage.mark_running([{'id': 'claude'}, {'id': 'codex'}], {'claude'})
        self.assertTrue(claude[0]['running'])
        self.assertFalse(claude[1]['running'])
        alt = usage.as_cursor_account(merged, 'cursor-alt')
        self.assertEqual(alt[0]['id'], 'cursor-alt')
        self.assertEqual(alt[0]['name'], 'Cursor alt · Grok')
        self.assertEqual(merged[0]['id'], 'cursor')
        self.assertEqual(usage.as_cursor_account(merged, 'cursor-alt2')[0]['name'], 'Cursor alt 2 · Grok')
        self.assertIs(usage.as_cursor_account(merged, 'cursor'), merged)

    def test_cursor_percent_under_one_is_not_a_fraction(self):
        now = datetime(2026, 11, 10, 7, 0, tzinfo=datetime.now().astimezone().tzinfo)
        row = usage.parse_cursor_usage(
            {'planUsage': {'totalPercentUsed': 0.28169014084507044}},
            {'planInfo': {'includedUsagePeriod': 'INCLUDED_USAGE_PERIOD_WEEKLY',
                          'includedUsageResetsAt': '1794626644390'}},
            now,
        )
        self.assertEqual(row['windows'][0]['used'], 0.28)
        self.assertEqual(row['today'], 99.72)
        grok = usage.parse_grok_usage({'usagePercent': 0.28, 'grokPlanLabel': 'Grok Bot Plan'}, None, now)
        self.assertEqual(grok['today'], 99.72)

    def test_a_failed_fetch_keeps_the_last_good_rows_for_an_hour(self):
        now = datetime(2026, 11, 4, 14, 0, tzinfo=datetime.now().astimezone().tzinfo)
        stamp = now.timestamp()
        good = [{'id': 'cursor', 'today': 40}]
        shown, saved = usage.keep_last_good({'cursor': good}, {}, now)
        self.assertEqual(shown['cursor'], good)
        self.assertEqual(saved['cursor']['rows'], good)
        cache = {'cursor': {'at': stamp - 600, 'rows': good}, 'claude': {'at': stamp - 7200, 'rows': [{'id': 'claude'}]}}
        shown, saved = usage.keep_last_good({'cursor': None, 'claude': None}, cache, now)
        self.assertEqual(shown['cursor'][0]['today'], 40)
        self.assertTrue(shown['cursor'][0]['stale'])
        self.assertEqual(saved['cursor'], cache['cursor'])
        self.assertEqual(shown['claude'], [])
        self.assertNotIn('claude', saved)

    def test_gpt_window_uses_remaining_percent(self):
        now = datetime(2026, 11, 4, 14, 0, tzinfo=datetime.now().astimezone().tzinfo)
        row = usage.parse_codex_usage({
            'rate_limit': {
                'primary_window': {
                    'used_percent': 15,
                    'limit_window_seconds': 18000,
                    'reset_at': int(now.timestamp()) + 3600,
                },
                'secondary_window': {
                    'remaining_percent': 40,
                    'limit_window_seconds': 604800,
                    'reset_after_seconds': 86400,
                },
            },
        }, now)
        self.assertEqual(row['name'], 'GPT')
        self.assertEqual(row['id'], 'codex')
        self.assertEqual(row['today'], 40)
        self.assertEqual(row['model'], 'Weekly')
        self.assertIn('Session (5hr) 85% left', row['detail'])
        self.assertEqual(row['windows'][0]['label'], 'Session (5hr)')
        self.assertEqual(row['windows'][0]['used'], 15)

    def test_gemini_quota_buckets_fold_into_five_hour(self):
        now = datetime(2026, 11, 4, 14, 0, tzinfo=datetime.now().astimezone().tzinfo)
        row = usage.parse_gemini_usage({
            'buckets': [
                {'modelId': 'gemini-2.5-pro', 'remainingFraction': 0.42,
                 'resetTime': '2026-11-04T19:00:00+08:00'},
                {'modelId': 'gemini-2.5-flash', 'remainingFraction': 0.88,
                 'resetTime': '2026-11-10T08:00:00+08:00'},
            ],
        }, now)
        self.assertEqual(row['id'], 'gemini')
        self.assertEqual(row['name'], 'Antigravity')
        self.assertEqual(row['today'], 42)
        self.assertEqual(row['model'], 'Gemini five hour')

    def test_antigravity_quota_summary_matches_models_and_usage(self):
        now = datetime(2026, 11, 20, 12, 0, tzinfo=datetime.now().astimezone().tzinfo)
        row = usage.parse_antigravity_quota_summary({
            'groups': [
                {'displayName': 'Gemini Models', 'buckets': [
                    {'bucketId': 'gemini-5h', 'remainingFraction': 1.0,
                     'resetTime': '2026-11-20T17:00:00+08:00'},
                    {'bucketId': 'gemini-weekly', 'remainingFraction': 1.0,
                     'resetTime': '2026-11-27T12:00:00+08:00'},
                ]},
                {'displayName': 'Claude and GPT models', 'buckets': [
                    {'bucketId': '3p-5h', 'remainingFraction': 0.37,
                     'resetTime': '2026-11-20T17:00:00+08:00'},
                    {'bucketId': '3p-weekly', 'remainingFraction': 0.69,
                     'resetTime': '2026-11-27T12:00:00+08:00'},
                ]},
                {'displayName': 'Gemini 4 Argon', 'buckets': [
                    {'bucketId': 'gemini-argon-wtu-weekly', 'remainingFraction': 1.0,
                     'resetTime': '2026-11-27T12:00:00+08:00'},
                ]},
            ],
        }, now)
        self.assertEqual(row['id'], 'gemini')
        self.assertEqual(row['name'], 'Antigravity')
        self.assertEqual(row['today'], 37)
        self.assertEqual(row['model'], 'Claude/GPT five hour')
        self.assertEqual([w['label'] for w in row['windows']], [
            'Gemini weekly', 'Gemini five hour',
            'Claude/GPT weekly', 'Claude/GPT five hour',
            'Argon weekly',
        ])

    def test_antigravity_user_status_folds_into_five_hour_groups(self):
        now = datetime(2026, 11, 20, 12, 0, tzinfo=datetime.now().astimezone().tzinfo)
        row = usage.parse_antigravity_user_status({
            'userStatus': {
                'planStatus': {'planInfo': {'planName': 'Pro'}},
                'cascadeModelConfigData': {'clientModelConfigs': [
                    {'label': 'Gemini 3 Pro (High)',
                     'quotaInfo': {'remainingFraction': 0.7,
                                   'resetTime': '2026-11-20T17:00:00+08:00'}},
                    {'label': 'Claude Sonnet 4.5',
                     'quotaInfo': {'remainingFraction': 0.1}},
                    {'label': 'Gemini 3 Flash',
                     'quotaInfo': {'remainingFraction': 0.95}},
                ]},
            },
        }, now)
        self.assertEqual(row['id'], 'gemini')
        self.assertEqual(row['name'], 'Antigravity · Pro')
        self.assertEqual(row['today'], 10)
        self.assertEqual(row['model'], 'Claude/GPT five hour')
        labels = {w['label'] for w in row['windows']}
        self.assertEqual(labels, {'Gemini five hour', 'Claude/GPT five hour'})


if __name__ == '__main__':
    unittest.main()
