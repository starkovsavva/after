#!/usr/bin/env python3
"""Exercise libpulse capture on a private virtual PipeWire graph, without devices."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
TEST = "capture_platform::linux::tests::private_source_captures_pcm_and_saves_through_the_canonical_queue"
CONFIG = '''
context.properties = { core.daemon = true core.name = after-fixture support.dbus = false default.clock.rate = 48000 }
context.spa-libs = { support.* = support/libspa-support audio.convert.* = audioconvert/libspa-audioconvert }
context.modules = [
 { name = libpipewire-module-protocol-native }
 { name = libpipewire-module-metadata }
 { name = libpipewire-module-spa-node-factory }
 { name = libpipewire-module-client-node }
 { name = libpipewire-module-access args = { access.force = unrestricted } }
 { name = libpipewire-module-adapter }
 { name = libpipewire-module-link-factory }
 { name = libpipewire-module-protocol-pulse }
]
pulse.properties = { server.address = [ "unix:SOCKET" ] }
context.objects = [
 { factory = metadata args = { metadata.name = default metadata.values = [ { key = default.audio.source value = { name = fixture-mic } } ] } }
 { factory = spa-node-factory args = { factory.name = support.node.driver node.name = Fixture-Driver priority.driver = 20000 } }
 { factory = adapter args = { factory.name = support.null-audio-sink node.name = fixture-mic node.description = "Fixture Mic" media.class = "Audio/Source/Virtual" audio.position = [ MONO ] monitor.passthrough = true adapter.auto-port-config = { mode = dsp monitor = true position = preserve } } }
]
'''


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario', choices=('capture', 'disconnect', 'monitor'), default='capture')
    parser.add_argument('--engine', type=Path, default=PROJECT / '.build/rust/debug/posle-engine')
    args = parser.parse_args()
    for tool in ('pipewire', 'pw-link', 'pw-cli', 'pw-dump', 'pactl', 'cargo'):
        if not shutil.which(tool):
            parser.error(f'{tool} is required for the private virtual-audio fixture')
    if not args.engine.is_file():
        parser.error('Build the canonical debug engine first')
    build_env = os.environ.copy()
    build_env['CARGO_TARGET_DIR'] = str(PROJECT / '.build/tauri')
    build = subprocess.run(['cargo', 'test', '--manifest-path', str(PROJECT / 'desktop/src-tauri/Cargo.toml'),
                            '--locked', '--lib', '--features', 'linux-audio-fixture', '--no-run', '--message-format=json'],
                           cwd=PROJECT, env=build_env, capture_output=True, text=True, timeout=300)
    if build.returncode:
        raise RuntimeError(build.stderr[-5000:] + build.stdout[-5000:])
    binary = None
    for line in build.stdout.splitlines():
        artifact = json.loads(line)
        if artifact.get('reason') == 'compiler-artifact' and artifact.get('executable') and artifact['target']['name'] == 'after_desktop':
            binary = artifact['executable']
    if binary is None:
        raise RuntimeError('Cargo did not produce the native test binary')
    with tempfile.TemporaryDirectory(prefix='after-linux-audio-') as folder:
        root = Path(folder)
        socket = root / 'pulse.sock'
        cookie = root / 'cookie'
        cookie.write_bytes(bytes(256))
        (root / 'fixture-only').write_text('virtual source only; no hardware modules\n')
        config = root / 'after-fixture.conf'
        config_text = CONFIG.replace('SOCKET', str(socket))
        if args.scenario == 'monitor':
            config_text = config_text.replace('Audio/Source/Virtual', 'Audio/Sink')
        config.write_text(config_text)
        client_config = root / 'pulse-client.conf'
        client_config.write_text(f'autospawn = no\ndefault-server = unix:{socket}\ncookie-file = {cookie}\n')
        env = os.environ.copy()
        env.update(PIPEWIRE_RUNTIME_DIR=folder, PIPEWIRE_CONFIG_DIR=folder, PIPEWIRE_REMOTE='after-fixture',
                   XDG_RUNTIME_DIR=folder, PULSE_SERVER=f'unix:{socket}', PULSE_COOKIE=str(cookie),
                   PULSE_CLIENTCONFIG=str(client_config), AFTER_TEST_PULSE_SOCKET=str(socket),
                   AFTER_TEST_ENGINE_PATH=str(args.engine.resolve()), AFTER_TEST_AUDIO_SCENARIO=args.scenario)
        (root / 'after-client.conf').write_text('context.modules = [ { name = libpipewire-module-protocol-native } { name = libpipewire-module-metadata } ]\n')
        link_env = env.copy()
        link_env['PIPEWIRE_CONFIG_NAME'] = 'after-client.conf'
        server = test = None
        with (root / 'server.log').open('w') as server_log, (root / 'test.log').open('w') as test_log:
            try:
                server = subprocess.Popen(['pipewire', '-c', str(config)], env=env, stdout=server_log, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 5
                while not socket.exists() and server.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                sources = subprocess.run(['pactl', f'--server=unix:{socket}', '--format=json', 'list', 'sources'],
                                         env=env, capture_output=True, text=True, timeout=3, check=True)
                source_rows = json.loads(sources.stdout)
                expected_name = 'fixture-mic.monitor' if args.scenario == 'monitor' else 'fixture-mic'
                if len(source_rows) != 1 or source_rows[0]['name'] != expected_name or (source_rows[0].get('properties', {}).get('device.class') == 'monitor') != (args.scenario == 'monitor'):
                    raise RuntimeError('Fixture did not expose the expected sole virtual source')
                selected = subprocess.run(['pactl', f'--server=unix:{socket}', 'get-default-source'], env=env, capture_output=True, text=True, timeout=3, check=True)
                if selected.stdout.strip() != expected_name:
                    raise RuntimeError(f'Fixture default source mismatch: {selected.stdout!r}')
                test = subprocess.Popen([binary, '--exact', TEST, '--nocapture'], env=env,
                                        stdout=test_log, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 20
                linked = set()
                configured = set()
                last_graph = []
                while test.poll() is None and time.monotonic() < deadline:
                    # No session manager or hardware discovery runs in this graph.
                    # Explicitly link its sole virtual output to record-client inputs.
                    if (root / 'disconnect-now').exists() and server.poll() is None:
                        stop(server)
                    if server.poll() is not None:
                        time.sleep(.05)
                        continue
                    graph = subprocess.run(['pw-dump'], env=link_env, capture_output=True, text=True, timeout=2, check=True)
                    last_graph = json.loads(graph.stdout)
                    for node in last_graph:
                        props = node.get('info', {}).get('props', {})
                        if node.get('type') == 'PipeWire:Interface:Node' and props.get('media.class') == 'Stream/Input/Audio' and node['id'] not in configured:
                            result = subprocess.run(['pw-cli', 'set-param', str(node['id']), 'PortConfig',
                                '{ direction: Input mode: dsp format: { mediaType: audio mediaSubtype: raw format: F32P rate: 48000 channels: 1 position: [ MONO ] } }'],
                                env=link_env, capture_output=True, text=True, timeout=2)
                            if result.returncode == 0:
                                configured.add(node['id'])
                    ports = subprocess.run(['pw-link', '-i'], env=link_env, capture_output=True, text=True, timeout=2, check=True)
                    for port in ports.stdout.splitlines():
                        if port and not port.startswith('fixture-mic:') and port not in linked:
                            result = subprocess.run(['pw-link', 'fixture-mic:capture_MONO', port], env=link_env,
                                                    capture_output=True, timeout=2)
                            if result.returncode == 0:
                                linked.add(port)
                    time.sleep(.05)
                if test.poll() is None:
                    raise RuntimeError('Private audio capture exceeded its deadline')
                test_log.flush()
                output = (root / 'test.log').read_text()
                if test.returncode or '1 passed' not in output:
                    raise RuntimeError(output[-5000:])
                print(json.dumps({'passed': True, 'privateVirtualSource': True, 'physicalDevicesUsed': False,
                                  'realLibpulse': True, 'scenario': args.scenario, 'canonicalQueuedImport': args.scenario != 'monitor'}, indent=2))
            except Exception:
                server_log.flush()
                print((root / 'server.log').read_text()[-2000:])
                print('linked fixture inputs:', sorted(linked) if 'linked' in locals() else [])
                test_log.flush()
                print((root / 'test.log').read_text()[-4000:])
                raise
            finally:
                stop(test)
                stop(server)


if __name__ == '__main__':
    main()
