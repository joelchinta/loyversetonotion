"""Exercise the real shell scripts with a stateful, network-free curl fixture."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LABELS = ['Item', 'Variant', 'Qty', 'Price', 'Note', 'Modifiers', 'Category']


def receipt(number, day):
    data = dict(receipt_number=number, created_at=f'2026-10-{day:02}T00:00:00Z',
                receipt_date=f'2026-10-{day:02}T00:00:00Z', updated_at=f'2026-10-{day:02}T01:00:00Z',
                receipt_type='SALE', source='POS', store_id='fixture', employee_id='fixture',
                pos_device_id='fixture', line_items=[], payments=[])
    data.update({key: 0 for key in ['total_money', 'total_tax', 'total_discount', 'tip', 'surcharge',
                                 'points_earned', 'points_deducted', 'points_balance']})
    return data


def curl_fixture():
    args = sys.argv[1:]
    def option(name, default=None):
        return args[args.index(name) + 1] if name in args else default
    url = next(x for x in args if x.startswith('https://'))
    from urllib.parse import urlparse, parse_qs
    parsed = urlparse(url)
    path = parsed.path
    method = option('-X', 'GET')
    payload = json.loads(option('--data', '{}'))
    file = Path(os.environ['SYNC_FIXTURE_STATE'])
    state = json.loads(file.read_text())
    action = 'other'
    if parsed.netloc == 'api.loyverse.com':
        action = 'receipts'
        if path.startswith('/v1.0/receipts/'):
            response = next(r for r in state['receipts'] if r['receipt_number'] == path.split('/')[-1])
        else:
            action = 'receipts-page2' if 'cursor' in parse_qs(parsed.query) else 'receipts'
            response = {'receipts': [state['receipts'][0]], 'cursor': 'page2'} if action == 'receipts' else {'receipts': state['receipts'][1:]}
    elif path.endswith('/query'):
        action = 'query'
        number = payload['filter']['title']['equals']
        response = {'object': 'list', 'results': [p for p in state['pages'] if p['properties']['receipt_number']['title'][0]['text']['content'] == number], 'has_more': False}
    elif path == '/v1/pages':
        action = 'create'
        response = {'object': 'page', 'id': f'page-{len(state["pages"])+1}', 'properties': payload['properties']}
    elif path.startswith('/v1/pages/'):
        action = 'properties'
        page = next(p for p in state['pages'] if p['id'] == path.split('/')[-1])
        response = {**page, 'properties': payload['properties']}
    elif method == 'DELETE':
        action = 'delete'
        response = {'object': 'block', 'id': path.split('/')[-1], 'archived': True}
    elif method == 'PATCH':
        action = 'append'
        block = {**payload['children'][0], 'id': f'table-{state["next_table"]}'}
        response = {'object': 'list', 'results': [block]}
    else:
        block_id = path.split('/')[-2]
        if block_id.startswith('table-'):
            action = 'table-header'
            response = {'results': [{'table_row': {'cells': [[{'text': {'content': text}}] for text in LABELS]}}]}
        else:
            action = 'children'
            response = {'results': state['blocks'], 'has_more': False}
    status = 200
    rule = state.get('failure')
    target = payload.get('properties', {}).get('receipt_number', {}).get('title', [{}])[0].get('text', {}).get('content')
    failed = rule and rule['action'] == action and rule['remaining'] > 0 and ('receipt' not in rule or rule['receipt'] == target)
    if failed:
        rule['remaining'] -= 1
        status = rule.get('status', 400)
        response = {'object': 'error', 'status': status, 'code': 'fixture_rejection'}
    elif action == 'create':
        state['pages'].append(response)
    elif action == 'append':
        state['blocks'].append(response['results'][0]); state['next_table'] += 1
    elif action == 'delete':
        state['blocks'] = [b for b in state['blocks'] if b['id'] != response['id']]
    elif action == 'properties':
        state['pages'] = [response if p['id'] == response['id'] else p for p in state['pages']]
    state['calls'].append([action, status])
    file.write_text(json.dumps(state))
    Path(option('--output')).write_text('<html>fixture</html>' if failed and rule.get('invalid_json') else json.dumps(response))
    Path(option('--dump-header')).write_text(f'HTTP/1.1 {status}\r\nRetry-After: 0\r\n\r\n')
    print(status, end='')


def run_case(failure=None, existing=False, script='sync.sh', recover=False):
    with tempfile.TemporaryDirectory(prefix='loyverse-tests-') as temp:
        work = Path(temp); binary = work / 'bin'; binary.mkdir()
        # Use the running Python path, avoiding whichever python3 is on shell PATH.
        (binary / 'curl').write_text(f'#!{sys.executable}\nimport runpy\nrunpy.run_path({str(__file__)!r}, run_name="curl_fixture")\n')
        (binary / 'curl').chmod(0o755)
        (binary / 'sleep').write_text('#!/bin/sh\nexit 0\n'); (binary / 'sleep').chmod(0o755)
        source = [receipt('fixture-42', 21), receipt('fixture-41', 20)]
        state = {'receipts': source, 'pages': [], 'blocks': [], 'calls': [], 'next_table': 2, 'failure': failure}
        if existing:
            state['pages'] = [{'object': 'page', 'id': 'page-1', 'properties': {'receipt_number': {'title': [{'text': {'content': 'fixture-41'}}]}, 'updated_at': {'date': {'start': '2026-10-19T00:00:00Z'}}}}]
            state['blocks'] = [{'object': 'block', 'type': 'table', 'table': {'table_width': 7}, 'id': 'table-1'}, {'type': 'paragraph', 'id': 'keep-note'}]
        state_file = work / 'state.json'; state_file.write_text(json.dumps(state))
        checkpoint = work / '.last_receipt.txt'; checkpoint.write_text('fixture-40\n')
        env = {**os.environ, 'PATH': str(binary) + ':/usr/bin:/bin', 'SYNC_FIXTURE_STATE': str(state_file),
               'LOYVERSE_API_KEY': 'fixture', 'NOTION_API_KEY': 'fixture', 'NOTION_DB_ID': 'fixture', 'RECEIPT_NUMBER': 'fixture-41'}
        result = subprocess.run(['/bin/bash', str(ROOT / script)], cwd=work, env=env, capture_output=True, text=True, timeout=20)
        final = json.loads(state_file.read_text())
        if failure and failure['remaining'] >= 4:
            assert result.returncode != 0, result.stdout + result.stderr
            assert checkpoint.read_text().strip() == 'fixture-40', 'Failed job advanced checkpoint'
            if existing:
                assert final['pages'][0]['properties']['updated_at']['date']['start'] == '2026-10-19T00:00:00Z', 'Failed update set completion marker'
                assert any(b['id'] == 'keep-note' for b in final['blocks']), 'Unrelated note was deleted'
            if failure['action'] == 'append':
                assert all(call[0] not in ['delete', 'properties'] for call in final['calls']), 'Deleted old content before replacement was accepted'
            if failure['action'] == 'create' and failure.get('status') == 503:
                assert sum(action == 'create' for action, _ in final['calls']) == 1, 'Non-idempotent write blindly retried'
            if not recover:
                return
            final['failure'] = None
            state_file.write_text(json.dumps(final))
            result = subprocess.run(['/bin/bash', str(ROOT / script)], cwd=work, env=env, capture_output=True, text=True, timeout=20)
            final = json.loads(state_file.read_text())
        assert result.returncode == 0, result.stdout + result.stderr
        assert checkpoint.read_text().strip() == ('fixture-40' if script == 'webhook-sync.sh' else 'fixture-42')
        if script == 'sync.sh':
            assert len(final['pages']) == 2, 'Pagination/retry duplicated or skipped receipts'
            assert any(action == 'receipts-page2' for action, _ in final['calls']), 'Did not fetch every receipt page'
            assert 'Created' in result.stdout, 'No batch summary'
        if existing:
            assert any(b['id'] == 'keep-note' for b in final['blocks'])
            assert len([b for b in final['blocks'] if b['type'] == 'table']) == 1, 'Retry left duplicate receipt tables'
            actions = [action for action, status in final['calls'] if status == 200]
            assert actions.index('append') < actions.index('delete') < actions.index('properties'), 'Unsafe replacement/completion ordering'


if __name__ == 'curl_fixture':
    curl_fixture()
elif __name__ == '__main__':
    run_case()
    run_case({'action': 'create', 'remaining': 4, 'status': 400})
    run_case({'action': 'create', 'remaining': 4, 'status': 503})
    run_case({'action': 'create', 'remaining': 1, 'status': 429})
    run_case({'action': 'receipts-page2', 'remaining': 4, 'status': 500})
    run_case({'action': 'query', 'remaining': 4, 'status': 403})
    run_case({'action': 'append', 'remaining': 4, 'status': 400}, existing=True)
    run_case({'action': 'properties', 'remaining': 4, 'status': 400}, existing=True, recover=True)
    run_case({'action': 'delete', 'remaining': 4, 'status': 500}, existing=True, recover=True)
    run_case(existing=True)
    run_case({'action': 'create', 'remaining': 4, 'status': 400, 'receipt': 'fixture-42'}, recover=True)
    run_case({'action': 'receipts', 'remaining': 4, 'status': 200, 'invalid_json': True})
    run_case(script='webhook-sync.sh')
    run_case({'action': 'create', 'remaining': 4, 'status': 400}, script='webhook-sync.sh')
    print('PASS: 14 stateful cases cover pagination, checkpoint retention, 429 recovery, ambiguous-write retry policy, safe table replacement/recovery, note preservation and webhook cursor isolation. No network calls.')
