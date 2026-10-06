"""Tests for the Mission Control server: pipeline rules, data intake, and the state the screen renders.

Run: python3 -m unittest discover -s mission-control/tests
"""
import gzip
import io
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

os.environ['TZ'] = 'UTC'   # "today" is part of what the page shows; pin it so the fixtures mean the same everywhere
time.tzset()

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..'))

import fixtures as fx  # noqa: E402
import server  # noqa: E402
from mc import github, ingest, pipeline, state  # noqa: E402
from mc.store import Store  # noqa: E402

REPO = fx.REPO
PLUGIN = os.path.join(HERE, '..', '..')
HOOK = os.path.join(HERE, '..', 'hook.sh')
SERVER = os.path.join(HERE, '..', 'server.py')
NOW = fx.T0 + 4000


class FakeRepos:
    """Every working directory is the shop repo, checked out on issue 3's branch."""

    def lookup(self, cwd):
        return REPO, 'feat/3-password-reset'


def seeded(data=None):
    store = Store()
    store.add_repo(REPO)
    github.apply(store, REPO, data or fx.repo_data())
    return store


def by_n(doc):
    return {r['n']: r for r in doc['requests']}


def line(data, now=NOW):
    """The requests on the line for one fetch of the shop repo, by issue number."""
    return by_n(state.build(seeded(data), REPO, now=now))


def journey(request):
    return [(s['slot'], s['round']) for s in request['stops']]


class PipelineRules(unittest.TestCase):
    def test_only_this_plugins_agents_are_pipeline_agents(self):
        self.assertEqual(pipeline.station_for('adlc:builder'), 'builder')
        self.assertEqual(pipeline.station_for('adlc:adversarial-reviewer'), 'reviewer')
        for other in ('builder', 'other-plugin:builder', 'architect', 'Explore', 'custom', '', None, 7):
            self.assertIsNone(pipeline.station_for(other), other)

    def test_prompt_refs(self):
        self.assertEqual(pipeline.refs_in('You are the ADLC Builder. Implement issue #142 following its ADR.'), (142, None))
        self.assertEqual(pipeline.refs_in('Review PR #156 in fresh context'), (None, 156))
        self.assertEqual(pipeline.refs_in('Gate the PR linked to issue #9.'), (9, None))
        self.assertEqual(pipeline.refs_in('no numbers here'), (None, None))

    def test_a_branch_names_its_issue_by_the_pipelines_own_rule(self):
        # the same cases as tests/run.sh checks against templates/scripts/adlc-branch-issue.sh
        self.assertEqual(pipeline.issue_in_branch('feat/142-password-reset'), 142)
        self.assertEqual(pipeline.issue_in_branch('feat/142'), 142)
        for branch in ('main', 'fix/diff-scope', 'feat/area/12-deeper', '', None):
            self.assertIsNone(pipeline.issue_in_branch(branch), branch)

    def test_the_label_added_last_says_where_an_issue_stands(self):
        both = ['stage:intake', 'gate:stories']
        self.assertEqual(pipeline.slot_for_labels(both)[0], 'gate1')                # no history: the later stage
        returned = [{'label': 'stage:intake', 'added': 1, 'ts': 100}, {'label': 'gate:stories', 'added': 1, 'ts': 400}, {'label': 'stage:intake', 'added': 1, 'ts': 900}]
        self.assertEqual(pipeline.slot_for_labels(both, returned), ('analyst', 'stage:intake'))   # stories returned: the Analyst has it again
        self.assertEqual(pipeline.slot_for_labels(['stage:qa', 'gate:deploy'], [{'label': 'stage:qa', 'added': 1, 'ts': 1}, {'label': 'gate:deploy', 'added': 1, 'ts': 2}])[0], 'gate2')
        self.assertEqual(pipeline.slot_for_labels(['bug', 'question']), (None, None))

    def test_step_labels_are_plain(self):
        self.assertEqual(pipeline.step_label('Read', {'file_path': '/work/shop/src/a.ts'}, '/work/shop'), ('read', 'Reading src/a.ts'))
        self.assertEqual(pipeline.step_label('Bash', {'command': 'gh pr create --fill'})[0], 'gh')
        self.assertEqual(pipeline.step_label('Bash', {'command': 'npm test', 'description': 'Run the tests'}), ('bash', 'Run the tests'))

    def test_agent_file_is_read(self):
        info = pipeline.read_agent(PLUGIN, 'builder')
        self.assertTrue(info['prompt'].startswith('You are the **Builder**'))
        self.assertIn('Bash', info['tools'])
        # A narrow role's limits come from the guard hook, not from the agent file: they replace its bare "Bash".
        reviewer = pipeline.read_agent(PLUGIN, 'reviewer')['tools']
        self.assertIn('gh pr diff', reviewer)
        self.assertIn('git (read-only)', reviewer)
        self.assertNotIn('Bash', reviewer)
        analyst = pipeline.read_agent(PLUGIN, 'analyst')['tools']
        self.assertIn('gh issue edit', analyst)
        self.assertNotIn('gh issue delete', analyst)

    def test_a_remote_in_any_form_names_the_repo(self):
        for url in ('git@github.com:acme/shop.git', 'https://github.com/acme/shop', 'https://github.com/Acme/Shop.git/',
                    'ssh://git@github.com/acme/shop', 'git@github-work:acme/shop.git'):
            self.assertEqual(ingest.parse_remote(url), REPO, url)
        self.assertIsNone(ingest.parse_remote(''))
        self.assertIsNone(ingest.parse_remote('shop'))


