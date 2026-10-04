"""Tests for the Mission Control server: pipeline rules, data intake, and the state the screen renders.

Run: python3 -m unittest discover -s mission-control/tests
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..'))

import fixtures as fx  # noqa: E402
from mc import github, ingest, pipeline, state  # noqa: E402
from mc.store import Store  # noqa: E402

REPO = 'acme/shop'
PLUGIN = os.path.join(HERE, '..', '..')


class FakeRepos:
    def lookup(self, cwd):
        return REPO, 'feat/3-password-reset'


def seeded():
    store = Store()
    store.add_repo(REPO)
    github.apply(store, REPO, fx.repo_data())
    return store


def by_n(doc):
    return {r['n']: r for r in doc['requests']}


class PipelineRules(unittest.TestCase):
    def test_agent_names_map_to_stations(self):
        self.assertEqual(pipeline.station_for('adlc:builder'), 'builder')
        self.assertEqual(pipeline.station_for('adversarial-reviewer'), 'reviewer')
        self.assertIsNone(pipeline.station_for('Explore'))
        self.assertIsNone(pipeline.station_for(None))

    def test_prompt_refs(self):
        self.assertEqual(pipeline.refs_in('You are the ADLC Builder. Implement issue #142 following its ADR.'), (142, None))
        self.assertEqual(pipeline.refs_in('Review PR #156 in fresh context'), (None, 156))
        self.assertEqual(pipeline.refs_in('Gate the PR linked to issue #9.'), (9, None))
        self.assertEqual(pipeline.refs_in('no numbers here'), (None, None))
        self.assertEqual(pipeline.issue_in_branch('feat/142-password-reset'), 142)
        self.assertIsNone(pipeline.issue_in_branch('main'))

    def test_later_stage_label_wins(self):
        self.assertEqual(pipeline.slot_for_labels(['stage:intake', 'gate:stories'])[0], 'gate1')
        self.assertEqual(pipeline.slot_for_labels(['bug', 'question']), (None, None))

    def test_step_labels_are_plain(self):
        self.assertEqual(pipeline.step_label('Read', {'file_path': '/work/shop/src/a.ts'}, '/work/shop'), ('read', 'Reading src/a.ts'))
        self.assertEqual(pipeline.step_label('Bash', {'command': 'gh pr create --fill'})[0], 'gh')
        self.assertEqual(pipeline.step_label('Bash', {'command': 'npm test', 'description': 'Run the tests'}), ('bash', 'Run the tests'))

    def test_agent_file_is_read(self):
        info = pipeline.read_agent(PLUGIN, 'builder')
        self.assertTrue(info['prompt'].startswith('You are the **Builder**'))
        self.assertIn('Bash', info['tools'])
        self.assertTrue(any(s['name'] == 'adlc:charter' for s in info['skills']))
        self.assertIn('gh pr diff', pipeline.read_agent(PLUGIN, 'reviewer')['tools'])


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

    def test_sessions_outside_the_pipeline_are_dropped(self):
        self.assertFalse(self.ing.hook(fx.hook('PreToolUse', agent=None, tool_name='Bash', tool_input={'command': 'ls'})))
        self.assertFalse(self.ing.hook(fx.hook('PreToolUse', agent='Explore', tool_name='Bash', tool_input={'command': 'ls'})))
        self.assertEqual(self.store.q('SELECT * FROM runs'), [])

    def test_a_subagent_gets_the_prompt_its_parent_gave_it(self):
        self.ing.hook(fx.hook('PreToolUse', session='s-main', agent=None, tool_name='Agent',
                              tool_input={'subagent_type': 'adlc:adversarial-reviewer', 'prompt': 'Review PR #10 in fresh context.'}), now=fx.T0)
        self.ing.hook(fx.hook('SubagentStart', session='s-main', agent='adlc:adversarial-reviewer', agent_id='a1'), now=fx.T0 + 1)
        run = self.store.run('s-main:a1')
        self.assertEqual((run['station'], run['pr'], run['prompt']), ('reviewer', 10, 'Review PR #10 in fresh context.'))

    def test_telemetry_lands_on_the_right_run(self):
        self.ing.hook(fx.hook('SessionStart'), now=fx.T0 + 1510)
        self.assertEqual(self.ing.otlp_logs(fx.otlp('s-build', 'builder', n=2)), 2)
        total = self.store.api_sum(['s-build'])
        self.assertEqual((total['input'], total['cacheRead'], total['output'], total['replies']), (2400, 40000, 600, 2))
        self.assertAlmostEqual(total['usd'], 0.04)
        self.assertEqual(self.store.run('s-build')['model'], 'fable')
        # a reply from an agent that is not part of the pipeline is not kept
        self.assertEqual(self.ing.otlp_logs(fx.otlp('s-build', 'Explore')), 0)
        # a reply that arrives before any hook still opens the run
        self.assertEqual(self.ing.otlp_logs(fx.otlp('s-new', 'qa-release-ops')), 1)
        self.assertEqual(self.store.run('s-new')['station'], 'qa')


class Line(unittest.TestCase):
    def test_where_each_request_stands(self):
        doc = state.build(seeded(), REPO, now=fx.T0 + 4000)
        r = by_n(doc)
        self.assertEqual(sorted(r), [1, 2, 3, 4, 5, 6])              # issue 7 is not on the line
        self.assertEqual((r[1]['at'], r[1]['phase']), ('analyst', 'queued'))
        self.assertEqual((r[2]['at'], r[2]['phase'], r[2]['fastRec']), ('gate1', 'waiting', True))
        self.assertEqual((r[3]['at'], r[3]['adr'], r[3]['epic']), ('builder', 7, 'Account security'))
        self.assertEqual((r[4]['at'], r[4]['round'], r[4]['pr']), ('reviewer', 1, 10))   # fix pushed, back under review
        self.assertEqual((r[5]['at'], r[5]['phase'], r[5]['autopilot']), ('gate2', 'waiting', True))
        self.assertEqual((r[6]['at'], r[6]['phase'], r[6]['lane']), ('done', 'done', 'fast'))
        self.assertEqual(r[2]['since'], fx.T0 + 400)
        self.assertEqual(doc['merged'], 1)
        self.assertEqual(doc['lead'], 3800)

    def test_the_journey_of_a_request(self):
        r = by_n(state.build(seeded(), REPO, now=fx.T0 + 4000))
        slots = [(s['slot'], s['round']) for s in r[4]['stops']]
        self.assertEqual(slots, [('intake', 0), ('analyst', 0), ('gate1', 0), ('architect', 0), ('builder', 0), ('reviewer', 0),
                                 ('builder', 1), ('reviewer', 1)])
        notes = {(s['slot'], s['round']): s['note'] for s in r[4]['stops']}
        self.assertEqual(notes[('reviewer', 0)], 'ADLC-ADV: CHANGES')
        self.assertEqual(notes[('builder', 1)], 'Pushed fix round 1 to PR #10')
        self.assertIsNone(r[4]['stops'][-1]['t1'])
        auto = [s for s in r[5]['stops'] if s['slot'] == 'gate1'][0]
        self.assertEqual((auto['auto'], auto['note']), (True, 'Autopilot approved the plan'))
        self.assertEqual([s for s in r[5]['stops'] if s['slot'] == 'reviewer'][0]['note'], 'ADLC-ADV: PASS and ADLC-ARCH: PASS')

    def test_a_changes_label_sends_it_back_to_the_builder(self):
        store = seeded()
        data = fx.repo_data()
        data['pullRequests']['nodes'][0]['labels'] = {'nodes': [{'name': 'adlc:changes-requested'}]}
        github.apply(store, REPO, data)
        self.assertEqual(by_n(state.build(store, REPO, now=fx.T0 + 4000))[4]['at'], 'builder')

    def test_a_live_run_makes_the_station_work(self):
        store = seeded()
        ing = ingest.Ingest(store, repos=FakeRepos())
        t = fx.T0 + 3990
        ing.hook(fx.hook('SessionStart'), now=t)
        ing.hook(fx.hook('UserPromptSubmit', prompt='You are the ADLC Builder. Implement issue #3.'), now=t)
        ing.hook(fx.hook('PreToolUse', tool_name='Edit', tool_input={'file_path': '/work/shop/src/reset.ts'}, tool_use_id='t1'), now=t + 2)
        ing.otlp_logs(fx.otlp('s-build', 'builder'))
        agents = {st: pipeline.read_agent(PLUGIN, st) for st in pipeline.STATIONS}
        doc = state.build(store, REPO, now=fx.T0 + 4000, agents=agents)
        self.assertEqual((by_n(doc)[3]['phase'], by_n(doc)[3]['since']), ('working', t))
        run = doc['stations']['builder']['run']
        self.assertEqual((run['n'], run['live'], run['steps'][0]['label']), (3, True, 'Editing src/reset.ts'))
        self.assertEqual(run['acc']['cacheRead'], 20000)
        self.assertEqual(run['ctx'][0]['id'], 'agent')
        self.assertTrue(run['ctx'][0]['text'].startswith('You are the **Builder**'))
        self.assertEqual(run['ctx'][-1]['id'], 'new')
        self.assertEqual(run['ctxTotal'], 21700)
        self.assertEqual(run['outputs'][0]['title'], '1 file changed')
        self.assertTrue(doc['telemetry'])
        # ten quiet minutes later the run no longer counts as working
        later = state.build(store, REPO, now=fx.T0 + 4000 + 700, agents=agents)
        self.assertEqual(by_n(later)[3]['phase'], 'queued')

    def test_github_trouble_is_reported_not_hidden(self):
        def broken(cmd, **kw):
            raise FileNotFoundError()
        with self.assertRaises(github.GhError) as ctx:
            github.fetch(REPO, run=broken)
        self.assertIn('not installed', str(ctx.exception))
        self.assertEqual(ingest.parse_remote('git@github.com:acme/shop.git'), REPO)
        self.assertEqual(ingest.parse_remote('https://github.com/acme/shop'), REPO)


if __name__ == '__main__':
    unittest.main()
