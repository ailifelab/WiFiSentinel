import Foundation
import RecoveryCore

@main struct IPCRecoveryTests {
    static func main() async{
        var count=0,failed=0
        let binary=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("OfflineCycleFixture")
        let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("WiFiSentinel-offline-ipc-\(UUID().uuidString)")
        try!FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        func has(_ file:URL,_ marker:String)->Bool{((try?String(contentsOf:file,encoding:.utf8)) ?? "").split(separator:"\n").contains(Substring(marker))}
        func waitFor(_ file:URL,_ marker:String,_ seconds:Double) async ->Bool{
            let end=Monotonic.now+seconds
            while Monotonic.now<end{if has(file,marker){return true};try?await Task.sleep(nanoseconds:20_000_000)};return has(file,marker)
        }
        func test(_ name:String,_ body:() async ->Bool) async{count += 1;if await body(){print("PASS \(name)")}else{failed += 1;print("FAIL \(name)")}}
        await test("cooperative cancellation before OFF does not turn on user radio"){
            let file=root.appendingPathComponent("pre.log"),task=Task{await BoundedProcess.run(binary,["delay-before-off",root.appendingPathComponent("pre.log").path],seconds:8,terminationGrace:5,cancelWithTERM:true)}
            try?await Task.sleep(nanoseconds:200_000_000);task.cancel();let result=await task.value
            return result.reaped && result.cancelled && !has(file,"OFF") && !has(file,"ON")
        }
        await test("Task cancellation after OFF still completes local ON cleanup"){
            let file=root.appendingPathComponent("cancel.log"),task=Task{await BoundedProcess.run(binary,["normal",root.appendingPathComponent("cancel.log").path],seconds:8,terminationGrace:5,cancelWithTERM:true)}
            guard await waitFor(file,"OFF",2) else{task.cancel();_=await task.value;return false};task.cancel();let result=await task.value
            return result.reaped && result.cancelled && has(file,"ON")
        }
        await test("deadline TERM gives local cleanup grace before kill"){
            let file=root.appendingPathComponent("timeout.log"),start=Monotonic.now
            let result=await BoundedProcess.run(binary,["normal",file.path],seconds:1,terminationGrace:5,cancelWithTERM:true)
            return result.timedOut && result.reaped && has(file,"OFF") && has(file,"ON") && Monotonic.now-start<7
        }
        await test("broken parent output pipe cannot abort ON cleanup"){
            let file=root.appendingPathComponent("pipe.log")
            let result=await BoundedProcess.run(binary,["broken-pipe",file.path],seconds:6,terminationGrace:5,cancelWithTERM:true)
            return result.reaped && result.status==0 && has(file,"OFF") && has(file,"ON")
        }
        await test("launcher exit leaves independent local cleanup running"){
            let file=root.appendingPathComponent("orphan.log")
            let result=await BoundedProcess.run(binary,["spawn-orphan",file.path],seconds:2)
            let restored=await waitFor(file,"ON",6)
            return result.reaped && result.status==0 && restored
        }
        await test("manual radio-off state never receives cleanup ON"){
            let file=root.appendingPathComponent("user.log")
            let result=await BoundedProcess.run(binary,["user-off",file.path],seconds:4,terminationGrace:5,cancelWithTERM:true)
            return result.reaped && result.status==0 && !has(file,"OFF") && !has(file,"ON")
        }
        try?FileManager.default.removeItem(at:root)
        print("RESULT \(count-failed)/\(count) IPC cleanup scenarios; \(failed) failed");exit(failed==0 ? 0:1)
    }
}
