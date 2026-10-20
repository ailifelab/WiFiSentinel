import Foundation
import CoreLocation
import RecoveryCore

@main struct LocationFlowTests {
    @MainActor static func main() async {
        var count=0,failed=0
        func check(_ name:String,_ body:() async ->Bool) async {count += 1;if await body(){print("PASS \(name)")}else{failed += 1;print("FAIL \(name)")}}
        let paused:[String:Any]=["build":"rewrite3","monitoring":false,"busy":false,"needsRestore":false,"generatedWall":1000.0]
        func pauseData(_ changes:[String:Any]=[:])->Data {try!JSONSerialization.data(withJSONObject:paused.merging(changes){_,new in new})}
        await check("isolated session excludes its own process from competing instances"){
            !IsolatedSessionSafety.anotherInstanceIsRunning(processIDs:[42],currentPID:42)
        }
        await check("another bundle instance is detected without a personal installation path"){
            IsolatedSessionSafety.anotherInstanceIsRunning(processIDs:[42,99],currentPID:42)
        }
        await check("fresh paused legacy instance permits isolated preflight"){
            IsolatedSessionSafety.allowsLegacyPauseSnapshot(pauseData(),anotherInstanceRunning:true,now:1119.99)
        }
        await check("no competing instance retains legacy stopped-state behavior"){
            IsolatedSessionSafety.allowsLegacyPauseSnapshot(pauseData(),anotherInstanceRunning:false,now:5000)
        }
        await check("competing instance cannot use pause proof at120seconds"){
            !IsolatedSessionSafety.allowsLegacyPauseSnapshot(pauseData(),anotherInstanceRunning:true,now:1120)
        }
        await check("future pause proof cannot authorize a competing instance"){
            !IsolatedSessionSafety.allowsLegacyPauseSnapshot(pauseData(),anotherInstanceRunning:true,now:999)
        }
        await check("competing instance requires a pause timestamp"){
            var value=paused;value.removeValue(forKey:"generatedWall")
            return !IsolatedSessionSafety.allowsLegacyPauseSnapshot(try!JSONSerialization.data(withJSONObject:value),anotherInstanceRunning:true,now:1001)
        }
        for field in ["monitoring","busy","needsRestore"] {
            await check("unsafe legacy state \(field) blocks isolated preflight"){
                !IsolatedSessionSafety.allowsLegacyPauseSnapshot(pauseData([field:true]),anotherInstanceRunning:false,now:1001)
            }
        }
        await check("a different runtime version cannot supply legacy pause proof"){
            !IsolatedSessionSafety.allowsLegacyPauseSnapshot(pauseData(["build":"rewrite5-exit0"]),anotherInstanceRunning:false,now:1001)
        }
        await check("malformed pause proof fails closed"){
            !IsolatedSessionSafety.allowsLegacyPauseSnapshot(Data("invalid".utf8),anotherInstanceRunning:false,now:1001)
        }
        await check("oversized pause proof fails closed"){
            !IsolatedSessionSafety.allowsLegacyPauseSnapshot(Data(repeating:32,count:32769),anotherInstanceRunning:false,now:1001)
        }
        await check("standard request needs declared purpose and undetermined consent"){LocationAccess.mayRequest(descriptionPresent:true,servicesEnabled:true,status:.notDetermined,requested:false)}
        await check("existing-authorization-only session never repeats permission request even if grant is lost"){!LocationAccess.mayRequest(descriptionPresent:true,servicesEnabled:true,status:.notDetermined,requested:false,existingAuthorizationOnly:true)}
        await check("missing usage description never requests"){!LocationAccess.mayRequest(descriptionPresent:false,servicesEnabled:true,status:.notDetermined,requested:false)}
        await check("global location OFF is not bypassed"){!LocationAccess.mayRequest(descriptionPresent:true,servicesEnabled:false,status:.notDetermined,requested:false)}
        await check("a pending request cannot produce duplicate dialogs"){!LocationAccess.mayRequest(descriptionPresent:true,servicesEnabled:true,status:.notDetermined,requested:true)}
        for status in [CLAuthorizationStatus.denied,.restricted,.authorizedAlways] {
            await check("consent state \(status.rawValue) never causes repeated request"){!LocationAccess.mayRequest(descriptionPresent:true,servicesEnabled:true,status:status,requested:false)}
        }
        let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("WiFiSentinel-location-tests-\(UUID().uuidString)")
        try!FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try?FileManager.default.removeItem(at:root)}
        let target=CurrentSavedNetwork(interface:"fake0",ssid:"fixture-saved",networkID:KnownNetwork.id("fixture-saved"),security:4)
        await check("same current saved target sends one request without password or radio command"){
            var calls=[[String]]();let probe=SingleCurrentNetworkProbe(reader:{target},preflight:{_ in true},runner:{args in calls.append(args);return ProcessReply(status:0,timedOut:false,reaped:true,output:Data("fixture stdout".utf8),error:"fixture stderr",launched:true)})
            let receipt=root.appendingPathComponent(UUID().uuidString),reply=await probe.run(target:target,receipt:receipt)
            _=await probe.run(target:target,receipt:receipt)
            return calls==[["-setairportnetwork","fake0","fixture-saved"]] && probe.consumed && reply.status==0 && String(decoding:reply.output,as:UTF8.self)=="fixture stdout" && reply.error=="fixture stderr"
        }
        await check("current SSID unavailable never guesses from saved history"){
            var calls=0;let probe=SingleCurrentNetworkProbe(reader:{throw Fault("Fixture",1,"SSID unavailable")},preflight:{_ in true},runner:{_ in calls += 1;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
            let reply=await probe.run(target:target,receipt:root.appendingPathComponent(UUID().uuidString));return calls==0 && !reply.launched && !probe.consumed
        }
        for shape in 0..<4 {
            await check("changed actual target \(shape) blocks command"){
                let changed=CurrentSavedNetwork(interface:shape==0 ? "other0":target.interface,ssid:shape==1 ? "other":target.ssid,networkID:shape==2 ? "different":target.networkID,security:shape==3 ? 13:target.security)
                var calls=0;let probe=SingleCurrentNetworkProbe(reader:{changed},preflight:{_ in true},runner:{_ in calls += 1;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
                let reply=await probe.run(target:target,receipt:root.appendingPathComponent(UUID().uuidString));return calls==0 && !reply.launched
            }
        }
        await check("existing policy failure does not launch or request elevation"){
            var calls=0;let probe=SingleCurrentNetworkProbe(reader:{target},preflight:{_ in false},runner:{_ in calls += 1;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
            let reply=await probe.run(target:target,receipt:root.appendingPathComponent(UUID().uuidString));return calls==0 && !reply.launched && !probe.consumed
        }
        for status in [Int32(1),-1] {
            await check("failed or timed-out command \(status) cannot retry"){
                var calls=0;let probe=SingleCurrentNetworkProbe(reader:{target},preflight:{_ in true},runner:{_ in calls += 1;return ProcessReply(status:status,timedOut:status == -1,reaped:true,output:Data(),error:"denied",launched:true)})
                let receipt=root.appendingPathComponent(UUID().uuidString);_=await probe.run(target:target,receipt:receipt);_=await probe.run(target:target,receipt:receipt)
                return calls==1 && probe.consumed
            }
        }
        await check("durable once marker prevents another instance repeating the request"){
            var calls=0;let runner:([String]) async ->ProcessReply={_ in calls += 1;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)}
            let first=SingleCurrentNetworkProbe(reader:{target},preflight:{_ in true},runner:runner),second=SingleCurrentNetworkProbe(reader:{target},preflight:{_ in true},runner:runner),receipt=root.appendingPathComponent(UUID().uuidString)
            _=await first.run(target:target,receipt:receipt);let reply=await second.run(target:target,receipt:receipt)
            return calls==1 && !reply.launched
        }
        await check("symlink receipt refuses command and preserves target"){
            let destination=root.appendingPathComponent("preserve"),receipt=root.appendingPathComponent("link");try!Data("preserve".utf8).write(to:destination);try!FileManager.default.createSymbolicLink(at:receipt,withDestinationURL:destination)
            var calls=0;let probe=SingleCurrentNetworkProbe(reader:{target},preflight:{_ in true},runner:{_ in calls += 1;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
            let reply=await probe.run(target:target,receipt:receipt);return calls==0 && !reply.launched && (try!String(contentsOf:destination,encoding:.utf8))=="preserve"
        }
        for security in [2,3,4,11,13,0,9] {
            await check("current-only compatibility security \(security) preserves policy/identity guards"){
                let target=CurrentSavedNetwork(interface:"fake0",ssid:"fixture-saved",networkID:KnownNetwork.id("fixture-saved"),security:security)
                var snapshot=NativeKnownNetworkAdapter.Snapshot();snapshot.activeID=target.networkID;snapshot.attachment = .attached;snapshot.supportedSecurity=false
                let expected=[2,3,4,11,13].contains(security),allowed=SingleCurrentNetworkProbe.allowedCurrent(snapshot:snapshot,target:target)
                snapshot.activeID="other"
                return allowed==expected && !SingleCurrentNetworkProbe.allowedCurrent(snapshot:snapshot,target:target)
            }
        }

        await check("isolated session rejects real exit0 failure even when post-check is healthy"){
            let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/networksetup-exit0-3900.stdout")
            let bytes=try!Data(contentsOf:fixture)
            var calls=0
            let probe=SingleCurrentNetworkProbe(reader:{target},preflight:{_ in true},runner:{_ in calls += 1;return ProcessReply(status:0,timedOut:false,reaped:true,output:bytes,error:"",launched:true)})
            let receipt=root.appendingPathComponent(UUID().uuidString),reply=await probe.run(target:target,receipt:receipt)
            let second=SingleCurrentNetworkProbe(reader:{target},preflight:{_ in true},runner:{_ in calls += 1;return ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)})
            _=await second.run(target:target,receipt:receipt)
            return NetworksetupJoinReply.assess(reply).state == .failed && !NetworksetupJoinReply.currentNetworkVerified(reply,connectivityVerified:true) && calls==1
        }
        await check("silent exit0 remains unverified until actual target and connectivity pass"){
            let reply=ProcessReply(status:0,timedOut:false,reaped:true,output:Data(),error:"",launched:true)
            return NetworksetupJoinReply.assess(reply).commandCompleted && !NetworksetupJoinReply.currentNetworkVerified(reply,connectivityVerified:false) && NetworksetupJoinReply.currentNetworkVerified(reply,connectivityVerified:true)
        }

        print("RESULT \(count-failed)/\(count) location-flow scenarios; \(failed) failed")
        exit(failed==0 ? 0:1)
    }
}