class Intake(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.ing = ingest.Ingest(self.store, repos=FakeRepos())

    def test_a_run_and_its_steps(self):
        t = fx.T0 + 1510
        self.ing.hook(fx.hook('SessionStart'), now=t)
        self.ing.hook(fx.hook('UserPromptSubmit', prompt='You are the ADLC Builder. Implement issue #3 following its task breakdown.'), now=t + 1)
        self.ing.hook(fx.hook('PreToolUse', tool_name='Read', tool_input={'file_path': '/work/shop/docs/adr/0007.md'}, tool_use_id='t1'), now=t + 2)
        self.ing.hook(fx.hook('PostToolUse', tool_name='Read', tool_input={'file_path': '/work/shop/docs/adr/0007.md'}, tool_use_id='t1',
                              tool_response='...'), now=t + 4)
        self.ing.hook(fx.hook('PreToolUse', tool_name='Edit', tool_input={'file_path': '/work/shop/src/reset.ts'}, tool_use_id='t2'), now=t + 5)
        run = self.store.run('s-build')
        self.assertEqual((run['station'], run['repo'], run['issue']), ('builder', REPO, 3))
        steps = self.store.steps('s-build')
        self.assertEqual([s['label'] for s in steps], ['Reading docs/adr/0007.md', 'Editing src/reset.ts'])
        self.assertEqual(steps[0]['ended'], t + 4)
        self.assertIsNone(steps[1]['ended'])
        self.ing.hook(fx.hook('Stop', last_assistant_message='Opened PR #9.'), now=t + 60)
        run = self.store.run('s-build')
        self.assertEqual((run['ended'], run['report']), (t + 60, 'Opened PR #9.'))
        self.assertIsNotNone(self.store.steps('s-build')[1]['ended'])

    def test_what_a_tool_returned_is_not_kept(self):
        self.ing.hook(fx.hook('PreToolUse', tool_name='Bash', tool_input={'command': 'cat .env'}, tool_use_id='t1'), now=fx.T0)
        self.ing.hook(fx.hook('PostToolUse', tool_name='Bash', tool_input={'command': 'cat .env'}, tool_use_id='t1', tool_response='SECRET=hunter2'), now=fx.T0 + 1)
        self.assertNotIn('hunter2', json.dumps(self.store.q('SELECT * FROM steps') + self.store.q('SELECT * FROM runs')))

    def test_sessions_outside_the_pipeline_are_dropped(self):
        for agent in (None, 'Explore', 'builder', 'other-plugin:builder'):
            self.assertFalse(self.ing.hook(fx.hook('PreToolUse', agent=agent, tool_name='Bash', tool_input={'command': 'ls'})), agent)
        self.assertEqual(self.store.q('SELECT * FROM runs'), [])

    def test_each_subagent_gets_the_prompt_its_parent_gave_it(self):
        hand = lambda n: fx.hook('PreToolUse', session='s-main', agent=None, tool_name='Agent',
                                 tool_input={'subagent_type': 'adlc:adversarial-reviewer', 'prompt': 'Review PR #%d in fresh context.' % n})
        self.ing.hook(hand(10), now=fx.T0)
        self.ing.hook(hand(11), now=fx.T0)                       # two reviewers started by one parent, in one message
        self.ing.hook(fx.hook('SubagentStart', session='s-main', agent='adlc:adversarial-reviewer', agent_id='a1'), now=fx.T0 + 1)
        self.ing.hook(fx.hook('SubagentStart', session='s-main', agent='adlc:adversarial-reviewer', agent_id='a2'), now=fx.T0 + 1)
        first, second = self.store.run('s-main:a1'), self.store.run('s-main:a2')
        self.assertEqual((first['station'], first['pr'], first['prompt']), ('reviewer', 10, 'Review PR #10 in fresh context.'))
        self.assertEqual((second['pr'], second['prompt']), (11, 'Review PR #11 in fresh context.'))
        # a prompt whose subagent never started (the call was denied) is not handed to a later one
        self.ing.hook(hand(12), now=fx.T0 + 10)
        self.ing.hook(fx.hook('SubagentStart', session='s-main', agent='adlc:adversarial-reviewer', agent_id='a3'), now=fx.T0 + 10 + ingest.HANDOFF_TTL + 1)
        self.assertIsNone(self.store.run('s-main:a3')['prompt'])

    def test_what_the_prompt_names_wins_over_the_branch(self):
        # FakeRepos puts every checkout on feat/3-...: a review of PR 10 run from there is not work on issue 3
        self.ing.hook(fx.hook('SessionStart', session='s-rev', agent='adlc:adversarial-reviewer'), now=fx.T0)
        self.assertEqual(self.store.run('s-rev')['issue'], 3)                      # nothing but the branch to go by yet
        self.ing.hook(fx.hook('UserPromptSubmit', session='s-rev', agent='adlc:adversarial-reviewer', prompt='Review PR #10 in fresh context.'), now=fx.T0 + 1)
        run = self.store.run('s-rev')
        self.assertEqual((run['issue'], run['pr']), (None, 10))

    def test_a_later_prompt_moves_the_run_only_when_it_names_another_request(self):
        self.ing.hook(fx.hook('UserPromptSubmit', prompt='Implement issue #3.'), now=fx.T0)
        self.ing.hook(fx.hook('Stop'), now=fx.T0 + 50)
        self.ing.hook(fx.hook('UserPromptSubmit', prompt='Also add a test for the empty case.'), now=fx.T0 + 60)
        run = self.store.run('s-build')
        self.assertEqual((run['issue'], run['prompt'], run['ended']), (3, 'Implement issue #3.', None))   # live again, same task
        self.ing.hook(fx.hook('Stop'), now=fx.T0 + 90)
        self.ing.hook(fx.hook('UserPromptSubmit', prompt='Now implement issue #8.'), now=fx.T0 + 100)
        run = self.store.run('s-build')
        self.assertEqual((run['issue'], run['prompt']), (8, 'Now implement issue #8.'))

    def test_a_late_result_does_not_bring_a_finished_run_back(self):
        self.ing.hook(fx.hook('PreToolUse', tool_name='Bash', tool_input={'command': 'npm test'}, tool_use_id='t1'), now=fx.T0)
        self.ing.hook(fx.hook('Stop'), now=fx.T0 + 5)
        self.ing.hook(fx.hook('PostToolUse', tool_name='Bash', tool_input={'command': 'npm test'}, tool_use_id='t1'), now=fx.T0 + 6)
        self.assertEqual(self.store.run('s-build')['ended'], fx.T0 + 5)

    def test_a_call_that_never_reported_back_is_ended_by_the_next_one(self):
        pre = lambda tid, cmd, t: self.ing.hook(fx.hook('PreToolUse', tool_name='Bash', tool_input={'command': cmd}, tool_use_id=tid), now=t)
        post = lambda tid, cmd, t: self.ing.hook(fx.hook('PostToolUse', tool_name='Bash', tool_input={'command': cmd}, tool_use_id=tid), now=t)
        pre('t1', 'gh pr merge 11', fx.T0)             # denied: no PostToolUse ever comes
        pre('t2', 'npm test', fx.T0 + 5)
        post('t2', 'npm test', fx.T0 + 9)
        pre('t3', 'git status', fx.T0 + 10)
        steps = {s['tool_use_id']: s for s in self.store.steps('s-build')}
        self.assertEqual((steps['t1']['ended'], steps['t1']['ok']), (fx.T0 + 9, 0))
        self.assertIsNone(steps['t3']['ended'])

    def test_telemetry_lands_on_the_right_run(self):
        self.ing.hook(fx.hook('SessionStart'), now=fx.T0 + 1510)
        # a session started as `claude --agent adlc:builder`: its replies name no agent
        self.assertEqual(self.ing.otlp_logs(fx.otlp('s-build', None, n=2)), 2)
        total = self.store.api_sum(['s-build'])
        self.assertEqual((total['input'], total['cacheRead'], total['output'], total['replies']), (2400, 40000, 600, 2))
        self.assertAlmostEqual(total['usd'], 0.04)
        self.assertEqual(self.store.run('s-build')['model'], 'fable')
        # a pipeline subagent: its replies carry its name, and join its own run, not the parent's
        self.ing.hook(fx.hook('SubagentStart', session='s-main', agent='adlc:qa-release-ops', agent_id='q1'), now=fx.T0 + 1590)
        self.assertEqual(self.ing.otlp_logs(fx.otlp('s-main', 'adlc:qa-release-ops')), 1)
        self.assertEqual(self.store.api_sum(['s-main:q1'])['replies'], 1)
        # replies that are not a pipeline agent's are not kept, and open no run
        for name in ('Explore', 'custom', 'other-plugin:builder'):
            self.assertEqual(self.ing.otlp_logs(fx.otlp('s-build', name)), 0, name)
        self.assertEqual(self.ing.otlp_logs(fx.otlp('s-unknown', 'adlc:builder')), 0)
        self.assertEqual(self.ing.otlp_logs(fx.otlp('s-unknown', None)), 0)
        self.assertEqual(len(self.store.q('SELECT * FROM runs')), 2)

    def test_numbers_that_are_not_numbers_are_stored_as_zero(self):
        self.ing.hook(fx.hook('SessionStart'), now=fx.T0)
        self.assertEqual(self.ing.otlp_logs(fx.otlp('s-build', None, cost_usd='Infinity', input_tokens='1e999', duration_ms='soon')), 1)
        row = self.store.api_rows('s-build')[0]
        self.assertEqual((row['cost'], row['input'], row['ms']), (0.0, 0, 0.0))
        self.assertEqual(self.ing.otlp_logs({'resourceLogs': {'not': 'a list'}}), 0)
        self.assertEqual(self.ing.otlp_logs({'resourceLogs': [None, {'scopeLogs': [{'logRecords': ['x', {'attributes': 'x'}]}]}]}), 0)


class Line(unittest.TestCase):
    def test_where_each_request_stands(self):
        doc = state.build(seeded(), REPO, now=NOW)
        r = by_n(doc)
        self.assertEqual(sorted(r), [1, 2, 3, 4, 5, 6])              # issue 7 is not on the line
        self.assertEqual((r[1]['at'], r[1]['phase']), ('analyst', 'queued'))
        self.assertEqual((r[2]['at'], r[2]['phase'], r[2]['fastRec'], r[2]['lane']), ('gate1', 'waiting', True, 'full'))
        self.assertEqual((r[3]['at'], r[3]['adr'], r[3]['epic']), ('builder', 7, 'Account security'))
        self.assertEqual((r[4]['at'], r[4]['round'], r[4]['pr']), ('reviewer', 1, 10))   # fix pushed, back under review
        self.assertEqual((r[5]['at'], r[5]['phase'], r[5]['autopilot']), ('gate2', 'waiting', True))
        self.assertEqual((r[6]['at'], r[6]['phase'], r[6]['lane']), ('done', 'done', 'fast'))
        self.assertEqual(r[2]['since'], fx.T0 + 400)
        self.assertEqual(doc['merged'], 1)
        self.assertEqual(doc['lead'], 3800)

    def test_the_journey_of_a_request(self):
        r = line(None)
        self.assertEqual(journey(r[4]), [('intake', 0), ('analyst', 0), ('gate1', 0), ('architect', 0), ('builder', 0), ('reviewer', 0),
                                         ('builder', 1), ('reviewer', 1)])
        notes = {(s['slot'], s['round']): s['note'] for s in r[4]['stops']}
        self.assertEqual(notes[('reviewer', 0)], 'ADLC-ADV: CHANGES')
        self.assertEqual(notes[('builder', 1)], 'Pushed fix round 1 to PR #10')
        self.assertIsNone(r[4]['stops'][-1]['t1'])
        auto = [s for s in r[5]['stops'] if s['slot'] == 'gate1'][0]
        self.assertEqual((auto['auto'], auto['note']), (True, 'Autopilot approved the plan'))
        self.assertEqual([s for s in r[5]['stops'] if s['slot'] == 'reviewer'][0]['note'], 'ADLC-ADV: PASS and ADLC-ARCH: PASS')

    def test_a_pull_request_is_tied_to_its_issue_as_the_diff_scope_lane_does_it(self):
        store, data = seeded(), fx.repo_data()
        pr = data['openPrs']['nodes'][0]
        tied = lambda: [p for p in store.prs(REPO) if p['number'] == 10][0]['issue']
        elsewhere = {'number': 99, 'repository': {'nameWithOwner': 'other/repo'}}
        pr['closingIssuesReferences'] = {'nodes': [elsewhere, {'number': 3, 'repository': {'nameWithOwner': REPO}}]}
        github.apply(store, REPO, data)
        self.assertEqual(tied(), 3)                      # the first closing reference in this repo, ahead of the branch
        pr['closingIssuesReferences'] = {'nodes': [elsewhere]}
        github.apply(store, REPO, data)
        self.assertEqual(tied(), 4)                      # only another repo's: the branch feat/4-... names it
        pr['headRefName'], pr['title'] = 'chore/deps', 'Bump deps (unlike #3)'
        github.apply(store, REPO, data)
        self.assertIsNone(tied())                        # a number mentioned in passing ties it to nothing

    def test_a_changes_label_sends_it_back_to_the_builder(self):
        data = fx.repo_data()
        data['openPrs']['nodes'][0]['labels'] = {'nodes': [{'name': 'adlc:changes-requested'}]}
        self.assertEqual(line(data)[4]['at'], 'builder')

    def test_either_verdict_can_start_a_fix_round(self):
        data = fx.repo_data()
        pr = data['openPrs']['nodes'][0]
        # the adversarial review passes, the Architect asks for changes: adlc-review.yml flags the pull request all the same
        pr['comments'] = {'nodes': [fx.comment('a', 2300, 'ADLC-ADV: PASS'), fx.comment('b', 2400, 'Off the ADR.\nADLC-ARCH: CHANGES')]}
        pr['commits'] = {'nodes': [{'commit': {'messageHeadline': 'Add guest checkout', 'committedDate': fx.iso(1990)}}]}
        r = line(data)[4]
        self.assertEqual((r['at'], r['round']), ('builder', 1))
        self.assertEqual(journey(r)[-2:], [('reviewer', 0), ('builder', 1)])
        self.assertEqual(r['stops'][-1]['t0'], fx.T0 + 2400)       # the round starts when the last verdict of the review is in

    def test_rounds_are_counted_as_the_fix_cap_counts_them(self):
        data = fx.repo_data()
        pr = data['openPrs']['nodes'][0]
        fix = lambda t: {'commit': {'messageHeadline': 'adlc-fix: again', 'committedDate': fx.iso(t)}}
        # two comments asking for changes, then one fix commit: one round, not two
        pr['comments'] = {'nodes': [fx.comment('a', 2300, 'ADLC-ADV: CHANGES'), fx.comment('b', 2400, 'ADLC-ARCH: CHANGES')]}
        pr['commits'] = {'nodes': [fix(2600)]}
        r = line(data)[4]
        self.assertEqual((r['at'], r['round']), ('reviewer', 1))
        self.assertEqual(journey(r)[-3:], [('reviewer', 0), ('builder', 1), ('reviewer', 1)])
        # three fix commits and still not clean: the loop stops and tags needs:human. No fourth round.
        pr['commits'] = {'nodes': [fix(2600), fix(2800), fix(3000)]}
        pr['comments'] = {'nodes': [fx.comment(str(t), t, 'ADLC-ADV: CHANGES') for t in (2300, 2700, 2900, 3100)]}
        pr['labels'] = {'nodes': [{'name': 'needs:human'}]}
        r = line(data)[4]
        self.assertEqual((r['at'], r['round'], r['alert']), ('reviewer', 3, 'Needs a human'))

    def test_stories_returned_at_gate_1_go_back_to_the_analyst(self):
        data = fx.repo_data()
        gate = data['open']['nodes'][1]
        gate['labels'] = {'nodes': [{'name': 'gate:stories'}, {'name': 'stage:intake'}]}          # the old gate label was left on
        gate['timelineItems']['nodes'].append(fx.labeled(900, 'stage:intake'))
        r = line(data)[2]
        self.assertEqual((r['at'], r['fastRec']), ('analyst', False))
        self.assertEqual(r['stops'][-2]['note'], 'Sent back to the Analyst by juanjtov')        # not "Plan approved"

    def test_a_fast_request_bounced_to_the_full_pipeline_is_a_full_one(self):
        data = fx.repo_data()
        bounced = fx.issue(8, 'Rename Basket to Cart', ['stage:design'],
                           [fx.labeled(100, 'stage:intake'), fx.labeled(400, 'gate:stories', 'adlc-bot'), fx.labeled(500, 'stage:fast'), fx.labeled(800, 'stage:design', 'adlc-bot')])
        data['open']['nodes'].append(bounced)
        r = line(data)[8]
        self.assertEqual((r['at'], r['lane']), ('architect', 'full'))

    def test_a_request_that_left_the_line_leaves_the_page(self):
        store = seeded()
        self.assertIn(1, by_n(state.build(store, REPO, now=NOW)))
        data = fx.repo_data()
        del data['open']['nodes'][0]                     # closed, or its label removed: GitHub no longer returns it
        del data['openPrs']['nodes'][1]
        github.apply(store, REPO, data)
        doc = by_n(state.build(store, REPO, now=NOW))
        self.assertNotIn(1, doc)
        self.assertIsNone(doc[5]['pr'])

    def test_merged_means_done_even_when_the_issue_stays_open(self):
        data = fx.repo_data()
        pr = data['openPrs']['nodes'].pop(1)             # PR 11 for issue 5, merged without a closing keyword
        pr.update({'state': 'MERGED', 'mergedAt': fx.iso(3950)})
        data['closedPrs']['nodes'].append(pr)
        r = line(data)[5]
        self.assertEqual((r['at'], r['phase'], r['doneAt']), ('done', 'done', fx.T0 + 3950))
        self.assertEqual(r['stops'][-2]['note'], 'Merged PR #11')

    def test_a_live_run_makes_the_station_work(self):
        store = seeded()
        ing = ingest.Ingest(store, repos=FakeRepos())
        t = fx.T0 + 3990
        ing.hook(fx.hook('SessionStart'), now=t)
        ing.hook(fx.hook('UserPromptSubmit', prompt='You are the ADLC Builder. Implement issue #3.'), now=t)
        ing.hook(fx.hook('PreToolUse', tool_name='Skill', tool_input={'skill': 'adlc:charter'}, tool_use_id='t0'), now=t + 1)
        ing.hook(fx.hook('PostToolUse', tool_name='Skill', tool_input={'skill': 'adlc:charter'}, tool_use_id='t0', tool_response='ok'), now=t + 1)
        ing.hook(fx.hook('PreToolUse', tool_name='Edit', tool_input={'file_path': '/work/shop/src/reset.ts'}, tool_use_id='t1'), now=t + 2)
        ing.hook(fx.hook('PostToolUse', tool_name='Edit', tool_input={'file_path': '/work/shop/src/reset.ts'}, tool_use_id='t1'), now=t + 3)
        ing.otlp_logs(fx.otlp('s-build', None), now=NOW)
        agents = {st: pipeline.read_agent(PLUGIN, st) for st in pipeline.STATIONS}
        doc = state.build(store, REPO, now=NOW, agents=agents, plugin_root=PLUGIN)
        skills = [c for c in doc['stations']['builder']['run']['ctx'] if c['id'] == 'skills'][0]
        self.assertEqual([s['name'] for s in skills['items']], ['adlc:charter'])   # only what the run loaded, not what it was told to load
        self.assertGreater(skills['tok'], 500)
        self.assertEqual((by_n(doc)[3]['phase'], by_n(doc)[3]['since']), ('working', t))
        run = doc['stations']['builder']['run']
        self.assertEqual((run['n'], run['live'], run['steps'][-1]['label']), (3, True, 'Editing src/reset.ts'))
        self.assertEqual(run['acc']['cacheRead'], 20000)
        self.assertEqual(run['ctx'][0]['id'], 'agent')
        self.assertTrue(run['ctx'][0]['text'].startswith('You are the **Builder**'))
        self.assertEqual(run['ctx'][-1]['id'], 'new')
        self.assertEqual(run['ctxTotal'], 21700)
        self.assertEqual(sum(c['tok'] for c in run['ctx']), 21700)
        self.assertEqual(run['outputs'][0]['title'], '1 file changed')
        self.assertTrue(doc['telemetry'])
        # ten quiet minutes later the run no longer counts as working
        self.assertEqual(by_n(state.build(store, REPO, now=NOW + 700, agents=agents))[3]['phase'], 'queued')
        # ...unless a tool call is still open: a long test run sends nothing until it ends
        ing.hook(fx.hook('PreToolUse', tool_name='Bash', tool_input={'command': 'npm test'}, tool_use_id='t2'), now=NOW)
        self.assertEqual(by_n(state.build(store, REPO, now=NOW + 700, agents=agents))[3]['phase'], 'working')
        self.assertEqual(by_n(state.build(store, REPO, now=NOW + state.LONG_GAP + 1, agents=agents))[3]['phase'], 'queued')

    def test_the_architects_review_counts_as_review_work(self):
        store = seeded()
        ing = ingest.Ingest(store, repos=FakeRepos())
        ing.hook(fx.hook('SessionStart', session='s-arch', agent='adlc:architect'), now=NOW - 20)
        ing.hook(fx.hook('UserPromptSubmit', session='s-arch', agent='adlc:architect', prompt='You are the ADLC Architect (review duty). Review PR #10.'), now=NOW - 20)
        ing.otlp_logs(fx.otlp('s-arch', None), now=NOW)
        doc = state.build(store, REPO, now=NOW)
        r = by_n(doc)[4]
        self.assertEqual((r['at'], r['phase']), ('reviewer', 'working'))           # under review, by the Architect
        self.assertEqual(r['stops'][-1]['tok'], 22000)                              # and the tokens belong to that review
        self.assertEqual([s['tok'] for s in r['stops'] if s['slot'] == 'architect'], [0])
        self.assertEqual(doc['stations']['architect']['run']['n'], 4)               # the Architect's machine shows its own run

    def test_a_run_shows_the_round_it_ran_in(self):
        store = seeded()
        ing = ingest.Ingest(store, repos=FakeRepos())
        for session, agent, prompt, t in (('s-an', 'adlc:product-analyst', 'Triage issue #4.', 150), ('s-b0', 'adlc:builder', 'Implement issue #4.', 1600),
                                          ('s-b1', 'adlc:builder', 'PR #10 was labelled adlc:changes-requested.', 2350)):
            ing.hook(fx.hook('UserPromptSubmit', session=session, agent=agent, prompt=prompt), now=fx.T0 + t)
            ing.hook(fx.hook('Stop', session=session, agent=agent), now=fx.T0 + t + 60)
        doc = state.build(store, REPO, now=NOW)
        self.assertEqual(by_n(doc)[4]['round'], 1)
        self.assertEqual(doc['stations']['analyst']['run']['round'], 0)             # the Analyst ran long before any review
        self.assertEqual(doc['stations']['builder']['run']['round'], 1)             # the latest Builder run is the fix
        store.x('DELETE FROM runs WHERE id = ?', ('s-b1',))
        self.assertEqual(state.build(store, REPO, now=NOW)['stations']['builder']['run']['round'], 0)

    def test_what_a_run_left_behind(self):
        store = seeded()
        ing = ingest.Ingest(store, repos=FakeRepos())
        t = fx.T0 + 1600
        ing.hook(fx.hook('UserPromptSubmit', prompt='Implement issue #4.'), now=t)
        for i in range(20):
            ing.hook(fx.hook('PreToolUse', tool_name='Edit', tool_input={'file_path': '/work/shop/src/f%d.ts' % (i % 12)}, tool_use_id='e%d' % i), now=t + i)
            ing.hook(fx.hook('PostToolUse', tool_name='Edit', tool_input={}, tool_use_id='e%d' % i), now=t + i)
        for i in range(90):                                                         # more reads afterwards than the page lists steps
            ing.hook(fx.hook('PreToolUse', tool_name='Read', tool_input={'file_path': '/work/shop/a.ts'}, tool_use_id='r%d' % i), now=t + 30 + i)
            ing.hook(fx.hook('PostToolUse', tool_name='Read', tool_input={}, tool_use_id='r%d' % i), now=t + 30 + i)
        run = state.build(store, REPO, now=NOW)['stations']['builder']['run']
        self.assertEqual(run['outputs'][0]['title'], '12 files changed')
        self.assertTrue(run['outputs'][0]['code'].startswith('src/f0.ts\nsrc/f1.ts'))
        # the run never said it stopped: it is credited with what happened while it was seen, not with everything since
        titles = [o['title'] for o in run['outputs']]
        self.assertNotIn('Pull request #10', titles)                                # opened at +2000, long after its last event
        self.assertFalse(run['live'])

    def test_the_activity_list_is_todays(self):
        today = state.build(seeded(), REPO, now=NOW)['feed']
        self.assertGreater(len(today), 10)
        self.assertEqual(state.build(seeded(), REPO, now=NOW + 3 * 86400)['feed'], [])

    def test_sizes_add_up_on_a_cold_cache(self):
        store = seeded()
        ing = ingest.Ingest(store, repos=FakeRepos())
        ing.hook(fx.hook('UserPromptSubmit', prompt='Implement issue #3.'), now=NOW - 5)
        ing.otlp_logs(fx.otlp('s-build', None, input_tokens=30000, cache_read_tokens=0, cache_creation_tokens=0), now=NOW)
        agents = {st: pipeline.read_agent(PLUGIN, st) for st in pipeline.STATIONS}
        run = state.build(store, REPO, now=NOW, agents=agents)['stations']['builder']['run']
        self.assertEqual(sum(c['tok'] for c in run['ctx']), run['ctxTotal'])        # the estimates sit inside the total, not on top
        self.assertFalse(any(c['cached'] for c in run['ctx']))

    def test_telemetry_is_on_when_any_export_arrives(self):
        store = seeded()
        ing = ingest.Ingest(store, repos=FakeRepos())
        self.assertFalse(state.build(store, REPO, now=NOW)['telemetry'])
        ing.otlp_logs(fx.otlp('s-someone-else', None), now=NOW)                     # an ordinary session: stored nowhere, but telemetry works
        doc = state.build(store, REPO, now=NOW)
        self.assertEqual((doc['telemetry'], doc['telemetryNote']), (True, ''))
        ing.otlp_logs(fx.otlp('s-main', 'custom'), now=NOW)                         # a plugin agent without OTEL_LOG_TOOL_DETAILS
        self.assertIn('OTEL_LOG_TOOL_DETAILS=1', state.build(store, REPO, now=NOW)['telemetryNote'])


class GitHubReader(unittest.TestCase):
    def test_trouble_with_gh_is_reported_in_plain_words(self):
        def missing(cmd, **kw):
            raise FileNotFoundError()
        with self.assertRaises(github.GhError) as ctx:
            github.fetch(REPO, run=missing)
        self.assertIn('not installed', str(ctx.exception))
        failed = lambda text: (lambda cmd, **kw: subprocess.CompletedProcess(cmd, 1, '', text))
        with self.assertRaises(github.GhError) as ctx:
            github.fetch(REPO, run=failed('To get started with GitHub CLI, please run:  gh auth login\n'))
        self.assertIn('not signed in', str(ctx.exception))
        with self.assertRaises(github.GhError) as ctx:
            github.fetch('acme/auth-service', run=failed("gh: Could not resolve to a Repository with the name 'acme/auth-service'."))
        self.assertNotIn('not signed in', str(ctx.exception))                       # a repo with "auth" in its name is not a login problem

    def test_names_are_sent_as_text(self):
        seen = []
        def ok(cmd, **kw):
            seen.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, json.dumps({'data': {'repository': {'open': {'nodes': []}}}}), '')
        github.fetch('gabrielecirulli/2048', run=ok)
        self.assertNotIn('-F', seen[0])                                             # gh's -F would send the name 2048 as a number
        self.assertIn('name=2048', seen[0])

    def test_the_poller_survives_anything_and_says_so(self):
        store, changes = seeded(), []
        replies = iter([TypeError('odd data'), github.GhError('rate limited'), fx.repo_data()])
        def fetcher(repo):
            reply = next(replies)
            if isinstance(reply, Exception):
                raise reply
            return reply
        poller = github.Poller(store, lambda: [REPO], lambda: changes.append(1), fetcher=fetcher)
        poller.poll(REPO)
        self.assertEqual((poller.status[REPO]['ok'], poller.status[REPO]['msg']), (False, 'Reading GitHub failed (TypeError)'))
        poller.poll(REPO)
        self.assertEqual(poller.status[REPO]['msg'], 'rate limited')
        poller.poll(REPO)
        self.assertTrue(poller.status[REPO]['ok'])
        self.assertEqual(len(changes), 3)
        doc = state.build(store, REPO, now=NOW, github={'ok': False, 'msg': 'rate limited', 'polled': None})
        self.assertEqual(doc['github']['msg'], 'rate limited')

    def test_a_read_that_fails_half_way_changes_nothing(self):
        store, data = seeded(), fx.repo_data()
        data['open']['nodes'] = [{'title': 'no number'}]
        with self.assertRaises(KeyError):
            github.apply(store, REPO, data)
        self.assertEqual(len(store.issues(REPO)), 7)                                # the mirror from before is intact

    def test_github_is_read_only_while_a_page_is_open(self):
        reads = []
        app = server.App(seeded(), REPO, poll=False, interval=0.05)
        app.poller.fetcher = lambda repo: reads.append(repo) or fx.repo_data()
        app.poller.start()
        try:
            time.sleep(0.3)
            self.assertEqual(reads, [])                                             # nobody is looking: nothing is spent
            app.watch(REPO, +1)
            time.sleep(0.3)
            self.assertGreater(len(reads), 1)
            self.assertEqual(set(reads), {REPO})
            app.watch(REPO, -1)
            time.sleep(0.2)
            settled = len(reads)
            time.sleep(0.3)
            self.assertEqual(len(reads), settled)                                   # the page closed: reading stops
        finally:
            app.poller.stopped = True
            app.poller.wake.set()


