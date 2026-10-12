"""Run the real Swift transport against a disposable stock daemon over loopback SSH.

Usage (macOS with stock herdr, sshd, ssh-keygen and XcodeBuildMCP installed):
    python3 client/Tests/HerdrKitTests/Fixtures/upstream_ssh_fixture.py

Generates temporary host/user keys, creates fresh Herdr config/state/socket,
forces every SSH exec through that isolated environment, runs the upstream unit and SSH integration tests,
and stops both processes. Existing sessions and authorized_keys are never used.
"""
import json, os, pathlib, pwd, shutil, socket, subprocess, tempfile, time

binary = shutil.which('herdr')
assert binary, 'stock herdr must be installed'
user = pwd.getpwuid(os.getuid()).pw_name
with tempfile.TemporaryDirectory(prefix='herdr-swift-ssh-') as tmp:
    path = pathlib.Path(tmp)
    env = {k:v for k,v in os.environ.items() if not k.startswith('HERDR_')}
    env.update(XDG_CONFIG_HOME=tmp+'/config', XDG_STATE_HOME=tmp+'/state', HERDR_SOCKET_PATH=tmp+'/api.sock', SHELL='/bin/sh')
    config = path/'config/herdr'; config.mkdir(parents=True)
    (config/'config.toml').write_text('[terminal]\ndefault_shell = "/bin/sh"\nshell_mode = "non_login"\n')
    for key in ['host-key','client-key']:
        subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(path/key)],check=True)
    (path/'authorized_keys').write_text((path/'client-key.pub').read_text())
    wrapper = path/'isolate.sh'
    import shlex
    wrapper.write_text('#!/bin/sh\n'+ ''.join('export '+k+'='+shlex.quote(env[k])+'\n' for k in ['XDG_CONFIG_HOME','XDG_STATE_HOME','HERDR_SOCKET_PATH','SHELL']) + 'export PATH='+shlex.quote(str(pathlib.Path(binary).parent)+':/usr/bin:/bin:/usr/sbin:/sbin')+'\nexec /bin/sh -c "$SSH_ORIGINAL_COMMAND"\n')
    wrapper.chmod(0o700)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
    ssh_config=path/'sshd_config'
    ssh_config.write_text(f'Port {port}\nListenAddress 127.0.0.1\nHostKey {path}/host-key\nPidFile {path}/sshd.pid\nAuthorizedKeysFile {path}/authorized_keys\nStrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nPermitRootLogin no\nAllowUsers {user}\nForceCommand {wrapper}\nLogLevel VERBOSE\n')
    log=open(path/'daemon.log','wb'); sshlog=open(path/'ssh.log','wb')
    daemon=subprocess.Popen([binary,'server'],cwd=tmp,env=env,stdout=log,stderr=log)
    ssh=None
    def api(method, params=None):
        result=subprocess.run([binary,'remote-api-bridge'],input=json.dumps(dict(id='fixture',method=method,params=params or {}))+'\n',text=True,capture_output=True,env=env,timeout=10,check=True)
        reply=json.loads(result.stdout); assert 'error' not in reply,reply; return reply['result']
    try:
        deadline=time.monotonic()+10
        while not (path/'api.sock').exists():
            assert daemon.poll() is None,(path/'daemon.log').read_text()
            assert time.monotonic()<deadline,'daemon socket timeout'
            time.sleep(.05)
        api('workspace.create',dict(cwd=tmp,label='swift-isolated',focus=True))
        pane=api('pane.list')['panes'][0]
        ssh=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(ssh_config)],stdout=sshlog,stderr=sshlog)
        deadline=time.monotonic()+10
        while True:
            assert ssh.poll() is None,(path/'ssh.log').read_text()
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.2): pass
                break
            except OSError:
                assert time.monotonic()<deadline,'sshd timeout';time.sleep(.05)
        test_env=os.environ.copy()
        test_env.update(HERDR_UPSTREAM_ISOLATED_TEST='1',HERDR_UPSTREAM_TEST_KEY=str(path/'client-key'),HERDR_UPSTREAM_TEST_PORT=str(port),HERDR_UPSTREAM_TEST_USER=user,HERDR_UPSTREAM_TEST_TERMINAL=pane['terminal_id'],HERDR_UPSTREAM_TEST_PANE=pane['pane_id'])
        print('Isolated stock daemon and loopback SSH ready',flush=True)
        try:
            result=subprocess.run(['xcodebuildmcp','swift-package','test','--package-path',str(pathlib.Path(__file__).resolve().parents[3]),'--filter','Upstream'],env=test_env,timeout=180)
            assert result.returncode==0,f'Swift test exited {result.returncode}'
        except BaseException:
            print((path/'ssh.log').read_text(),flush=True)
            raise
    finally:
        if ssh: ssh.terminate();ssh.wait(timeout=5)
        try: api('server.stop')
        except Exception: daemon.terminate()
        try: daemon.wait(timeout=5)
        except subprocess.TimeoutExpired: daemon.kill();daemon.wait()
        log.close();sshlog.close()
