import Foundation
import Darwin

enum Monotonic {
    static var now:Double {var b=mach_timebase_info_data_t();mach_timebase_info(&b);return Double(mach_continuous_time())*Double(b.numer)/Double(b.denom)/1e9}
}
struct ProcessReply {
    var status:Int32,timedOut:Bool,reaped:Bool,output:Data,error:String
    var launched=false,cancelled=false
}
private final class Capture:@unchecked Sendable {
    let lock=NSLock();var data=Data(),ended=false
    func add(_ d:Data){lock.lock();defer{lock.unlock()};if d.isEmpty{ended=true};data.append(d.prefix(max(0,16384-data.count)))}
    func read()->Data{lock.lock();defer{lock.unlock()};return data}
    var eof:Bool{lock.lock();defer{lock.unlock()};return ended}
}
private final class ProcessCancellation:@unchecked Sendable {
    let lock=NSLock();private var value=false
    func cancel(){lock.lock();value=true;lock.unlock()}
    var cancelled:Bool{lock.lock();defer{lock.unlock()};return value}
}
enum BoundedProcess {
    static func run(_ executable:URL,_ arguments:[String],seconds:Double,environment:[String:String]?=nil,
                    terminationGrace:Double=0.3,cancelWithTERM:Bool=false) async ->ProcessReply {
        let control=ProcessCancellation()
        return await withTaskCancellationHandler(operation:{
            await withCheckedContinuation{continuation in
                DispatchQueue.global(qos:.utility).async{continuation.resume(returning:blocking(executable,arguments,seconds:seconds,environment:environment,terminationGrace:terminationGrace,control:cancelWithTERM ? control:nil))}
            }
        },onCancel:{if cancelWithTERM{control.cancel()}})
    }
    private static func blocking(_ executable:URL,_ arguments:[String],seconds:Double,environment:[String:String]?,
                                 terminationGrace:Double,control:ProcessCancellation?)->ProcessReply {
        guard seconds.isFinite,seconds>0,seconds<=60,terminationGrace.isFinite,(0...36).contains(terminationGrace) else{return ProcessReply(status:-1,timedOut:false,reaped:true,output:Data(),error:"无效期限")}
        guard control?.cancelled != true else{return ProcessReply(status:-1,timedOut:false,reaped:true,output:Data(),error:"启动前取消",cancelled:true)}
        let process=Process(),pipe=Pipe(),errors=Pipe(),capture=Capture(),errorCapture=Capture()
        process.executableURL=executable;process.arguments=arguments;process.environment=environment ?? ProcessInfo.processInfo.environment
        process.standardInput=FileHandle.nullDevice;process.standardOutput=pipe;process.standardError=errors
        pipe.fileHandleForReading.readabilityHandler={capture.add($0.availableData)}
        errors.fileHandleForReading.readabilityHandler={errorCapture.add($0.availableData)}
        defer{pipe.fileHandleForReading.readabilityHandler=nil;errors.fileHandleForReading.readabilityHandler=nil;try?pipe.fileHandleForReading.close();try?errors.fileHandleForReading.close()}
        do{try process.run()}catch{return ProcessReply(status:-1,timedOut:false,reaped:true,output:Data(),error:(error as NSError).domain+" [\((error as NSError).code)]")}
        try?pipe.fileHandleForWriting.close();try?errors.fileHandleForWriting.close()
        let deadline=Monotonic.now+seconds
        while process.isRunning && Monotonic.now<deadline && control?.cancelled != true{usleep(10_000)}
        let cancelled=control?.cancelled == true,timedOut=process.isRunning && !cancelled
        if process.isRunning {
            process.terminate();let grace=Monotonic.now+terminationGrace
            while process.isRunning && Monotonic.now<grace{usleep(10_000)}
            if process.isRunning{Darwin.kill(process.processIdentifier,SIGKILL)}
            let reap=Monotonic.now+0.7
            while process.isRunning && Monotonic.now<reap{usleep(10_000)}
        }
        let drain=Monotonic.now+0.2
        while !process.isRunning && (!capture.eof || !errorCapture.eof) && Monotonic.now<drain{usleep(1_000)}
        return ProcessReply(status:process.isRunning ? -1:process.terminationStatus,timedOut:timedOut,reaped:!process.isRunning,output:capture.read(),error:String(decoding:errorCapture.read().prefix(400),as:UTF8.self),launched:true,cancelled:cancelled)
    }
}