class OverHttp(unittest.TestCase):
    """The real server and the real hook script, over a real socket."""

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.app = server.App(seeded(), REPO, poll=False)
        self.app.ingest.repos = FakeRepos()
        self.arrived = []                              # every hook event that reached the server, kept or not
        kept = self.app.ingest.hook
        self.app.ingest.hook = lambda ev, **kw: self.arrived.append(ev) or kept(ev, **kw)
        server.Handler.app = self.app
        self.httpd = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]
        self.url = 'http://127.0.0.1:%d' % self.port
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        with open(os.path.join(self.home, 'server.json'), 'w') as fh:
            json.dump({'port': self.port, 'pid': 1}, fh)

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.home)

    def hook(self, ev, home=None):
        env = dict(os.environ, ADLC_MC_HOME=home or self.home)
        return subprocess.run(['bash', HOOK], input=json.dumps(ev), text=True, capture_output=True, env=env, timeout=10)

    def get(self, path, **headers):
        try:
            with urllib.request.urlopen(urllib.request.Request(self.url + path, headers=headers), timeout=5) as res:
                return res.status, res.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()

    def post(self, path, doc, raw=None, **headers):
        head = {'Content-Type': 'application/json'}
        head.update(headers)
        req = urllib.request.Request(self.url + path, data=raw if raw is not None else json.dumps(doc).encode(), headers=head)
        try:
            with urllib.request.urlopen(req, timeout=5) as res:
                return res.status
        except urllib.error.HTTPError as exc:
            return exc.code

    def raw(self, request):
        """One request exactly as written, no client tidying the path."""
        with socket.create_connection(('127.0.0.1', self.port), timeout=5) as sock:
            sock.sendall(request.encode())
            sock.settimeout(5)
            data = b''
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                data += chunk
        return data

    def builder_run(self):
        return json.loads(self.get('/api/state')[1])['stations']['builder']['run']

    def test_the_hook_script_reports_a_pipeline_run(self):
        out = self.hook(fx.hook('SessionStart'))
        self.assertEqual((out.returncode, out.stdout, out.stderr), (0, '', ''))
        self.hook(fx.hook('PreToolUse', tool_name='Bash', tool_input={'command': 'npm test'}, tool_use_id='t1'))
        run = self.builder_run()
        self.assertEqual((run['live'], run['steps'][0]['label']), (True, 'npm test'))
        # a session handing work to a pipeline agent is ours too: it carries that agent's task prompt
        self.hook(fx.hook('PreToolUse', session='s-main', agent=None, tool_name='Agent', tool_input={'subagent_type': 'adlc:qa-release-ops', 'prompt': 'Gate PR #11.'}))
        self.assertEqual(len(self.arrived), 3)

    def test_events_that_name_no_pipeline_agent_never_leave_the_hook(self):
        plain = {'hook_event_name': 'PreToolUse', 'session_id': 's-other', 'cwd': '/work/shop', 'tool_name': 'Bash', 'tool_input': {'command': 'cat notes.txt'}}
        others = [
            plain,
            dict(plain, agent_type='Explore', agent_id='x1'),                                     # another subagent
            dict(plain, agent_type='other-plugin:builder'),                                       # another plugin's agent of the same name
            dict(plain, agent_type='builder'),                                                    # a project's own agent of the same name
            dict(plain, tool_name='Agent', tool_input={'subagent_type': 'Explore', 'prompt': 'Find the adlc:builder agent file'}),
            {'hook_event_name': 'SessionEnd', 'session_id': 's-other', 'cwd': '/work/shop', 'reason': 'exit'},
            dict(plain, tool_input={'command': 'echo "agent_type" adlc:builder'}),                # the words alone are not the field
        ]
        for ev in others:
            self.assertEqual(self.hook(ev).returncode, 0)
        self.assertEqual(self.arrived, [])
        self.assertEqual(self.app.store.q('SELECT * FROM runs'), [])

    def test_the_hook_is_silent_when_mission_control_is_not_running(self):
        empty = tempfile.mkdtemp()
        try:
            out = self.hook(fx.hook('SessionStart'), home=empty)
            self.assertEqual((out.returncode, out.stdout, out.stderr), (0, '', ''))
            with open(os.path.join(empty, 'server.json'), 'w') as fh:
                json.dump({'port': 9, 'pid': 1}, fh)             # a stale marker: nothing listens there
            out = self.hook(fx.hook('SessionStart'), home=empty)
            self.assertEqual((out.returncode, out.stdout, out.stderr), (0, '', ''))
        finally:
            shutil.rmtree(empty)

    def test_telemetry_over_http(self):
        self.post('/hooks', fx.hook('SessionStart'))
        self.assertEqual(self.post('/v1/logs', fx.otlp('s-build', None)), 200)
        self.assertEqual(self.builder_run()['acc']['cacheRead'], 20000)
        packed = gzip.compress(json.dumps(fx.otlp('s-build', None)).encode())
        self.assertEqual(self.post('/v1/logs', None, raw=packed, **{'Content-Encoding': 'gzip'}), 200)
        self.assertEqual(self.builder_run()['acc']['cacheRead'], 40000)
        self.assertEqual(self.post('/v1/metrics', {'resourceMetrics': []}), 200)   # accepted and ignored

    def test_only_this_machine_and_this_page_are_answered(self):
        self.assertEqual(self.post('/hooks', fx.hook('SessionStart'), Origin='https://elsewhere.example'), 403)
        self.assertEqual(self.post('/hooks', fx.hook('SessionStart'), Host='elsewhere.example'), 403)
        self.assertEqual(self.post('/hooks', fx.hook('SessionStart'), Origin='null'), 403)
        self.assertEqual(self.post('/v1/logs', None, raw=b'\x0a\x02hi', **{'Content-Type': 'application/x-protobuf'}), 415)
        self.assertEqual(self.arrived, [])
        # reading is guarded the same way: another site's page gets neither the state nor the stream
        self.assertEqual(self.get('/api/state', Origin='https://elsewhere.example')[0], 403)
        self.assertEqual(self.get('/api/events', Origin='https://elsewhere.example')[0], 403)
        self.assertEqual(self.get('/api/state', **{'Sec-Fetch-Site': 'cross-site'})[0], 403)
        self.assertEqual(self.get('/api/state', Host='localhost.elsewhere.example')[0], 403)
        self.assertEqual(self.get('/api/state', **{'Sec-Fetch-Site': 'same-origin'})[0], 200)
        self.assertEqual(self.get('/', **{'Sec-Fetch-Site': 'cross-site'})[0], 200)   # a link to the page from elsewhere still opens it

    def test_pages_are_served_and_nothing_outside_web(self):
        status, body = self.get('/')
        self.assertEqual(status, 200)
        self.assertIn(b'<div id="app">', body)
        self.assertEqual(self.get('/app.js')[0], 200)
        meta = json.loads(self.get('/api/meta')[1])
        self.assertEqual([a['station'] for a in meta['stations']], pipeline.STATIONS)
        # asked for raw: urllib would tidy these paths before sending them
        for path in ('/../server.py', '/../mc/store.py', '/..%2fserver.py', '//etc/passwd', '/./../server.py'):
            reply = self.raw('GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' % path)
            self.assertTrue(reply.startswith(b'HTTP/1.1 404'), path)
            self.assertNotIn(b'import', reply)

    def test_a_body_that_cannot_be_read_is_refused_not_dropped(self):
        ok = fx.hook('SessionStart')
        self.assertEqual(self.post('/hooks', [ok]), 400)                                          # a list, not an object
        self.assertEqual(self.post('/hooks', None, raw=b'{"half":'), 400)
        self.assertEqual(self.post('/hooks', None, raw=b'not gzip', **{'Content-Encoding': 'gzip'}), 400)
        self.assertEqual(self.post('/hooks', dict(ok, session_id=['a list']), ), 200)             # an odd field is ignored, not a crash
        self.assertEqual(self.post('/hooks', dict(ok, tool_input='x', cwd={'a': 1}, agent_id={'b': 2})), 200)
        reply = self.raw('POST /hooks HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: lots\r\n\r\n')
        self.assertTrue(reply.startswith(b'HTTP/1.1 400'))
        self.assertEqual(self.post('/v1/logs', fx.otlp('s-build', None, cost_usd='Infinity', input_tokens='1e999')), 200)
        status, body = self.get('/api/state')
        self.assertEqual(status, 200)
        json.loads(body, parse_constant=lambda name: self.fail('the state holds %s, which no browser can parse' % name))

    def test_the_stream_sends_the_state_and_marks_the_repo_as_watched(self):
        self.assertEqual(self.app.watched(), [])
        res = urllib.request.urlopen(self.url + '/api/events', timeout=5)
        try:
            self.assertEqual(res.readline(), b'event: state\n')
            doc = json.loads(res.readline()[len(b'data: '):])
            self.assertEqual((doc['repo'], len(doc['requests'])), (REPO, 5))    # by the real clock, the merged one was not merged today
            self.assertEqual(self.app.watched(), [REPO])
            self.app.ingest.hook(fx.hook('SessionStart'))
            self.app.bump()
            res.readline()                                           # the blank line that ends the first event
            self.assertEqual(res.readline(), b'event: state\n')
            self.assertTrue(json.loads(res.readline()[len(b'data: '):])['stations']['builder']['run']['live'])
        finally:
            res.close()
        for _ in range(40):                                          # the server notices the closed page at its next write
            self.app.bump()
            time.sleep(0.1)
            if not self.app.watched():
                break
        self.assertEqual(self.app.watched(), [])

    def test_a_row_the_view_cannot_digest_does_not_end_the_stream(self):
        build, state.build = state.build, lambda *a, **kw: 1 / 0
        stderr, sys.stderr = sys.stderr, io.StringIO()               # the server prints the traceback; keep it out of the test output
        try:
            self.assertEqual(self.get('/api/state')[0], 500)
            res = urllib.request.urlopen(self.url + '/api/events', timeout=5)
            self.assertEqual(res.readline(), b'event: trouble\n')
            self.assertIn('ZeroDivisionError', json.loads(res.readline()[len(b'data: '):])['error'])
            state.build = build
            self.app.bump()
            res.readline()
            self.assertEqual(res.readline(), b'event: state\n')      # the same stream recovers
            res.close()
            self.assertIn('ZeroDivisionError', sys.stderr.getvalue())
        finally:
            state.build, sys.stderr = build, stderr


