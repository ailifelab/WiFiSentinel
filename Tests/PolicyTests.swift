import Foundation
import RecoveryCore

@MainActor final class PolicyClock:Clock {
    var now=0.0,awakeNow=0.0,wallNow=1_800_000_000.0,bootID="boot-a"
    func advance(_ seconds:Double){now += seconds;awakeNow += seconds;wallNow += seconds}
    func sleep(_ seconds:Double){now += seconds;wallNow += seconds}
    func wait(_ seconds:Double) async{advance(seconds);await Task.yield()}
}
@MainActor final class PolicyJournal {
    var value=AutomaticState(),writable=true,writes=0,snapshots:[RuntimeSnapshot]=[]
    func save(_ state:AutomaticState)->Bool{writes += 1;if writable{value=state};return writable}
}
@MainActor final class PolicyBackend:Backend {
    let clock:PolicyClock
    var local:Signal = .response,internet:[Signal]=[.timeout,.timeout],power:Power = .on
    var attached:Attachment = .attached,identity="test-link",interface="fake0",sleeping=false,wired=false,bound=true,age=0.0
    var off=0,on=0,heal=false,permissionError=false,onFails=false,commandsSettled=true
    var offTimes:[Double]=[],onTimes:[Double]=[],onInspect:(()->Void)?,onCommand:((Bool)->Void)?
    init(_ clock:PolicyClock){self.clock=clock}
    func inspect(_ settings:Settings) async ->Sample {onInspect?();await Task.yield();return Sample(link:Link(interface:interface,identity:identity,gateway:"192.0.2.1",power:power,attachment:attached,sleeping:sleeping,wired:wired,tunnel:true),local:local,internet:internet,sampledAt:clock.now-age,boundInterface:bound ? interface:nil)}
    func readPower(interface:String) async ->Power{power}
    func command(on:Bool,interface:String) async ->CommandResult {
        onCommand?(on)
        if !on {off += 1;offTimes.append(clock.now);if permissionError{return CommandResult(began:true,power:.on,error:Fault("CoreWLAN",77,"denied"))}}
        else {self.on += 1;onTimes.append(clock.now);if onFails{return CommandResult(began:true,power:.off,error:Fault("CoreWLAN",78,"ON denied"))}}
        power=on ? .on:.off
        if on && heal {local = .response;internet=[.response,.response];attached = .attached}
        return CommandResult(began:true,power:power)
    }
}
@MainActor final class PolicyFixture {
    let clock:PolicyClock,journal:PolicyJournal,backend:PolicyBackend,core:Coordinator
    init(option:Bool=true,automatic:Bool=true,journal:PolicyJournal?=nil,clock:PolicyClock?=nil) {
        let sink=journal ?? PolicyJournal(),timer=clock ?? PolicyClock();self.clock=timer;self.journal=sink;backend=PolicyBackend(timer);var settings=Settings();settings.internetTrial=option
        core=Coordinator(settings:settings,backend:backend,clock:timer,automaticState:sink.value,saveState:{sink.save($0)},snapshot:{sink.snapshots.append($0)})
        if automatic{core.setAutomatic(true)}
    }
    func round(_ after:Double=0,_ trigger:Trigger = .timer) async {clock.advance(after);core.request(trigger);await core.waitForIdle()}
    func confirm() async {await round();await round(60);await round(60)}
    func twoFailures() async {await confirm();await round(60);await round(60);await round(60)}
    func healthy() async {backend.local = .response;backend.internet=[.response,.response];await round()}
    func manual() async {core.request(.explicitRepair,repairConfirmed:true);await core.waitForIdle()}
}
@main struct PolicyTests {
    @MainActor static func main() async {
        var count=0,failures=0
        func test(_ name:String,_ body:() async ->Bool) async{count += 1;if await body(){print("PASS \(name)")}else{failures += 1;print("FAIL \(name)")}}
        await test("both strategy and total permission default off"){let f=PolicyFixture(option:false,automatic:false);return !Settings().internetTrial && !f.core.automatic && !f.core.settings.internetTrial}
        await test("selected strategy without grant never acts"){let f=PolicyFixture(automatic:false);await f.confirm();return f.backend.off==0 && f.core.trialSnapshot.failureRounds==0}
        await test("conservative mode preserves LAN guard"){let f=PolicyFixture(option:false);await f.confirm();return f.backend.off==0}
        await test("dual business timeout permits one action after3rounds120seconds"){let f=PolicyFixture();await f.confirm();return f.backend.off==1 && f.backend.on==1 && f.core.automaticState.failures==1 && f.core.repair?.reason.contains("非Wi-Fi故障诊断")==true}
        await test("manual polling spam cannot manufacture elapsed time"){let f=PolicyFixture();for _ in 0..<20{await f.round(0,.manual)};return f.backend.off==0 && f.core.trialSnapshot.failureRounds==1}
        await test("three rounds still need120seconds"){let f=PolicyFixture();await f.round();await f.round(30);await f.round(30);return f.backend.off==0 && f.core.trialSnapshot.failureRounds==3}
        await test("observed jitter does not reset continuous fault window"){let f=PolicyFixture();await f.round();await f.round(58);await f.round(60);let before=f.backend.off;await f.round(60);return before==0 && f.backend.off==1}
        await test("manual and timer polling share the same window"){let f=PolicyFixture();await f.round(0,.manual);await f.round(60,.timer);await f.round(60,.manual);return f.backend.off==1}
        await test("busy requests coalesce and never overlap radio cycles"){let f=PolicyFixture();f.backend.onInspect={f.core.request(.manual);f.core.request(.explicitRepair,repairConfirmed:true)};await f.confirm();return f.backend.off==1 && f.core.joinedRequests>=6}
        await test("one target timeout never qualifies"){let f=PolicyFixture();f.backend.internet=[.timeout,.response];await f.confirm();return f.backend.off==0}
        for error in [Signal.portal,.httpError,.dnsFailure,.tlsFailure,.permissionDenied,.refused,.unknown]{
            await test("non-timeout error resets window: \(error.rawValue)"){let f=PolicyFixture();await f.round();await f.round(60);f.backend.internet=[.timeout,error];await f.round(60);f.backend.internet=[.timeout,.timeout];await f.round(60);return f.backend.off==0 && f.core.trialSnapshot.failureRounds==1}
        }
        await test("unknown local response is not a WiFi root-cause diagnosis"){let f=PolicyFixture();f.backend.local = .unknown;f.backend.bound=false;await f.confirm();return f.backend.off==1 && f.core.repair?.reason.contains("上游／VPN")==true}
        for protection in 0..<8 {
            await test("physical protection resets pending window \(protection)"){let f=PolicyFixture();await f.round();await f.round(60)
                switch protection{case 0:f.backend.power = .off;case 1:f.backend.power = .unknown;case 2:f.backend.sleeping=true;case 3:f.backend.wired=true;case 4:f.backend.attached = .unknown;case 5:f.backend.interface="";case 6:f.backend.identity="";default:f.backend.age=6}
                await f.round(60);return f.backend.off==0 && f.core.trialSnapshot.failureRounds==0}
        }
        await test("identity change discards prior rounds"){let f=PolicyFixture();await f.round();await f.round(60);f.backend.identity="changed";await f.round(60);return f.backend.off==0 && f.core.trialSnapshot.failureRounds==1}
        await test("long observation gap restarts confirmation"){let f=PolicyFixture();await f.round();await f.round(60);await f.round(600);return f.backend.off==0 && f.core.trialSnapshot.failureRounds==1}
        await test("new total grant needs new confirmation"){let f=PolicyFixture(automatic:false);await f.confirm();f.core.setAutomatic(true);await f.round();return f.backend.off==0 && f.core.trialSnapshot.failureRounds==1}
        await test("first network failure is1of2 with no immediate OFF"){let f=PolicyFixture();await f.confirm();let done=f.clock.now;await f.round();return f.backend.off==1 && f.core.automaticState.failures==1 && f.clock.now==done && f.core.cooldownRemaining==60}
        await test("second action requires a new three-round120second window"){let f=PolicyFixture();await f.confirm();await f.round(60);await f.round(60);let before=f.backend.off;await f.round(60);return before==1 && f.backend.off==2 && f.backend.offTimes[1]-f.backend.onTimes[0]>=210}
        await test("two failed verifications start full1800awake-second cooling"){let f=PolicyFixture();await f.twoFailures();return f.backend.off==2 && f.core.automaticState.failures==2 && f.core.cooldownRemaining==1800 && f.journal.value.cooling}
        await test("every failed attempt waits the full30second verification window"){let f=PolicyFixture();await f.confirm();return abs(f.clock.now-f.backend.onTimes[0]-30)<0.01 && f.core.repair?.internetVerified==false}
        await test("no automatic or manual action during cooling"){let f=PolicyFixture();await f.twoFailures();for _ in 0..<20{await f.round(60);await f.manual()};return f.backend.off==2 && f.core.automaticState.failures==2}
        await test("cooldown expiry alone cannot reuse stale fault evidence"){let f=PolicyFixture();await f.twoFailures();await f.round(1800);return f.backend.off==2 && f.core.automaticState.round==1 && f.core.trialSnapshot.failureRounds==1}
        await test("at expiry continuous recent fault can start a new round"){let f=PolicyFixture();await f.twoFailures();for _ in 0..<29{await f.round(60)};let before=f.backend.off;await f.round(60);return before==2 && f.backend.off==3 && f.core.automaticState.round==1 && f.core.automaticState.failures==1}
        await test("repeated failure rounds do not hit a per-launch cap"){let f=PolicyFixture();await f.twoFailures();for _ in 0..<30{await f.round(60)};await f.round(60);await f.round(60);await f.round(60);for _ in 0..<30{await f.round(60)};return f.backend.off==5 && f.core.automaticState.round==2 && f.core.automaticAttempts==5}
        await test("powerON and local response alone do not clear failures"){let f=PolicyFixture();await f.confirm();await f.round(1);return f.backend.power == .on && f.backend.local == .response && f.core.automaticState.failures==1}
        await test("verified action success clears previous failure"){let f=PolicyFixture();await f.confirm();f.backend.heal=true;await f.round(60);await f.round(60);await f.round(60);return f.backend.off==2 && f.core.automaticState.failures==0 && f.core.repair?.internetVerified==true}
        await test("credible natural health ends cooling early"){let f=PolicyFixture();await f.twoFailures();await f.healthy();return f.core.automaticState.failures==0 && f.core.automaticState.retryWait==0 && !f.core.availability.cooling && f.backend.off==2}
        await test("single-site health cannot clear cooling"){let f=PolicyFixture();await f.twoFailures();f.backend.internet=[.response,.timeout];await f.round();return f.core.automaticState.failures==2}
        await test("unbound LAN health cannot clear cooling"){let f=PolicyFixture();await f.twoFailures();f.backend.internet=[.response,.response];f.backend.bound=false;await f.round();return f.core.automaticState.failures==2}
        await test("manual failed attempt has separate count"){let f=PolicyFixture();await f.manual();return f.core.manualAttempts==1 && f.core.automaticAttempts==0 && f.core.automaticState.failures==0 && f.core.automaticState.manualTotal==1}
        await test("manual success clears automatic failure by verified health"){let f=PolicyFixture();await f.confirm();f.clock.advance(60);f.backend.heal=true;await f.manual();return f.core.automaticState.failures==0 && f.core.manualAttempts==1 && f.core.automaticAttempts==1}
        await test("manual action requires its own risk confirmation"){let f=PolicyFixture();f.core.request(.explicitRepair);await f.core.waitForIdle();return f.backend.off==0 && f.core.reason.contains("尚未确认")}
        await test("manual repair respects user WiFi-off"){let f=PolicyFixture();f.backend.power = .off;await f.manual();return f.backend.off==0 && f.backend.on==0}
        await test("disabling automatic does not erase failures or cooldown"){let f=PolicyFixture();await f.twoFailures();let state=f.core.automaticState;f.core.setAutomatic(false);await f.round(60);return f.backend.off==2 && f.core.automaticState.failures==state.failures && f.core.automaticState.retryAt==state.retryAt}
        await test("policy selection toggle cannot bypass persisted cooling"){let f=PolicyFixture();await f.twoFailures();var s=f.core.settings;s.internetTrial=false;_=f.core.configure(s);f.backend.local = .timeout;await f.round(60);return f.backend.off==2 && f.core.automaticState.failures==2}
        await test("pausing monitoring cannot erase failure history"){let f=PolicyFixture();await f.twoFailures();f.core.setMonitoring(false);await f.round(60);return f.backend.off==2 && f.core.automaticState.failures==2}
        await test("restart preserves failures but total permission defaults off"){let a=PolicyFixture();await a.twoFailures();let b=PolicyFixture(automatic:false,journal:a.journal,clock:a.clock);await b.round();return !b.core.automatic && b.core.automaticState.failures==2 && b.core.cooldownRemaining==1800 && b.backend.off==0}
        await test("restart never reuses partial three-round confirmation"){let a=PolicyFixture();await a.round();await a.round(60);let b=PolicyFixture(journal:a.journal,clock:a.clock);await b.round(60);return b.backend.off==0 && b.core.trialSnapshot.failureRounds==1}
        await test("wallclock forward jump cannot expire cooldown"){let f=PolicyFixture();await f.twoFailures();f.clock.wallNow += 1e7;await f.round();return f.core.cooldownRemaining==1800 && f.backend.off==2}
        await test("wallclock backward jump cannot reset failures"){let f=PolicyFixture();await f.twoFailures();f.clock.wallNow -= 1e7;await f.round(60);return f.core.automaticState.failures==2 && f.core.cooldownRemaining==1740}
        await test("sleep time grants no cooldown credit and clears pending rounds"){let f=PolicyFixture();await f.twoFailures();f.clock.sleep(7200);await f.round();return f.core.cooldownRemaining==1800 && f.backend.off==2 && f.core.trialSnapshot.failureRounds==1}
        await test("new boot grants no elapsed credit"){let a=PolicyFixture();await a.twoFailures();let timer=PolicyClock();timer.bootID="boot-b";let b=PolicyFixture(journal:a.journal,clock:timer);await b.round();return b.core.cooldownRemaining==1800 && b.core.automaticState.failures==2 && b.backend.off==0}
        await test("same-boot clock rollback fails closed without double credit"){let f=PolicyFixture();await f.twoFailures();let old=f.clock.now;f.clock.now -= 100;f.clock.awakeNow -= 100;await f.round();let blocked=f.backend.off==2 && f.core.reason.contains("不可核验");f.clock.now=old;f.clock.awakeNow=old;await f.round();return blocked && f.core.cooldownRemaining==1800}
        await test("sleep before initial fault confirmation resets120second window"){let f=PolicyFixture();await f.round();await f.round(60);f.clock.sleep(3600);await f.round();return f.backend.off==0 && f.core.trialSnapshot.failureRounds==1}
        await test("ON failure requires human recovery and disables future OFF"){let f=PolicyFixture();f.backend.onFails=true;await f.confirm();let before=f.backend.off;await f.manual();return f.backend.on==2 && f.backend.off==before && f.core.needsRestore && f.core.automaticState.manualIntervention && !f.core.automatic}
        await test("permission NSError preserved and no spurious ON"){let f=PolicyFixture();f.backend.permissionError=true;await f.confirm();return f.backend.off==1 && f.backend.on==0 && f.core.repair?.error?.code==77 && !f.core.automatic && f.core.automaticState.manualIntervention}
        await test("pause after app-owned OFF completes ON cleanup"){let f=PolicyFixture();f.backend.onCommand={on in if !on{f.core.setMonitoring(false)}};await f.confirm();return f.backend.off==1 && f.backend.on==1 && !f.core.needsRestore && f.core.automaticState.failures==1}
        await test("grant revocation after OFF completes ON without another OFF"){let f=PolicyFixture();f.backend.onCommand={on in if !on{f.core.setAutomatic(false)}};await f.confirm();await f.round(300);return f.backend.off==1 && f.backend.on==1 && !f.core.automatic}
        await test("persist failure prevents any physical control"){let f=PolicyFixture();f.journal.writable=false;await f.confirm();return f.backend.off==0 && f.core.reason.contains("不可核验")}
        await test("execution-preparation persistence failure prevents OFF after completed confirmation"){let f=PolicyFixture();await f.round();await f.round(60);f.backend.onInspect={f.journal.writable=false};await f.round(60);return f.backend.off==0 && f.core.automaticState.inFlight.isEmpty && f.core.automaticState.automaticTotal==0 && f.core.reason.contains("无法保存执行前")}
        await test("failed result persistence retains failure and blocks another action"){let f=PolicyFixture();f.backend.onCommand={on in if on{f.journal.writable=false}};await f.confirm();let retained=f.core.automaticState.failures==1 && f.core.reason.contains("保存失败");await f.round(180);return retained && f.backend.off==1 && !f.core.availability.eligibleForFreshFault}
        await test("manual failure never increments existing automatic failure"){let f=PolicyFixture();await f.confirm();f.clock.advance(60);await f.manual();return f.core.automaticState.failures==1 && f.core.automaticAttempts==1 && f.core.manualAttempts==1}
        await test("inflight transaction restart enters90awake-second quarantine"){let journal=PolicyJournal();journal.value.prepare(automatic:true);let f=PolicyFixture(journal:journal);await f.round();await f.manual();return f.backend.off==0 && f.core.automaticState.manualIntervention && f.core.automaticState.sharedWait==90 && f.core.automaticState.failures==1}
        await test("quarantine cannot be cleared by early powerON or sleep"){let j=PolicyJournal();j.value.prepare(automatic:true);let f=PolicyFixture(journal:j);await f.healthy();f.clock.sleep(5000);await f.healthy();return f.core.automaticState.manualIntervention && f.core.automaticState.sharedWait==90}
        await test("after interrupted worker deadline verified natural health reconciles safely"){let j=PolicyJournal();j.value.prepare(automatic:true);let f=PolicyFixture(journal:j);await f.round();f.clock.advance(90);await f.healthy();return !f.core.automaticState.manualIntervention && !f.core.needsRestore && f.core.automaticState.failures==0 && f.backend.off==0}
        await test("legacy lock migrates to cooling instead of permanent lock"){var legacy=TrialLatch();legacy.consumed=true;let s=AutomaticState.upgrade(legacy:legacy);return s.failures==2 && s.retryWait==1800 && !s.manualIntervention}
        await test("invalid decoded state is replaced with conservative cooling"){let j=PolicyJournal();j.value.failures=99;let f=PolicyFixture(journal:j);await f.round();return f.core.automaticState.failures==2 && f.core.cooldownRemaining==1800 && f.backend.off==0}
        await test("runtime snapshot is emitted without any application window"){let f=PolicyFixture();await f.twoFailures();let s=f.journal.snapshots.last;return s?.state.failures==2 && s?.automaticSessionAttempts==2 && s?.availability.cooling==true && s?.sample != nil}
        await test("snapshot distinguishes selected policy total grant and eligibility"){let f=PolicyFixture(automatic:false);await f.confirm();let s=f.core.runtimeSnapshot();return s.internetTrialSelected && !s.automaticPermission && !s.availability.eligibleForFreshFault}
        await test("legacy attemptLimit is ignored and never re-encoded"){let data=Data("{\"interval\":90,\"attemptLimit\":1,\"internetTrial\":true}".utf8);let s=try!JSONDecoder().decode(Settings.self,from:data);return s.interval==90 && s.internetTrial && !String(decoding:try!JSONEncoder().encode(s),as:UTF8.self).contains("attemptLimit")}
        print("RESULT \(count-failures)/\(count) policy scenarios; \(failures) failed");exit(failures==0 ? 0:1)
    }
}
