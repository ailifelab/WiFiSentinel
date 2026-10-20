import Foundation
import Darwin
import RecoveryCore

@MainActor final class FixtureRealClock:Clock {
    var now:Double{Monotonic.now}
    func wait(_ seconds:Double) async{try?await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
}
@MainActor final class FixtureRadio:RadioPort {
    let log:URL,mode:String
    var power:Power = .on
    init(log:URL,mode:String){self.log=log;self.mode=mode;if mode=="user-off"{power = .off}}
    func mark(_ text:String){var data=(try?Data(contentsOf:log)) ?? Data();data.append(Data((text+"\n").utf8));try?data.write(to:log,options:.atomic)}
    func readPower(interface:String) async ->Power{
        if mode=="delay-before-off",power == .on{try?await Task.sleep(nanoseconds:1_000_000_000)}
        return power
    }
    func command(on:Bool,interface:String) async ->CommandResult{
        mark(on ? "ON":"OFF");power=on ? .on:.off
        if !on,mode=="broken-pipe"{
            var descriptors:[Int32]=[0,0];guard pipe(&descriptors)==0 else{exit(9)}
            close(descriptors[0]);dup2(descriptors[1],STDOUT_FILENO);close(descriptors[1])
            LocalIPC.emit(["phase":"OFF-ack-with-closed-parent-pipe"])
        }
        return CommandResult(began:true,power:power)
    }
}
@main struct OfflineCycleFixture {
    @MainActor static func main() async{
        let a=CommandLine.arguments;guard a.count==3 else{exit(2)}
        let mode=a[1],log=URL(fileURLWithPath:a[2]);LocalIPC.prepare()
        if mode=="spawn-orphan"{
            let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:a[0]);p.arguments=["broken-pipe",log.path]
            p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
            do{try p.run();try Data(String(p.processIdentifier).utf8).write(to:log.appendingPathExtension("pid"));exit(0)}catch{exit(3)}
        }
        let cancellation=LocalCancellation();cancellation.install()
        let port=FixtureRadio(log:log,mode:mode),clock=FixtureRealClock()
        let r=await PowerCycle.run(port:port,interface:"offline-fixture",permitUntil:clock.now+5,clock:clock,cancelled:{cancellation.cancelled || Task.isCancelled},event:{phase,message in LocalIPC.emit(["phase":phase.rawValue,"message":message])})
        LocalIPC.emit(r);withExtendedLifetime(cancellation){};exit(0)
    }
}
