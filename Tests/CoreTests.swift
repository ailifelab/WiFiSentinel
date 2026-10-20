import Foundation
import RecoveryCore

@MainActor final class FakeClock: Clock {
    var now=0.0
    var onWait:(()->Void)?
    func wait(_ seconds:Double) async {now += seconds;onWait?();await Task.yield()}
}
@MainActor final class FakeBackend: Backend {
    let clock:FakeClock
    var power:Power = .on,local:Signal = .response,internet:[Signal]=[.response,.response]
    var attachment:Attachment = .attached,identity="link-a",interface="fake0",bound=true,sleeping=false,wired=false,tunnel=true
    var sampleAge=0.0,readLag=0.0,inspectCount=0,offCount=0,onCount=0
    var commandsSettled=true
    var healAfterOn=true,offEffect:Power? = .off,onEffect:Power? = .on
    var offReply=CommandResult(began:true,power:.off)
    var onReply=CommandResult(began:true,power:.on)
    var onInspect:(()->Void)?,onCommand:((Bool)->Void)?
    init(_ clock:FakeClock){self.clock=clock}
    func inspect(_ settings:Settings) async -> Sample {
        inspectCount += 1;onInspect?();await Task.yield()
        return Sample(link:Link(interface:interface,identity:identity,gateway:attachment == .attached ? "192.0.2.1":"",power:power,
            attachment:attachment,sleeping:sleeping,wired:wired,tunnel:tunnel),local:local,internet:internet,
            sampledAt:clock.now-sampleAge,boundInterface:bound ? interface:nil)
    }
    func readPower(interface:String) async -> Power {clock.now += readLag;return power}
    func command(on:Bool,interface:String) async -> CommandResult {
        onCommand?(on);await Task.yield()
        if on {onCount += 1;if let effect=onEffect{power=effect};if healAfterOn && power == .on{local = .response;internet=[.response,.response];attachment = .attached};return onReply}
        offCount += 1;if let effect=offEffect{power=effect};return offReply
    }
}
@MainActor final class Fixture {
    let clock=FakeClock();let backend:FakeBackend;let core:Coordinator
    init(settings:Settings=Settings()){backend=FakeBackend(clock);core=Coordinator(settings:settings,backend:backend,clock:clock)}
    func run(_ trigger:Trigger = .manual) async {core.request(trigger);await core.waitForIdle()}
    func armed() async {await run(.timer);core.setAutomatic(true);backend.local = .timeout;backend.internet=[.timeout,.timeout];await run(.timer);clock.now += 60;await run(.timer);clock.now += 60}
}
@main struct CoreTests {
    @MainActor static func main() async {
        var count=0,failed=0
        func check(_ name:String,_ body:() async -> Bool) async {count += 1;if await body(){print("PASS \(name)")}else{failed += 1;print("FAIL \(name)")}}
        await check("fresh launch never inherits automatic permission"){let f=Fixture();return !f.core.automatic && f.core.attempts==0}
        await check("healthy observation no radio command"){let f=Fixture();await f.run();return f.core.phase == .idle && f.backend.offCount==0}
        await check("unchanged upstream fault does not write per-round logs"){let f=Fixture();f.backend.internet=[.timeout,.timeout];for _ in 0..<10{await f.run()};return f.core.events.count==1 && f.backend.offCount==0}
        await check("fault resolution is logged once"){let f=Fixture();f.backend.internet=[.timeout,.timeout];await f.run();f.backend.internet=[.response,.response];await f.run();await f.run();return f.core.events.count==2 && f.core.events.last?.message.contains("异常结束")==true}
        await check("no two historic HTTP baselines required"){let f=Fixture();await f.armed();await f.run();return f.backend.offCount==1 && f.backend.onCount==1 && f.core.repair?.internetVerified==true}
        await check("timer and manual share identical recovery path"){var result=true;for t in [Trigger.timer,.manual]{let f=Fixture();await f.armed();await f.run(t);result = result && f.backend.offCount==1 && f.core.repair?.trigger==t};return result}
        await check("repeated manual requests coalesce without canceling confirmation"){let f=Fixture();await f.armed();f.backend.onInspect={f.core.request(.manual)};await f.run();return f.backend.offCount==1 && f.core.joinedRequests>=1}
        await check("single site timeout does not recover"){let f=Fixture();await f.armed();f.backend.internet=[.timeout,.response];await f.run();return f.backend.offCount==0}
        await check("WAN only timeout with healthy LAN does not recover"){let f=Fixture();await f.armed();f.backend.local = .response;await f.run();return f.backend.offCount==0 && f.core.reason.contains("本地")}
        await check("unknown LAN never substitutes for failure"){let f=Fixture();await f.armed();f.backend.local = .unknown;await f.run();return f.backend.offCount==0}
        await check("no known local response never assumes ICMP works"){let f=Fixture();f.core.setAutomatic(true);f.backend.local = .timeout;f.backend.internet=[.timeout,.timeout];await f.run();return f.backend.offCount==0 && f.core.reason.contains("尚无")}
        await check("partial internet baseline still permits confirmed local fault"){let f=Fixture();f.backend.internet=[.response,.timeout];await f.run();f.core.setAutomatic(true);f.backend.internet=[.timeout,.timeout];f.backend.local = .timeout;await f.run();f.clock.now += 60;await f.run();f.clock.now += 60;await f.run();return f.backend.offCount==1}
        await check("VPN presence is not a veto"){let f=Fixture();await f.armed();f.backend.tunnel=true;await f.run();return f.backend.offCount==1}
        for shape in 0..<7 {
            await check("protection matrix \(shape)"){let f=Fixture();await f.armed()
                switch shape {case 0:f.backend.sleeping=true;case 1:f.backend.wired=true;case 2:f.backend.power = .off;case 3:f.backend.interface="";case 4:f.backend.bound=false;case 5:f.backend.sampleAge=6;default:f.backend.attachment = .unknown}
                await f.run();return f.backend.offCount==0}
        }
        await check("physical link change discards old local history"){let f=Fixture();await f.armed();f.backend.identity="link-b";await f.run();return f.backend.offCount==0}
        await check("link change during retries cancels eligibility"){let f=Fixture();await f.armed();f.backend.onInspect={f.backend.identity="link-b"};await f.run();return f.backend.offCount==0}
        await check("freshness checked again after power readback"){let f=Fixture();await f.armed();f.backend.readLag=6;await f.run();return f.backend.offCount==0 && f.core.reason.contains("过期")}
        await check("response in a retry clears fault count"){let f=Fixture();await f.armed();f.backend.onInspect={f.backend.local = .response};await f.run();return f.backend.offCount==0 && f.core.failures==0}
        await check("non-timeout internet error cancels recovery"){let f=Fixture();await f.armed();f.backend.internet=[.timeout,.unknown];await f.run();return f.backend.offCount==0}
        await check("monitor-only mode exposes permission reason without arming confirmation"){let f=Fixture();await f.armed();f.core.setAutomatic(false);await f.run();return f.core.failures==0 && f.backend.offCount==0 && f.core.reason.contains("未启用")}
        await check("explicit repair requires separate confirmation"){let f=Fixture();f.core.request(.explicitRepair);await f.core.waitForIdle();return f.backend.offCount==0 && f.core.reason.contains("尚未确认")}
        await check("confirmed single repair can test executor despite healthy LAN"){let f=Fixture();f.core.request(.explicitRepair,repairConfirmed:true);await f.core.waitForIdle();return f.backend.offCount==1 && !f.core.automatic && f.core.repair?.trigger == .explicitRepair}
        await check("explicit repair still respects manual power-off"){let f=Fixture();f.backend.power = .off;f.core.request(.explicitRepair,repairConfirmed:true);await f.core.waitForIdle();return f.backend.offCount==0 && f.backend.onCount==0}
        await check("permission error retains domain and code"){let f=Fixture();await f.armed();f.backend.offEffect = .on;f.backend.offReply=CommandResult(began:true,power:.on,error:Fault("com.apple.wifi",-3900,"not permitted"));await f.run();return f.core.repair?.error?.code == -3900 && f.core.repair?.error?.domain == "com.apple.wifi" && !f.core.automatic && f.backend.onCount==0}
        await check("unconfirmed OFF never claims a completed power cycle"){let f=Fixture();await f.armed();f.backend.offEffect = .on;f.backend.offReply=CommandResult(began:true,power:.on);await f.run();return f.backend.onCount==0 && f.core.repair?.offConfirmed==false && f.core.phase == .attention}
        await check("off timeout that took effect still restores on"){let f=Fixture();await f.armed();f.backend.offReply=CommandResult(began:true,timedOut:true,power:.unknown,error:Fault("Timeout",6,"deadline"));await f.run();return f.backend.onCount==1 && !f.core.needsRestore}
        await check("unknown power after possible off retains restore responsibility"){let f=Fixture();await f.armed();f.backend.offEffect = .unknown;f.backend.offReply=CommandResult(began:true,timedOut:true,power:.unknown);await f.run();return f.backend.onCount==1 && !f.core.needsRestore}
        await check("already-off race does not issue ON"){let f=Fixture();await f.armed();f.backend.offReply=CommandResult(began:false,power:.off,error:Fault("UserPowerOff",1,"off"));await f.run();return f.backend.onCount==0}
        await check("pause after OFF must complete ON"){let f=Fixture();await f.armed();f.backend.onCommand={on in if !on{f.core.setMonitoring(false)}};await f.run();return f.backend.onCount==1 && !f.core.needsRestore}
        await check("normal shutdown after OFF waits for ON cleanup"){let f=Fixture();await f.armed();var quit:Task<Bool,Never>?;f.backend.onCommand={on in if !on{quit=Task{await f.core.shutdown()}}};await f.run();let safe=await quit?.value;return safe==true && f.backend.onCount==1 && !f.core.needsRestore && !f.core.automatic}
        await check("revoking automatic after OFF must complete ON"){let f=Fixture();await f.armed();f.backend.onCommand={on in if !on{f.core.setAutomatic(false)}};await f.run();return f.backend.onCount==1 && !f.core.needsRestore}
        await check("ON failure retries finitely, disables future OFF"){let f=Fixture();await f.armed();f.backend.onEffect = .off;f.backend.onReply=CommandResult(began:true,power:.off,error:Fault("CoreWLAN",5,"denied"));await f.run();let first=f.backend.offCount;f.core.request(.explicitRepair,repairConfirmed:true);await f.core.waitForIdle();return f.backend.onCount==2 && f.backend.offCount==first && f.core.needsRestore && !f.core.automatic}
        await check("user resolving power-on permits safe quit"){let f=Fixture();await f.armed();f.backend.onEffect = .off;await f.run();f.backend.power = .on;return await f.core.shutdown() && !f.core.needsRestore}
        await check("unsettled worker blocks any new control without claiming an owned OFF"){let f=Fixture();await f.armed();f.backend.commandsSettled=false;await f.run();let quit=await f.core.shutdown();return !f.core.needsRestore && quit && f.backend.offCount==0}
        await check("cancelled quit permits read-only reconciliation"){let f=Fixture();await f.armed();f.backend.onEffect = .off;await f.run();_=await f.core.shutdown();f.core.cancelShutdown();f.core.setMonitoring(true);f.backend.power = .on;f.backend.local = .response;f.backend.internet=[.response,.response];await f.run();return !f.core.needsRestore && !f.core.automatic}
        await check("power ON alone is never recovery success"){let f=Fixture();await f.armed();f.backend.healAfterOn=false;await f.run();return f.core.phase == .attention && f.core.repair?.internetVerified==false && !f.core.needsRestore}
        await check("post ON verification is time-bounded"){let f=Fixture();await f.armed();f.backend.healAfterOn=false;let before=f.clock.now;await f.run();return f.clock.now-before<=40}
        await check("cooldown prevents repeated OFF"){let f=Fixture();await f.armed();await f.run();f.backend.local = .timeout;f.backend.internet=[.timeout,.timeout];await f.run();return f.backend.offCount==1 && f.core.reason.contains("串行间隔")}
        await check("successful recovery allows later newly confirmed fault"){let f=Fixture();await f.armed();await f.run();f.clock.now += 60;await f.run();f.backend.local = .timeout;f.backend.internet=[.timeout,.timeout];await f.run();f.clock.now += 60;await f.run();f.clock.now += 60;await f.run();return f.backend.offCount==2 && f.core.automaticAttempts==2}
        await check("stale local history does not authorize fault inference"){let f=Fixture();await f.armed();f.clock.now=601;await f.run();return f.backend.offCount==0 && f.core.reason.contains("尚无")}
        await check("unknown association does not auto power cycle"){let f=Fixture();f.core.setAutomatic(true);f.backend.attachment = .unknown;await f.run();return f.backend.offCount==0}
        await check("detached without saved target blocks useless radio cycling"){let f=Fixture();f.core.setAutomatic(true);f.backend.attachment = .detached;f.backend.local = .unknown;for time in [0.0,60,120]{f.clock.now=time;await f.run()};return f.backend.offCount==0 && f.core.reason.contains("重联未执行")}
        await check("manual spam cannot manufacture detached wait"){let f=Fixture();f.core.setAutomatic(true);f.backend.attachment = .detached;for _ in 0..<20{await f.run()};f.clock.now=120;await f.run();return f.backend.offCount==0}
        await check("sleep interrupts detached grace"){let f=Fixture();f.core.setAutomatic(true);f.backend.attachment = .detached;await f.run();f.clock.now=60;f.backend.sleeping=true;await f.run();f.clock.now=120;f.backend.sleeping=false;await f.run();return f.backend.offCount==0}
        await check("long observation gap restarts detached grace"){let f=Fixture();f.core.setAutomatic(true);f.backend.attachment = .detached;await f.run();f.clock.now=60;await f.run();f.clock.now=500;await f.run();return f.backend.offCount==0}
        await check("configuration changes do not inherit old local proof"){let f=Fixture();await f.armed();var s=f.core.settings;s.customURL="https://example.org/";_=f.core.configure(s);await f.run();return f.backend.offCount==0}
        await check("grants are never encoded into settings"){let f=Fixture();f.core.setAutomatic(true);let data=try!JSONEncoder().encode(f.core.settings);return !String(decoding:data,as:UTF8.self).contains("automatic")}
        await check("invalid URL credentials are rejected"){var s=Settings();s.customURL="https://user:secret@example.org/";return s.validation != nil}
        await check("duplicate independent target is rejected"){var s=Settings();s.customURL="https://www.cloudflare.com/";return s.validation != nil}
        await check("pause before retry never executes OFF"){let f=Fixture();await f.armed();f.backend.onInspect={f.core.setMonitoring(false)};await f.run();return f.backend.offCount==0}
        await check("shutdown leaves no pending transaction"){let f=Fixture();await f.armed();let okay=await f.core.shutdown();f.core.request(.manual);await f.core.waitForIdle();return okay && !f.core.busy && f.backend.offCount==0}
        await check("ON without association is explicit recovery failure"){let f=Fixture();await f.armed();f.backend.healAfterOn=false;f.backend.onCommand={on in if on{f.backend.attachment = .detached}};await f.run(.timer);return f.core.repair?.outcome == .radioOnNotAssociated && f.core.repair?.lastVerificationAttachment == .detached && f.core.repair?.internetVerified==false && f.core.automaticState.failures==1 && f.core.reason.contains("尚未重新关联")}
        await check("attached but failed probes remain networkUnverified"){let f=Fixture();await f.armed();f.backend.healAfterOn=false;await f.run();return f.core.repair?.outcome == .networkUnverified && f.core.repair?.lastVerificationAttachment == .attached && f.core.repair?.internetVerified==false}
        await check("later manual or system health does not rewrite failed repair as success"){let f=Fixture();await f.armed();f.backend.healAfterOn=false;f.backend.onCommand={on in if on{f.backend.attachment = .detached}};await f.run();f.clock.now += 60;f.backend.attachment = .attached;f.backend.local = .response;f.backend.internet=[.response,.response];await f.run();return f.core.automaticState.failures==0 && f.core.repair?.outcome == .radioOnNotAssociated && f.core.repair?.internetVerified==false && f.core.events.last?.message.contains("不追记")==true}
        await check("verified real probes produce networkVerified outcome"){let f=Fixture();await f.armed();await f.run();return f.core.repair?.outcome == .networkVerified && f.core.repair?.lastVerificationAttachment == .attached}
        await check("cancel afterOFF keeps separate verificationCancelled outcome"){let f=Fixture();await f.armed();f.backend.onCommand={on in if !on{f.core.setMonitoring(false)}};await f.run();return f.core.repair?.outcome == .verificationCancelled && f.backend.onCount==1 && !f.core.needsRestore}
        await check("third round just short of120waits tiny remainder and obtains new evidence"){var s=Settings();s.internetTrial=true;let f=Fixture(settings:s);f.core.setAutomatic(true);f.backend.internet=[.timeout,.timeout];await f.run(.timer);f.clock.now=59.97;await f.run(.timer);f.clock.now=119.94;var offAt=0.0;f.backend.onCommand={on in if !on{offAt=f.clock.now}};await f.run(.timer);return f.backend.offCount==1 && offAt>=120 && offAt<121 && f.backend.inspectCount>=5}
        await check("revocation during tiny120remainder preventsOFF"){var s=Settings();s.internetTrial=true;let f=Fixture(settings:s);f.core.setAutomatic(true);f.backend.internet=[.timeout,.timeout];await f.run(.timer);f.clock.now=60;await f.run(.timer);f.clock.now=119.99;f.clock.onWait={f.core.setAutomatic(false)};await f.run(.timer);return f.backend.offCount==0 && !f.core.automatic}
        await check("healthy fresh evidence after tiny remainder cancels action"){var s=Settings();s.internetTrial=true;let f=Fixture(settings:s);f.core.setAutomatic(true);f.backend.internet=[.timeout,.timeout];await f.run(.timer);f.clock.now=60;await f.run(.timer);f.clock.now=119.99;f.clock.onWait={f.backend.internet=[.response,.response]};await f.run(.timer);return f.backend.offCount==0 && f.core.failures==0}
        print("RESULT \(count-failed)/\(count) core scenarios; \(failed) failed")
        exit(failed==0 ? 0:1)
    }
}