class Launcher(unittest.TestCase):
    """server.py as the user starts it: the marker file is what tells the hook where to send."""

    def start(self, home, port, *args):
        env = dict(os.environ, ADLC_MC_HOME=home, PYTHONUNBUFFERED='1')
        return subprocess.Popen([sys.executable, SERVER, '--port', str(port), '--repo', 'Acme/Shop'] + list(args), env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def wait_for(self, check, what):
        for _ in range(100):
            if check():
                return
            time.sleep(0.05)
        self.fail('timed out waiting for ' + what)

    def free_port(self):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            return sock.getsockname()[1]

    def test_one_copy_per_data_folder_and_the_marker_goes_when_it_stops(self):
        home = tempfile.mkdtemp()
        marker = os.path.join(home, 'server.json')
        port = self.free_port()
        first = self.start(home, port)
        try:
            self.wait_for(lambda: server.running_at(port), 'the server')
            with open(marker) as fh:
                mark = json.load(fh)
            self.assertEqual((mark['port'], mark['pid']), (port, first.pid))
            with urllib.request.urlopen('http://127.0.0.1:%d/api/state?repo=ACME/shop' % port, timeout=5) as res:
                self.assertEqual(json.loads(res.read())['repo'], REPO)               # one repo, however its name is cased
            # a second copy on the same data would take the marker, and agents would stop reporting to the first
            second = self.start(home, self.free_port())
            out, _ = second.communicate(timeout=10)
            self.assertEqual(second.returncode, 0)
            self.assertIn('already running at http://localhost:%d' % port, out)
            with open(marker) as fh:
                self.assertEqual(json.load(fh)['pid'], first.pid)
            # the demo keeps to itself: no marker of its own, so agents never report to made-up data
            demo_port = self.free_port()
            demo = self.start(tempfile.mkdtemp(), demo_port, '--demo')
            try:
                self.wait_for(lambda: server.running_at(demo_port), 'the demo')
            finally:
                demo.terminate()
                demo.communicate(timeout=10)
            first.send_signal(signal.SIGHUP)                                          # the terminal was closed
            first.communicate(timeout=10)
            self.assertFalse(os.path.exists(marker))
        finally:
            if first.poll() is None:
                first.kill()
                first.communicate()
            shutil.rmtree(home)


if __name__ == '__main__':
    unittest.main()
