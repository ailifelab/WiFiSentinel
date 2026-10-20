import Foundation
import RecoveryCore

@MainActor final class CycleClock:Clock {
    var now=0.0
    func wait(_ seconds:Double) async{now += seconds;await Task.yield()}
}
@MainActor final class CyclePort:RadioPort {
    var power:Power = .on,offCalls=0,onCalls=0,commandsSettled=true
    var offReply=CommandResult(began:true,power:.off),onReplies:[CommandResult]=[CommandResult(began:true,power:.on)]
    var offEffect:Power? = .off,onEffect:Power? = .on,onOff:(()->Void)?
    func readPower(interface:String) async ->Power{power}
    func command(on:Bool,interface:String) async ->CommandResult{
        if on{onCalls += 1;if let value=onEffect{power=value};return onReplies[min(onCalls-1,onReplies.count-1)]}
        offCalls += 1;onOff?();if let value=offEffect{power=value};return offReply
    }
}
@main struct CycleTests {
    @MainActor static func main() async{
        var count=0,failed=0
        func test(_ name:String,_ body:() async ->Bool) async{count += 1;if await body(){print("PASS \(name)")}else{failed += 1;print("FAIL \(name)")}}
        await test("cancelled permit never issues OFF or ON"){let p=CyclePort(),c=CycleClock();let r=await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c,cancelled:{true});return p.offCalls==0 && p.onCalls==0 && !r.needsRestore}
        await test("expired permit never changes manual power"){let p=CyclePort(),c=CycleClock();c.now=10;_=await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c);return p.offCalls==0 && p.onCalls==0}
        await test("already manually OFF never receives ON"){let p=CyclePort(),c=CycleClock();p.power = .off;_=await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c);return p.offCalls==0 && p.onCalls==0}
        await test("permit expiry after OFF cannot skip cleanup"){let p=CyclePort(),c=CycleClock();let r=await PowerCycle.run(port:p,interface:"fake0",permitUntil:1,clock:c);return c.now>=2 && p.onCalls==1 && !r.needsRestore}
        await test("Task cancellation after OFF still runs ON"){let p=CyclePort(),c=CycleClock();var task:Task<CycleResult,Never>!;p.onOff={task.cancel()};task=Task{await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c)};let r=await task.value;return p.offCalls==1 && p.onCalls==1 && !r.needsRestore}
        await test("cooperative signal after OFF still runs ON"){let p=CyclePort(),c=CycleClock();var cancelled=false;p.onOff={cancelled=true};let r=await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c,cancelled:{cancelled});return p.onCalls==1 && !r.needsRestore}
        await test("OFF timeout with unknown result always attempts cleanup"){let p=CyclePort(),c=CycleClock();p.offReply=CommandResult(began:true,timedOut:true,power:.unknown);p.offEffect = .unknown;let r=await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c);return p.onCalls==1 && !r.needsRestore}
        await test("OFF permission refusal retains original error, no extra ON"){let p=CyclePort(),c=CycleClock();p.offEffect = .on;p.offReply=CommandResult(began:true,power:.on,error:Fault("CWErrorDomain",9,"denied"));let r=await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c);return p.onCalls==0 && r.error?.domain=="CWErrorDomain" && r.error?.code==9}
        await test("already-off response cannot take ownership"){let p=CyclePort(),c=CycleClock();p.offReply=CommandResult(began:false,power:.off);let r=await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c);return p.onCalls==0 && !r.needsRestore}
        await test("two ON failures are finite and each code retained"){let p=CyclePort(),c=CycleClock();p.onEffect = .off;p.onReplies=[CommandResult(began:true,power:.off,error:Fault("CWErrorDomain",10,"first")),CommandResult(began:true,power:.off,error:Fault("CWErrorDomain",11,"second"))];let r=await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c);return p.offCalls==1 && p.onCalls==2 && r.needsRestore && r.onResults.map{$0.error?.code} == [10,11]}
        await test("unsettled command blocks competing control calls"){let p=CyclePort(),c=CycleClock();p.onOff={p.commandsSettled=false};let r=await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c);return p.offCalls==1 && p.onCalls==0 && r.needsRestore}
        await test("cycle reports actual OFF readback independent of Internet"){let p=CyclePort(),c=CycleClock();let r=await PowerCycle.run(port:p,interface:"fake0",permitUntil:5,clock:c);return r.offConfirmed && r.finalPower == .on && !r.needsRestore}
        print("RESULT \(count-failed)/\(count) cycle scenarios; \(failed) failed");exit(failed==0 ? 0:1)
    }
}
