#!/usr/bin/env python3
"""Production URLSession pin delegate + real TLS receiver via fixed loopback proxy. No OS input."""
import json,os,pathlib,queue,socket,subprocess,tempfile,threading
ROOT=pathlib.Path(__file__).resolve().parents[1]
DOTNET=os.environ.get('SOFATAP_DOTNET',str(ROOT/'.tools/dotnet/dotnet'))
with tempfile.TemporaryDirectory(prefix='sofatap-peer-tls-') as tmp:
    tmp=pathlib.Path(tmp)
    lifecycle=tmp/'lifecycle'
    subprocess.run(['xcrun','swiftc','-warnings-as-errors',str(ROOT/'ios/SofaTap/Core/PeerTLSBridge.swift'),str(ROOT/'tests/PeerTLSBridgeLifecycleTests.swift'),'-o',str(lifecycle)],check=True,timeout=60)
    subprocess.run([str(lifecycle)],check=True,timeout=10)
    delegate=(ROOT/'ios/SofaTap/Core/Pairing.swift').read_text().split('final class PinnedSessionDelegate:',1)[1]
    fixture=tmp/'Pin.swift'
    fixture.write_text('import Foundation\nimport Security\nimport CryptoKit\nstruct Pairing { let host: String; let port: Int; let fingerprint: String }\nfinal class PinnedSessionDelegate:'+delegate)
    binary=tmp/'runner'
    subprocess.run(['xcrun','swiftc','-warnings-as-errors',str(fixture),str(ROOT/'desktop/macos/MacPeerRelay.swift'),str(ROOT/'ios/SofaTap/Core/PeerTLSBridge.swift'),str(ROOT/'tests/PeerTLSBridgeRunner.swift'),'-o',str(binary)],check=True,timeout=60)
    with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    with (tmp/'server.log').open('w') as log:
        server=subprocess.Popen([DOTNET,str(ROOT/'host/bin/Release/net10.0/SofaTap.dll'),'--native-ui','--dry-run','--data-dir',str(tmp/'profile'),'--control-port',str(port)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True)
        states=queue.Queue()
        def pump():
            for line in server.stdout:
                try: states.put(json.loads(line))
                except ValueError: pass
        reader=threading.Thread(target=pump,daemon=True);reader.start()
        try:
            state=states.get(timeout=10);assert state['dryRun']
            config=tmp/'config.json';config.write_text(json.dumps({'uri':state['pairings'][0]['uri']}));config.chmod(0o600)
            checks=[]
            for mode in ['valid','bad-pin','bad-hostname','bad-token','stopped-bridge','stopped-relay']:
                run=subprocess.run([str(binary),str(config),mode],capture_output=True,text=True,timeout=12)
                if run.returncode: raise AssertionError(mode+': '+run.stdout[-200:]+(' unexpected connection' if 'negative fixture unexpectedly connected' in run.stderr else ''))
                checks.append(mode);print(run.stdout.strip())
            destination=ROOT/'artifacts/pointer-development/peer-tls-bridge-e2e.json'
            destination.parent.mkdir(parents=True,exist_ok=True)
            destination.write_text(json.dumps({'mode':'real pinned TLS/WebSocket via explicit loopback TLS bridge; dry-run, no OS input','passed':checks},indent=2)+'\n')
        finally:
            server.stdin.close()
            try: server.wait(timeout=5)
            except subprocess.TimeoutExpired:server.kill();server.wait(timeout=5)
            reader.join(timeout=2);server.stdout.close()
