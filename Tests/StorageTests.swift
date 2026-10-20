import Foundation
import RecoveryCore

@MainActor final class SnapshotClock:Clock {var now=0.0;func wait(_ seconds:Double) async{now += seconds}}
@MainActor final class SnapshotBackend:Backend {
    let clock:Clock
    init(_ clock:Clock){self.clock=clock}
    func inspect(_ settings:Settings) async ->Sample {Sample(link:Link(interface:"fake0",identity:"fake",power:.on,attachment:.attached),local:.response,internet:[.response,.response],sampledAt:clock.now,boundInterface:"fake0")}
    func readPower(interface:String) async->Power{.on}
    func command(on:Bool,interface:String) async->CommandResult{fatalError("offline snapshot tests must never call radio control")}
}
@main struct StorageTests {
    @MainActor static func main() async {
        var count=0,failed=0
        let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("WiFiSentinel-policy-storage-\(UUID().uuidString)")
        try!FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try?FileManager.default.removeItem(at:root)}
        func check(_ name:String,_ body:() async throws->Bool) async {count += 1;do{if try await body(){print("PASS \(name)")}else{failed += 1;print("FAIL \(name)")}}catch{failed += 1;print("FAIL \(name): \(error)")}}
        func store()->Store{Store(directory:root.appendingPathComponent(UUID().uuidString))}
        func snapshot(_ at:Double)->RuntimeSnapshot {
            let clock=SnapshotClock();clock.now=at;let backend=SnapshotBackend(clock),core=Coordinator(backend:backend,clock:clock)
            return core.runtimeSnapshot()
        }
        await check("fresh storage has no inherited attempt quota"){let s=store().loadAutomaticState();return s.valid && s.failures==0 && s.automaticTotal==0}
        await check("failure and cooldown atomic persistence roundtrips"){let a=store();var s=AutomaticState();_=s.time.advance(ClockReading(boot:"a",awake:100,continuous:100,wall:1000));s.prepare(automatic:true);s.finish(automatic:true,success:false,radioSafe:true,manualDelay:300);s.prepare(automatic:true);s.finish(automatic:true,success:false,radioSafe:true,manualDelay:300);return a.saveAutomaticState(s) && Store(directory:a.directory).loadAutomaticState()==s}
        await check("log cleanup never erases policy cooldown"){let a=store();let s=AutomaticState.upgrade(legacy:nil,unverified:true);guard a.saveAutomaticState(s) else{return false};a.append(Event(.attention,"fixture"));try a.clearLogs();return a.loadAutomaticState()==s && a.logBytes==0}
        await check("legacy consumed lock becomes30minute cooling"){let a=store();var l=TrialLatch();l.consumed=true;guard a.saveTrialLatch(l) else{return false};let s=a.loadAutomaticState();return s.failures==2 && s.retryWait==1800 && !s.manualIntervention}
        await check("invalid legacy lock also migrates conservatively"){let a=store();try FileManager.default.createDirectory(at:a.directory,withIntermediateDirectories:true);try Data("bad".utf8).write(to:a.directory.appendingPathComponent("trial-latch-v1.json"));return a.loadAutomaticState().cooling}
        await check("malformed new state fails closed"){let a=store();try FileManager.default.createDirectory(at:a.directory,withIntermediateDirectories:true);try Data("bad".utf8).write(to:a.directory.appendingPathComponent("retry-policy-v3.json"));return a.loadAutomaticState().cooling && a.failure != nil}
        await check("oversized state fails closed"){let a=store();try FileManager.default.createDirectory(at:a.directory,withIntermediateDirectories:true);try Data(repeating:32,count:8193).write(to:a.directory.appendingPathComponent("retry-policy-v3.json"));return a.loadAutomaticState().cooling}
        await check("semantically invalid decoded state fails closed"){let a=store();try FileManager.default.createDirectory(at:a.directory,withIntermediateDirectories:true);var s=AutomaticState();s.failures=3;try JSONEncoder().encode(s).write(to:a.directory.appendingPathComponent("retry-policy-v3.json"));return a.loadAutomaticState().cooling && !a.saveAutomaticState(s)}
        await check("inflight marker survives disk reload for restart quarantine"){let a=store();var s=AutomaticState();s.prepare(automatic:true);return a.saveAutomaticState(s) && a.loadAutomaticState().inFlight=="automatic"}
        for dangling in [false,true]{
            await check("new state symbolic link refused dangling=\(dangling)"){let a=store();try FileManager.default.createDirectory(at:a.directory,withIntermediateDirectories:true);let target=root.appendingPathComponent(UUID().uuidString);if !dangling{try Data("preserve".utf8).write(to:target)};let path=a.directory.appendingPathComponent("retry-policy-v3.json");try FileManager.default.createSymbolicLink(at:path,withDestinationURL:target);let refused=a.loadAutomaticState().cooling && !a.saveAutomaticState(AutomaticState());let intact=dangling ? !FileManager.default.fileExists(atPath:target.path):try String(contentsOf:target,encoding:.utf8)=="preserve";return refused && intact}
            await check("runtime symbolic link refused dangling=\(dangling)"){let a=store();try FileManager.default.createDirectory(at:a.directory,withIntermediateDirectories:true);let target=root.appendingPathComponent(UUID().uuidString);if !dangling{try Data("preserve".utf8).write(to:target)};try FileManager.default.createSymbolicLink(at:a.directory.appendingPathComponent("runtime-snapshot-v3.json"),withDestinationURL:target);let refused = !a.writeRuntimeSnapshot(snapshot(1));let intact=dangling ? !FileManager.default.fileExists(atPath:target.path):try String(contentsOf:target,encoding:.utf8)=="preserve";return refused && intact}
        }
        await check("legacy dangling link cannot appear to be fresh state"){let a=store();try FileManager.default.createDirectory(at:a.directory,withIntermediateDirectories:true);try FileManager.default.createSymbolicLink(at:a.directory.appendingPathComponent("trial-latch-v1.json"),withDestinationURL:root.appendingPathComponent("missing-legacy"));return a.loadAutomaticState().cooling}
        await check("policy storage directory symlink is refused"){let target=root.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true);let link=root.appendingPathComponent(UUID().uuidString);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target);return !Store(directory:link).saveAutomaticState(AutomaticState())}
        await check("runtime snapshots overwrite one bounded regular file"){let a=store();for i in 0..<100{guard a.writeRuntimeSnapshot(snapshot(Double(i))) else{return false}};let files=try FileManager.default.contentsOfDirectory(atPath:a.directory.path),data=try Data(contentsOf:a.directory.appendingPathComponent("runtime-snapshot-v3.json")),last=try JSONDecoder().decode(RuntimeSnapshot.self,from:data);return files==["runtime-snapshot-v3.json"] && data.count<=16384 && last.generatedContinuous==99}
        await check("snapshot writer coalesces rapid updates to latest atmost1Hz"){let a=store(),writer=SnapshotWriter(store:a);writer.submit(snapshot(1));let path=a.directory.appendingPathComponent("runtime-snapshot-v3.json"),first=try Data(contentsOf:path);for i in 2...100{writer.submit(snapshot(Double(i)))};let before=try Data(contentsOf:path);try await Task.sleep(nanoseconds:1_200_000_000);let last=try JSONDecoder().decode(RuntimeSnapshot.self,from:Data(contentsOf:path));return before==first && last.generatedContinuous==100}
        await check("closed-window coordinator still produces independent snapshot"){let a=store(),writer=SnapshotWriter(store:a),clock=SnapshotClock(),backend=SnapshotBackend(clock);let core=Coordinator(backend:backend,clock:clock,saveState:{a.saveAutomaticState($0)},snapshot:{writer.submit($0)});core.request(.timer);await core.waitForIdle();try await Task.sleep(nanoseconds:1_100_000_000);let data=try Data(contentsOf:a.directory.appendingPathComponent("runtime-snapshot-v3.json")),s=try JSONDecoder().decode(RuntimeSnapshot.self,from:data);return s.sample?.local == .response && !s.automaticPermission && !s.busy && s.schema==3}
        print("RESULT \(count-failed)/\(count) storage scenarios; \(failed) failed");exit(failed==0 ? 0:1)
    }
}
