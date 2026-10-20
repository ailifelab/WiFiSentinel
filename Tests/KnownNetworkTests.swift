import Foundation
import RecoveryCore

@MainActor private final class JoinClock:Clock {
    var now=0.0,onWait:(()->Void)?
    func wait(_ seconds:Double) async {now += seconds;onWait?();await Task.yield()}
}
@MainActor private final class JoinBackend:Backend {
    let clock:JoinClock
    var power:Power = .on,attachment:Attachment = .attached
    var actualID:String?=KnownNetwork.id("saved-fixture"),local:Signal = .response,internet:[Signal]=[.response,.response]
    var qualified=false,allowed=true,joinHeals=true,detachAfterOn=false,off=0,on=0,joins=0,completions=0
    var commandsSettled=true,inspectAction:(()->Void)?,joinAction:(()->Void)?
    var joinResult=KnownNetworkResult(.completed,began:true,exitCode:0)
    init(_ clock:JoinClock){self.clock=clock}
    func inspect(_ settings:Settings) async ->Sample {
        inspectAction?();await Task.yield()
        return Sample(link:Link(interface:"fake0",identity:"fixture-link",gateway:attachment == .attached ? "192.0.2.1":"",power:power,attachment:attachment,networkID:actualID),local:local,internet:internet,sampledAt:clock.now,boundInterface:"fake0")
    }
    func readPower(interface:String) async ->Power {power}
    func command(on:Bool,interface:String) async ->CommandResult {
        power=on ? .on:.off
        if on{self.on += 1;if detachAfterOn{attachment = .detached;actualID=nil;local = .unknown;internet=[.timeout,.timeout]}}
        else{off += 1}
        return CommandResult(began:true,power:power)
    }
    func knownNetworkStatus(_ settings:Settings,interface:String) async ->KnownNetworkStatus {
        if settings.knownNetworkSSID.isEmpty{return KnownNetworkStatus(.noTarget,"未配置已保存目标")}
        if !allowed{return KnownNetworkStatus(.permissionRequired,"权限不足，不请求授权")}
        return KnownNetworkStatus(qualified ? .ready:.needsValidation,targetID:KnownNetwork.id(settings.knownNetworkSSID),qualified ? "已验证":"尚未单次验证")
    }
    func joinKnownNetwork(_ settings:Settings,interface:String,validation:Bool) async ->KnownNetworkResult {
        guard allowed,power == .on,attachment == .detached,qualified || validation else{return KnownNetworkResult(.blocked)}
        joins += 1;joinAction?()
        if joinResult.commandCompleted,joinHeals {attachment = .attached;actualID=KnownNetwork.id(settings.knownNetworkSSID);local = .response;internet=[.response,.response]}
        if !joinResult.reaped{commandsSettled=false}
        return joinResult
    }
    func completeKnownNetwork(_ settings:Settings,interface:String,verified:Bool) async {completions += 1;qualified=verified}
    func invalidateKnownNetwork(){qualified=false}
}
@MainActor private final class JoinFixture {
    let clock=JoinClock(),backend:JoinBackend,core:Coordinator
    init(target:Bool=true,settings:Settings?=nil){var value=settings ?? Settings();if target{value.knownNetworkSSID="saved-fixture"};backend=JoinBackend(clock);core=Coordinator(settings:value,backend:backend,clock:clock)}
    func round() async {core.request(.timer);await core.waitForIdle()}
    func validate(_ confirmed:Bool=true,detach:Bool=true) async {
        if detach{backend.attachment = .detached;backend.actualID=nil;backend.local = .unknown;backend.internet=[.timeout,.timeout]}
        core.validateKnownNetwork(confirmed:confirmed);await core.waitForIdle()
    }
    func detachedFault() async {backend.attachment = .detached;backend.actualID=nil;backend.local = .unknown;backend.internet=[.timeout,.timeout];core.setAutomatic(true);await round();clock.now += 60;await round();clock.now += 60;await round()}
}
@main struct KnownNetworkTests {
    @MainActor static func main() async {
        var count=0,failed=0
        func check(_ name:String,_ body:() async ->Bool) async {count += 1;if await body(){print("PASS \(name)")}else{failed += 1;print("FAIL \(name)")}}
        await check("legacy settings decode with no saved target"){let value=try!JSONDecoder().decode(Settings.self,from:Data("{}".utf8));return value.knownNetworkSSID.isEmpty && value.validation==nil}
        for name in ["",String(repeating:"x",count:33),"x\ny","x\0y","-looks-like-option"]{
            await check("reject unsafe/ambiguous name bytes \(Array(name.utf8))"){!KnownNetwork.validName(name)}
        }
        await check("exact Unicode byte length accepted"){KnownNetwork.validName(String(repeating:"网",count:10)) && !KnownNetwork.validName(String(repeating:"网",count:11))}
        await check("network digest distinguishes same-looking exact names"){KnownNetwork.id("WiFi") != KnownNetwork.id("wifi") && KnownNetwork.id("e\u{301}") != KnownNetwork.id("é")}
        await check("validation requires explicit user confirmation"){let f=JoinFixture();await f.validate(false);return f.backend.joins==0 && f.backend.off==0}
        await check("no target never guesses a network or cycles an unassociated radio"){let f=JoinFixture(target:false);await f.detachedFault();return f.backend.joins==0 && f.backend.off==0 && f.core.reason.contains("未配置")}
        await check("unvalidated CLI ability is never exercised automatically"){let f=JoinFixture();await f.detachedFault();return f.backend.joins==0 && f.backend.off==0 && f.core.reason.contains("尚未单次验证")}
        await check("missing system permission blocks both join and OFF"){let f=JoinFixture();f.backend.allowed=false;await f.validate();return f.backend.joins==0 && f.backend.off==0 && f.core.reason.contains("权限不足")}
        await check("successful explicit validation qualifies only real target and connectivity"){let f=JoinFixture();await f.validate();return f.backend.qualified && f.backend.joins==1 && f.backend.off==0 && f.backend.on==0 && f.core.repair?.kind == .knownNetworkJoin && f.core.repair?.targetVerified==true && f.core.repair?.outcome == .networkVerified}
        await check("CLI exit0 alone never qualifies a network"){let f=JoinFixture();f.backend.joinHeals=false;f.backend.attachment = .detached;f.backend.actualID=nil;f.backend.local = .unknown;f.backend.internet=[.timeout,.timeout];await f.validate();return !f.backend.qualified && f.core.repair?.internetVerified==false && f.core.repair?.outcome == .radioOnNotAssociated}
        await check("right name but missing LAN never becomes success"){let f=JoinFixture();f.backend.joinAction={f.backend.joinHeals=false;f.backend.attachment = .attached;f.backend.actualID=KnownNetwork.id("saved-fixture");f.backend.local = .timeout;f.backend.internet=[.response,.response]};await f.validate();return !f.backend.qualified && f.core.repair?.internetVerified==false}
        await check("wrong SSID with healthy probes cannot count as target success"){let f=JoinFixture();f.backend.joinHeals=false;f.backend.joinAction={f.backend.attachment = .attached;f.backend.actualID=KnownNetwork.id("other-fixture");f.backend.local = .response;f.backend.internet=[.response,.response]};await f.validate();return f.core.repair?.outcome != .networkVerified && !f.backend.qualified && f.core.reason.contains("其他网络")}
        await check("missing SSID proof with healthy probes is not success"){let f=JoinFixture();f.backend.joinHeals=false;f.backend.joinAction={f.backend.attachment = .attached;f.backend.actualID=nil;f.backend.local = .response;f.backend.internet=[.response,.response]};await f.validate();return f.core.repair?.internetVerified==false && !f.backend.qualified}
        await check("manual WiFi OFF is never powered back ON by join path"){let f=JoinFixture();f.backend.power = .off;await f.validate();return f.backend.joins==0 && f.backend.off==0 && f.backend.on==0}
        await check("user OFF during validation stops without another control"){let f=JoinFixture();f.backend.joinHeals=false;f.backend.joinAction={f.backend.power = .off};await f.validate();return f.backend.joins==1 && f.backend.on==0 && f.core.repair?.internetVerified==false}
        await check("validated detached fault requests association once with no power cycle"){let f=JoinFixture();f.backend.qualified=true;await f.detachedFault();return f.backend.joins==1 && f.backend.off==0 && f.backend.on==0 && f.core.repair?.outcome == .networkVerified && f.core.automaticAttempts==1}
        await check("a fresh process does not inherit CLI qualification"){let f=JoinFixture();await f.validate();let another=JoinFixture(settings:f.core.settings);return !another.backend.qualified && !another.core.automatic}
        await check("changing selected target invalidates qualification"){let f=JoinFixture();await f.validate();var value=f.core.settings;value.knownNetworkSSID="another-saved";_=f.core.configure(value);return !f.backend.qualified && f.core.knownNetworkStatus.state == .needsValidation}
        await check("failed command cannot be credited after concurrent manual health"){let f=JoinFixture();f.backend.joinResult=KnownNetworkResult(.failed,began:true,exitCode:1);await f.validate();return f.core.repair?.outcome != .networkVerified && !f.backend.qualified && f.core.repair?.rejoin?.exitCode==1}
        await check("unreaped join blocks further control and disables automatic"){let f=JoinFixture();f.backend.qualified=true;f.backend.joinResult=KnownNetworkResult(.unconfirmed,began:true,reaped:false,exitCode:-1);await f.detachedFault();let previous=f.backend.joins;f.clock.now += 600;await f.round();return previous==1 && f.backend.joins==1 && f.backend.off==0 && !f.core.automatic && f.core.automaticState.manualIntervention && f.core.repair?.verificationSummary.contains("关联命令")==true}
        await check("pause during verification never upgrades an accepted command to success"){let f=JoinFixture();f.backend.joinAction={f.core.setMonitoring(false)};await f.validate();return f.core.repair?.outcome == .verificationCancelled && !f.backend.qualified}
        await check("a different currently connected network is never switched"){let f=JoinFixture();f.backend.actualID=KnownNetwork.id("other-fixture");await f.validate(detach:false);return f.backend.joins==0 && f.backend.off==0}
        await check("after power cycle detached target gets exactly one fallback join"){var settings=Settings();settings.internetTrial=true;let f=JoinFixture(settings:settings);f.backend.qualified=true;f.backend.detachAfterOn=true;f.backend.internet=[.timeout,.timeout];f.core.setAutomatic(true);for _ in 0..<3{await f.round();f.clock.now += 60};return f.backend.off==1 && f.backend.on==1 && f.backend.joins==1 && f.core.repair?.outcome == .networkVerified && f.core.repair?.targetVerified==true}
        await check("revocation during system-join grace prevents fallback association"){var settings=Settings();settings.internetTrial=true;let f=JoinFixture(settings:settings);f.backend.qualified=true;f.backend.detachAfterOn=true;f.backend.internet=[.timeout,.timeout];f.core.setAutomatic(true);f.clock.onWait={if f.backend.on>0{f.core.setAutomatic(false)}};for _ in 0..<3{await f.round();f.clock.now += 60};return f.backend.off==1 && f.backend.on==1 && f.backend.joins==0}

        await check("already-connected same SSID cannot qualify through a no-op"){
            let f=JoinFixture();await f.validate(detach:false)
            return f.backend.joins==0 && f.backend.off==0 && !f.backend.qualified && f.core.reason.contains("不主动断网")
        }
        // Native adapter contract tests inject both data and process execution.
        // This suite never reads real Wi-Fi metadata or launches networksetup.
        var settings=Settings();settings.knownNetworkSSID="saved-fixture"
        let target=KnownNetwork.id(settings.knownNetworkSSID)
        for shape in 0..<8 {
            await check("native preflight refuses unsafe shape \(shape) without spawn"){
                var s=NativeKnownNetworkAdapter.Snapshot();s.signature="signature";s.activeID=nil
                switch shape {case 0:s.readable=false;case 1:s.power = .off;case 2:s.locationAllowed=false;case 3:s.saved=false;case 4:s.supportedSecurity=false;case 5:s.associationRequiresAdmin=true;case 6:s.administrator=false;default:s.activeID="different"}
                var calls=0;let a=NativeKnownNetworkAdapter(reader:{_,_ in s},runner:{_ in calls += 1;s.activeID=target;s.attachment = .attached;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
                let result=await a.join(settings,interface:"fake0",validation:true);return calls==0 && !result.began && a.status(settings,interface:"fake0").state != .ready
            }
        }
        await check("native never infers qualification from optional password syntax"){
            var calls=0;var s=NativeKnownNetworkAdapter.Snapshot();s.signature="signature";s.activeID=nil
            let a=NativeKnownNetworkAdapter(reader:{_,_ in s},runner:{_ in calls += 1;s.activeID=target;s.attachment = .attached;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
            let r=await a.join(settings,interface:"fake0",validation:false);return calls==0 && !r.began && a.status(settings,interface:"fake0").state == .needsValidation
        }
        await check("native one subprocess carries exact name with no password or shell"){
            var args=[String]();var s=NativeKnownNetworkAdapter.Snapshot();s.signature="signature";s.activeID=nil
            let a=NativeKnownNetworkAdapter(reader:{_,_ in s},runner:{v in args=v;s.activeID=target;s.attachment = .attached;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
            let r=await a.join(settings,interface:"fake0",validation:true);let before=a.status(settings,interface:"fake0").state;a.complete(settings,interface:"fake0",verified:true)
            return r.commandCompleted && args==["-setairportnetwork","fake0","saved-fixture"] && before == .needsValidation && a.status(settings,interface:"fake0").state == .ready
        }
        await check("native success without end-to-end proof locks automatic rejoin"){
            var calls=0;var s=NativeKnownNetworkAdapter.Snapshot();s.signature="signature";s.activeID=nil
            let a=NativeKnownNetworkAdapter(reader:{_,_ in s},runner:{_ in calls += 1;s.activeID=target;s.attachment = .attached;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
            _=await a.join(settings,interface:"fake0",validation:true);a.complete(settings,interface:"fake0",verified:false);for _ in 0..<5{_=await a.join(settings,interface:"fake0",validation:false)}
            return calls==1 && a.status(settings,interface:"fake0").state == .locked
        }
        await check("native command denial never creates repeated authorization attempts"){
            var calls=0;var s=NativeKnownNetworkAdapter.Snapshot();s.signature="signature";s.activeID=nil
            let a=NativeKnownNetworkAdapter(reader:{_,_ in s},runner:{_ in calls += 1;return ProcessReply(status:1,timedOut:false,reaped:true,output:Data("denied".utf8),error:"denied",launched:true)})
            _=await a.join(settings,interface:"fake0",validation:true);for _ in 0..<10{_=await a.join(settings,interface:"fake0",validation:false)}
            return calls==1 && a.status(settings,interface:"fake0").state == .locked
        }
        await check("native profile or OS signature change invalidates a successful proof"){
            var s=NativeKnownNetworkAdapter.Snapshot();s.signature="before";s.activeID=nil
            let a=NativeKnownNetworkAdapter(reader:{_,_ in s},runner:{_ in s.activeID=target;s.attachment = .attached;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
            _=await a.join(settings,interface:"fake0",validation:true);a.complete(settings,interface:"fake0",verified:true);s.signature="after"
            let result=await a.join(settings,interface:"fake0",validation:false)
            return a.status(settings,interface:"fake0").state == .needsValidation && !result.began
        }
        await check("native rechecks permissions immediately before spawn"){
            var reads=0,calls=0;var s=NativeKnownNetworkAdapter.Snapshot();s.signature="signature";s.activeID=nil
            let a=NativeKnownNetworkAdapter(reader:{_,_ in reads += 1;var copy=s;if reads>=2{copy.associationRequiresAdmin=true};return copy},runner:{_ in calls += 1;s.activeID=target;s.attachment = .attached;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
            let r=await a.join(settings,interface:"fake0",validation:true);return calls==0 && !r.began
        }
        await check("native unconfirmed worker prevents concurrent retry even after confirmation"){
            var calls=0;var s=NativeKnownNetworkAdapter.Snapshot();s.signature="signature";s.activeID=nil
            let a=NativeKnownNetworkAdapter(reader:{_,_ in s},runner:{_ in calls += 1;return ProcessReply(status:-1,timedOut:true,reaped:false,output:Data(),error:"",launched:true)})
            _=await a.join(settings,interface:"fake0",validation:true);_=await a.join(settings,interface:"fake0",validation:true);return calls==1 && !a.settled
        }
        await check("native refuses no-op validation on an already-associated target"){
            var calls=0;var snapshot=NativeKnownNetworkAdapter.Snapshot();snapshot.signature="signature";snapshot.activeID=target;snapshot.attachment = .attached
            let adapter=NativeKnownNetworkAdapter(reader:{_,_ in snapshot},runner:{_ in calls += 1;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
            let result=await adapter.join(settings,interface:"fake0",validation:true)
            return calls==0 && !result.began && adapter.status(settings,interface:"fake0").state == .needsValidation
        }

        // Exact captured stdout from the one real 2026-10-17 test. The runner
        // and metadata remain injected: no native Wi-Fi read or command here.
        let fixtureURL=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/networksetup-exit0-3900.stdout")
        let realFailure=try!Data(contentsOf:fixtureURL)
        await check("real exit0 -3900 failure cannot qualify even after external target health"){
            var calls=0;var s=NativeKnownNetworkAdapter.Snapshot();s.signature="signature";s.activeID=nil
            let a=NativeKnownNetworkAdapter(reader:{_,_ in s},runner:{_ in calls += 1;s.activeID=target;s.attachment = .attached;return ProcessReply(status:0,timedOut:false,reaped:true,output:realFailure,error:"",launched:true)})
            let result=await a.join(settings,interface:"fake0",validation:true)
            a.complete(settings,interface:"fake0",verified:true)
            s.activeID=nil;s.attachment = .detached
            for _ in 0..<4{_=await a.join(settings,interface:"fake0",validation:false)}
            return result.state == .failed && result.exitCode==0 && !result.commandCompleted && result.error != nil && calls==1 && a.status(settings,interface:"fake0").state == .locked && !result.error!.description.contains("fixture-saved-network")
        }
        let rejectedReplies:[(String,ProcessReply,KnownNetworkCommandState)]=[
            ("stderr-only explicit failure",ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"Failed to join network fixture. Error: -3900",launched:true),.failed),
            ("unrecognized stdout",ProcessReply(status:0,timedOut:false,reaped:true,output:Data("unexpected response".utf8),error:"",launched:true),.failed),
            ("positive-looking stdout is not documented proof",ProcessReply(status:0,timedOut:false,reaped:true,output:Data("Joined network fixture".utf8),error:"",launched:true),.failed),
            ("localized failure stdout",ProcessReply(status:0,timedOut:false,reaped:true,output:Data("无法加入网络，错误-3900".utf8),error:"",launched:true),.failed),
            ("invalid output encoding",ProcessReply(status:0,timedOut:false,reaped:true,output:Data([0xff,0xfe]),error:"",launched:true),.failed),
            ("nonzero silent exit",ProcessReply(status:7,timedOut:false,reaped:true,output:Data(),error:"",launched:true),.failed),
            ("timeout followed by exit0",ProcessReply(status:0,timedOut:true,reaped:true,output:Data(),error:"",launched:true),.timedOut),
            ("cancelled exit0",ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true,cancelled:true),.failed),
            ("unlaunched exit0",ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:""),.failed),
            ("unreaped exit0",ProcessReply(status:0,timedOut:false,reaped:false,output:Data(),error:"",launched:true),.unconfirmed)
        ]
        for (name,reply,expected) in rejectedReplies {
            await check("native rejects \(name) despite subsequent health"){
                var s=NativeKnownNetworkAdapter.Snapshot();s.signature="signature";s.activeID=nil
                let a=NativeKnownNetworkAdapter(reader:{_,_ in s},runner:{_ in s.activeID=target;s.attachment = .attached;return reply})
                let result=await a.join(settings,interface:"fake0",validation:true);a.complete(settings,interface:"fake0",verified:true)
                return result.state == expected && !result.commandCompleted && a.status(settings,interface:"fake0").state != .ready
            }
        }
        await check("exit0 failure remains a failed repair after immediate and later external recovery"){
            var snapshot=NativeKnownNetworkAdapter.Snapshot();snapshot.signature="signature";snapshot.activeID=nil
            let adapter=NativeKnownNetworkAdapter(reader:{_,_ in snapshot},runner:{_ in ProcessReply(status:0,timedOut:false,reaped:true,output:realFailure,error:"",launched:true)})
            let result=await adapter.join(settings,interface:"fake0",validation:true)
            let f=JoinFixture();f.backend.joinResult=result;f.backend.joinHeals=false
            f.backend.joinAction={f.backend.attachment = .attached;f.backend.actualID=KnownNetwork.id("saved-fixture");f.backend.local = .response;f.backend.internet=[.response,.response]}
            await f.validate();await f.round()
            return result.state == .failed && f.core.repair?.rejoin?.exitCode==0 && f.core.repair?.outcome != .networkVerified && f.core.repair?.internetVerified==false && !f.backend.qualified && f.backend.joins==1
        }

        print("RESULT \(count-failed)/\(count) known-network scenarios; \(failed) failed")
        exit(failed==0 ? 0:1)
    }
}
