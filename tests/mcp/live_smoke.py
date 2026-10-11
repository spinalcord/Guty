#!/usr/bin/env python3
"""Opt-in end-to-end checks against an open editor; stops only its own runs."""
import argparse
import json
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--url', default='http://127.0.0.1:9081/mcp')
args = parser.parse_args()
sequence = 0
version = '2025-11-25'
owned_run = None


def rpc(method, params=None, origin=None):
    global sequence
    sequence += 1
    body = {'jsonrpc': '2.0', 'method': method, 'params': params or {}}
    if not method.startswith('notifications/'):
        body['id'] = sequence
    headers = {'Content-Type': 'application/json',
               'Accept': 'application/json, text/event-stream',
               'MCP-Protocol-Version': version}
    if origin:
        headers['Origin'] = origin
    request = urllib.request.Request(args.url, json.dumps(body).encode(), headers)
    with urllib.request.urlopen(request, timeout=8) as response:
        raw = response.read()
        if response.status == 202:
            return {}
        result = json.loads(raw)
        assert type(result.get('id')) is int and result['id'] == sequence, result
        assert 'error' not in result, result
        return result['result']


def tool(name, **kwargs):
    result = rpc('tools/call', {'name': name, 'arguments': kwargs})
    assert not result.get('isError'), result
    return result['structuredContent']


def poll(run_id, predicate, seconds=15):
    # This is a client test deadline, never a server-imposed run limit.
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        status = tool('gut_get_run_status', run_id=run_id)
        if predicate(status):
            return status
        time.sleep(0.2)
    raise AssertionError(f'Client test deadline exceeded: {status}')


def start(test_name, **options):
    global owned_run
    result = tool('gut_run_tests', script='res://tests/mcp/test_fixture.gd',
                  test_name=test_name, **options)
    owned_run = result['run_id']
    return owned_run


def stopped(run_id):
    tool('gut_stop', run_id=run_id)
    return poll(run_id, lambda status: not status['window_open'])


try:
    init = rpc('initialize', {'protocolVersion': version, 'capabilities': {},
                             'clientInfo': {'name': 'gut-live-smoke', 'version': '1'}})
    version = init['protocolVersion']
    rpc('notifications/initialized')
    assert rpc('ping') == {}
    assert len(rpc('tools/list')['tools']) == 7
    assert tool('gut_get_config')['mcp']['enabled']
    try:
        rpc('ping', origin='https://evil.example')
        raise AssertionError('Invalid Origin accepted')
    except urllib.error.HTTPError as error:
        assert error.code == 403
    for name, arguments in [('gut_get_run_status', {'run_id': 'missing'}),
                            ('gut_list_tests', {'limit': 101}),
                            ('gut_run_tests', {'ignore_pause': 'false'}),
                            ('gut_run_tests', {'script': 'res://tests/mcp/test_fixture.gd',
                                              'test_name': 'no_match'})]:
        assert rpc('tools/call', {'name': name, 'arguments': arguments})['isError']
    listed = tool('gut_list_tests', script='res://tests/mcp/test_fixture.gd',
                  inner_class='TestInner', test_name='success', limit=1)
    assert listed['total'] == 1 and listed['items'][0]['inner_class'] == 'TestInner'
    for name, field in [('success', 'passing'), ('failure', 'failures'), ('pending', 'pending')]:
        run_id = start(name)
        poll(run_id, lambda status: status['state'] == 'completed' and not status['window_open'])
        results = tool('gut_get_results', run_id=run_id)
        assert not results['incomplete'] and results['summary'][field] >= 1
        if name == 'success':
            assert tool('gut_get_results', run_id=run_id, section='warnings')['total'] >= 1
        assert tool('gut_get_results', run_id=run_id, section='output')['total'] > 0
    run_id = start('inner_success', inner_class='TestInner')
    poll(run_id, lambda status: status['state'] == 'completed' and not status['window_open'])
    assert tool('gut_get_results', run_id=run_id)['summary']['tests'] == 1
    run_id = start('pause', ignore_pause=False)
    poll(run_id, lambda status: status['state'] == 'gut_paused')
    tool('gut_continue', run_id=run_id)
    poll(run_id, lambda status: status['state'] == 'completed' and not status['window_open'])
    for name in ['waiting', 'blocking']:
        run_id = start(name)
        poll(run_id, lambda status: status['current_test'].get('test_name') == 'test_' + name)
        assert tool('gut_get_results', run_id=run_id)['incomplete']
        assert stopped(run_id)['state'] == 'aborted'
        assert tool('gut_get_config')['mcp']['enabled']
    run_id = start('success', close_on_finish=False)
    assert poll(run_id, lambda status: status['state'] == 'completed')['window_open']
    assert stopped(run_id)['state'] == 'completed'
    assert tool('gut_stop', run_id=run_id)['already_stopped']
    newer = start('success')
    assert tool('gut_stop', run_id=run_id)['already_stopped']
    poll(newer, lambda status: status['state'] == 'completed' and not status['window_open'])
    print('Live MCP checks passed')
finally:
    if owned_run:
        # Never stop a panel run, game session, or a run created by another client.
        tool('gut_stop', run_id=owned_run)
