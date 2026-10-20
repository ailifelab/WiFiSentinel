import Foundation
import Network
import RecoveryCore

private final class ServerPlan: @unchecked Sendable {
    private let lock=NSLock();private var body:Data?=Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\na".utf8)
    private var connections:[NWConnection]=[]
    func set(_ value:String?){lock.lock();body=value.map{Data($0.utf8)};lock.unlock()}
    func answer(_ c:NWConnection){lock.lock();connections.append(c);let value=body;lock.unlock();if let value{c.send(content:value,completion:.contentProcessed{_ in})}}
    func close(){lock.lock();let values=connections;connections=[];lock.unlock();values.forEach{$0.cancel()}}
}
@main struct AdapterTests {
    @MainActor static func main() async {
        var count=0,failed=0
        func check(_ name:String,_ body:() async -> Bool) async {count += 1;if await body(){print("PASS \(name)")}else{failed += 1;print("FAIL \(name)")}}
        await check("default child environment preserves explicit fixture permission token"){let r=await BoundedProcess.run(URL(fileURLWithPath:"/usr/bin/printenv"),["WIFISENTINEL_OFFLINE_ENV_FIXTURE"],seconds:1);return r.status==0 && String(decoding:r.output,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)=="offline-child-inherited-value"}
        await check("explicit child environment remains isolated"){let r=await BoundedProcess.run(URL(fileURLWithPath:"/usr/bin/printenv"),["WIFISENTINEL_OFFLINE_ENV_FIXTURE"],seconds:1,environment:["WIFISENTINEL_OFFLINE_ENV_FIXTURE":"explicit-fixture-value"]);return r.status==0 && String(decoding:r.output,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)=="explicit-fixture-value"}
        await check("owned process normal output and exit captured"){let r=await BoundedProcess.run(URL(fileURLWithPath:"/bin/echo"),["fixture-result"],seconds:1);return r.reaped && r.status==0 && String(decoding:r.output,as:UTF8.self).contains("fixture-result")}
        await check("hung command bounded and reaped"){let start=ProcessInfo.processInfo.systemUptime;let r=await BoundedProcess.run(URL(fileURLWithPath:"/bin/sleep"),["30"],seconds:0.15);return r.timedOut && r.reaped && ProcessInfo.processInfo.systemUptime-start<1.5}
        await check("no shell interpretation in arguments"){let r=await BoundedProcess.run(URL(fileURLWithPath:"/bin/echo"),["$(id); literal"],seconds:1);return String(decoding:r.output,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)=="$(id); literal"}
        await check("large output cannot deadlock or grow capture"){let r=await BoundedProcess.run(URL(fileURLWithPath:"/usr/bin/yes"),["fixture"],seconds:0.15);return r.timedOut && r.reaped && r.output.count<=16384}
        await check("spawn failure returns finite error"){let r=await BoundedProcess.run(URL(fileURLWithPath:"/missing-wifisentinel-fixture"),[],seconds:1);return r.status == -1 && r.reaped && !r.error.isEmpty}
        for status in [301,302,307,308]{await check("HTTP portal distinct from timeout \(status)"){WebPulse.nonSuccessStatus(status) == .portal}}
        for status in [401,403,429,500,503]{await check("HTTP error distinct from timeout \(status)"){WebPulse.nonSuccessStatus(status) == .httpError}}
        await check("successful HTTP headers still require body policy"){WebPulse.nonSuccessStatus(200)==nil && WebPulse.nonSuccessStatus(204)==nil}
        for (code,want) in [(NSURLErrorTimedOut,Signal.timeout),(NSURLErrorDNSLookupFailed,.dnsFailure),(NSURLErrorCannotFindHost,.dnsFailure),(NSURLErrorSecureConnectionFailed,.tlsFailure),(NSURLErrorServerCertificateUntrusted,.tlsFailure),(NSURLErrorUserAuthenticationRequired,.permissionDenied),(NSURLErrorCannotConnectToHost,.refused)]{
            await check("URL error category \(code)"){WebPulse.errorSignal(NSError(domain:NSURLErrorDomain,code:code))==want}
        }
        await check("invalid deadline never spawns command"){let r=await BoundedProcess.run(URL(fileURLWithPath:"/bin/sleep"),["30"],seconds:.infinity);return r.status == -1 && !r.timedOut}
        for (label,active,addresses,gateway,want) in [
            ("detached",Optional(false),[String](),"",Attachment.detached),
            ("stale IPv4 not detached",Optional(false),["192.0.2.2"],"",.unknown),
            ("stale IPv6 not detached",Optional(false),["2001:db8::2"],"",.unknown),
            ("IPv6-only not false outage",Optional(true),["2001:db8::2"],"",.configuring),
            ("attached IPv4",Optional(true),["192.0.2.2"],"192.0.2.1",.attached),
            ("missing link state",nil,["192.0.2.2"],"192.0.2.1",.unknown),
            ("waiting DHCP",Optional(true),[String](),"192.0.2.1",.configuring),
            ("conflicting route",Optional(true),["192.0.2.2"],"",.configuring)] {
            await check("native state classifier: "+label){NativeHelper.classify(active:active,addresses:addresses,gateway:gateway)==want}
        }
        await check("repeated bounded workers are all reaped"){for _ in 0..<5{let r=await BoundedProcess.run(URL(fileURLWithPath:"/bin/sleep"),["30"],seconds:0.03);if !r.reaped{return false}};return true}
        let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("WiFiSentinel-tests-\(UUID().uuidString)")
        let store=Store(directory:root)
        await check("fresh settings have no old recovery permission"){let s=store.load();return s.interval==60 && s.cooldown==300 && !s.internetTrial}
        await check("settings roundtrip and independent from logs"){var s=Settings();s.customURL="https://example.org/";do{try store.save(s);return store.load()==s}catch{return false}}
        await check("bounded abnormal logs rotate at256KiB"){for i in 0..<600{store.append(Event(.attention,"fixture \(i) "+String(repeating:"x",count:650)))};return store.logBytes<=262144 && store.logBytes>100000 && store.history().count<=200}
        await check("log cleanup keeps settings"){let before=store.load();do{try store.clearLogs();return store.logBytes==0 && store.load()==before}catch{return false}}
        await check("trial lock survives log cleanup and reload"){var latch=TrialLatch();latch.consumed=true;latch.notBeforeWall=2000;latch.lastResult="failed";guard store.saveTrialLatch(latch) else{return false};do{try store.clearLogs();return store.loadTrialLatch()==latch}catch{return false}}
        await check("malformed stored trial state fails closed"){do{try Data("not-json".utf8).write(to:root.appendingPathComponent("trial-latch-v1.json"));return store.loadTrialLatch().consumed}catch{return false}}
        await check("event symlink is refused without touching target"){
            let outside=root.appendingPathComponent("outside-fixture.txt");do{try Data("preserve".utf8).write(to:outside);try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("events.jsonl").path,withDestinationPath:outside.path);store.append(Event(.attention,"blocked"));let preserved=try String(contentsOf:outside,encoding:.utf8);return store.failure != nil && preserved=="preserve"}catch{return false}
        }
        try?FileManager.default.removeItem(at:root)
        if ProcessInfo.processInfo.environment["WIFISENTINEL_OFFLINE_ONLY"] != "1" {
        do {
            let params=NWParameters.tcp;params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
            let listener=try NWListener(using:params),queue=DispatchQueue(label:"WiFiSentinel.loopback-fixture"),plan=ServerPlan()
            listener.newConnectionHandler={c in c.start(queue:queue);c.receive(minimumIncompleteLength:1,maximumLength:2048){_,_,_,_ in plan.answer(c)}}
            try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in listener.stateUpdateHandler={state in if case .ready=state{listener.stateUpdateHandler=nil;c.resume()}else if case .failed(let e)=state{listener.stateUpdateHandler=nil;c.resume(throwing:e)}};listener.start(queue:queue)}
            let url=URL(string:"http://127.0.0.1:\(listener.port!.rawValue)/")!
            await check("loopback first byte validates response"){await WebPulse.probe(url) == .response}
            plan.set("HTTP/1.1 503 Down\r\nContent-Length: 0\r\n\r\n")
            await check("HTTP error is distinct, never a WiFi timeout"){await WebPulse.probe(url) == .httpError}
            plan.set("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/\r\nContent-Length: 0\r\n\r\n")
            await check("redirect is not followed or used as failure evidence"){await WebPulse.probe(url) == .portal}
            plan.set("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n")
            await check("headers alone cannot validate body"){let start=ProcessInfo.processInfo.systemUptime;let value=await WebPulse.probe(url);return value == .timeout && ProcessInfo.processInfo.systemUptime-start<3}
            plan.set(nil)
            await check("absolute HTTP deadline handles hung response"){let start=ProcessInfo.processInfo.systemUptime;let value=await WebPulse.probe(url);return value == .timeout && ProcessInfo.processInfo.systemUptime-start<3}
            listener.cancel();plan.close()
        }catch{failed += 1;count += 1;print("FAIL loopback setup: \(error)")}
        }
        print("RESULT \(count-failed)/\(count) adapter scenarios; \(failed) failed")
        exit(failed==0 ? 0:1)
    }
}
