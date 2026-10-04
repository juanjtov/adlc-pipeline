"""A small made-up repo, shaped like what `gh api graphql` returns, used by the tests."""
import time

T0 = 1790000000.0   # an arbitrary fixed moment; tests pass their own `now`


def iso(offset):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(T0 + offset))


def labeled(offset, name, actor='juanjtov', added=True):
    return {'__typename': 'LabeledEvent' if added else 'UnlabeledEvent', 'createdAt': iso(offset), 'label': {'name': name}, 'actor': {'login': actor}}


def comment(cid, offset, body, author='adlc-bot'):
    return {'id': cid, 'body': body, 'createdAt': iso(offset), 'author': {'login': author}}


def issue(number, title, labels, timeline, comments=(), state='OPEN', milestone=None, closed=None):
    return {'number': number, 'title': title, 'url': 'https://github.com/acme/shop/issues/%d' % number, 'state': state,
            'createdAt': iso(-10), 'closedAt': iso(closed) if closed is not None else None, 'updatedAt': iso(0),
            'author': {'login': 'juanjtov'}, 'milestone': {'title': milestone} if milestone else None,
            'labels': {'nodes': [{'name': n} for n in labels]}, 'timelineItems': {'nodes': list(timeline)}, 'comments': {'nodes': list(comments)}}


def pull(number, title, head, closes, created, labels=(), comments=(), commits=(), state='OPEN', merged=None):
    return {'number': number, 'title': title, 'url': 'https://github.com/acme/shop/pull/%d' % number, 'state': state,
            'createdAt': iso(created), 'mergedAt': iso(merged) if merged is not None else None, 'updatedAt': iso(created), 'headRefName': head,
            'body': 'Closes #%d' % closes, 'author': {'login': 'adlc-bot'}, 'labels': {'nodes': [{'name': n} for n in labels]},
            'closingIssuesReferences': {'nodes': [{'number': closes}]},
            'commits': {'nodes': [{'commit': {'messageHeadline': m, 'committedDate': iso(t)}} for m, t in commits]},
            'comments': {'nodes': list(comments)}}


def repo_data():
    """Six requests, one at each interesting place on the line, plus one issue that is not on it."""
    return {
        'open': {'nodes': [
            # 1: the Analyst has it
            issue(1, 'Export orders as CSV', ['stage:intake'], [labeled(100, 'stage:intake')]),
            # 2: waiting at Gate 1, fast lane recommended
            issue(2, 'Fix typo on the pricing page', ['gate:stories'], [labeled(100, 'stage:intake'), labeled(400, 'gate:stories', 'adlc-bot')],
                  [comment('c2', 390, 'Change brief...\nADLC-TRIAGE: FAST | one-file copy fix')]),
            # 3: with the Builder, no pull request yet
            issue(3, 'Password reset link', ['stage:build'],
                  [labeled(100, 'stage:intake'), labeled(400, 'gate:stories', 'adlc-bot'), labeled(900, 'stage:design'), labeled(1500, 'stage:build', 'adlc-bot')],
                  [comment('c3a', 390, 'Stories S1..S3\nADLC-TRIAGE: FULL | touches auth'),
                   comment('c3b', 1490, 'Wrote docs/adr/0007-password-reset.md and the task breakdown')],
                  milestone='Account security'),
            # 4: pull request open, review asked for changes once, fix pushed, under review again
            issue(4, 'Guest checkout', ['stage:build'],
                  [labeled(100, 'stage:intake'), labeled(400, 'gate:stories', 'adlc-bot'), labeled(900, 'stage:design'), labeled(1500, 'stage:build', 'adlc-bot')],
                  milestone='Checkout'),
            # 5: at Gate 2 with an action card, on autopilot
            issue(5, 'Order confirmation email', ['gate:deploy', 'adlc:autopilot'],
                  [labeled(100, 'stage:intake'), labeled(400, 'gate:stories', 'adlc-bot'), labeled(430, 'stage:design', 'adlc-bot'),
                   labeled(1500, 'stage:build', 'adlc-bot'), labeled(3000, 'stage:qa', 'adlc-bot'), labeled(3900, 'gate:deploy', 'adlc-bot')],
                  [comment('c5', 3890, '## Proposed Action Card — Gate 2\nAction: merge PR #11 to main\nRisk: low\nRollback: revert the merge commit')],
                  milestone='Checkout'),
            # 7: an ordinary issue that is not on the line
            issue(7, 'Question about pricing', ['question'], []),
        ]},
        'closed': {'nodes': [
            # 6: merged through the fast lane
            issue(6, 'Update the footer year', [],
                  [labeled(100, 'stage:intake'), labeled(400, 'gate:stories', 'adlc-bot'), labeled(500, 'stage:fast'), labeled(1200, 'gate:deploy', 'adlc-bot')],
                  state='CLOSED', closed=1300),
        ]},
        'pullRequests': {'nodes': [
            pull(10, 'Guest checkout', 'feat/4-guest-checkout', 4, 2000,
                 comments=[comment('p10a', 2300, 'Finding...\nADLC-FINDING: High | missing-authz | src/checkout/guest.ts\nADLC-ADV: CHANGES')],
                 commits=[('Add guest checkout', 1990), ('adlc-fix: scope the guest cart query', 2600)]),
            pull(11, 'Order confirmation email', 'feat/5-order-email', 5, 2000,
                 comments=[comment('p11a', 2400, 'ADLC-ADV: PASS'), comment('p11b', 2500, 'ADLC-ARCH: PASS')]),
            pull(12, 'Update the footer year', 'feat/6-footer-year', 6, 700, labels=['lane:fast'], state='MERGED', merged=1300,
                 comments=[comment('p12a', 900, 'ADLC-ADV: PASS')]),
        ]},
    }


def hook(name, session='s-build', agent='adlc:builder', **extra):
    ev = {'hook_event_name': name, 'session_id': session, 'cwd': '/work/shop', 'transcript_path': '/tmp/t.jsonl', 'agent_type': agent}
    ev.update(extra)
    return ev


def otlp(session, agent, n=1, **fields):
    """An OTLP/HTTP JSON logs export with n api_request records."""
    base = {'input_tokens': 1200, 'output_tokens': 300, 'cache_read_tokens': 20000, 'cache_creation_tokens': 500, 'cost_usd': 0.02,
            'duration_ms': 1800, 'model': 'fable'}
    base.update(fields)

    def attr(key, value):
        if isinstance(value, str):
            return {'key': key, 'value': {'stringValue': value}}
        if isinstance(value, float):
            return {'key': key, 'value': {'doubleValue': value}}
        return {'key': key, 'value': {'intValue': str(value)}}   # OTLP JSON carries 64-bit integers as strings

    attrs = [attr('event.name', 'api_request'), attr('session.id', session)]
    if agent:
        attrs.append(attr('agent.name', agent))
    attrs += [attr(k, v) for k, v in base.items()]
    rec = {'timeUnixNano': str(int((T0 + 1600) * 1e9)), 'body': {'stringValue': 'claude_code.api_request'}, 'attributes': attrs}
    return {'resourceLogs': [{'resource': {'attributes': [attr('service.name', 'claude-code')]}, 'scopeLogs': [{'logRecords': [rec] * n}]}]}
