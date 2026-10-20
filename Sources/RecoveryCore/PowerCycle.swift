import Foundation

public struct CycleResult: Codable,Equatable {
    public var off:CommandResult?,onResults:[CommandResult]=[]
    public var offConfirmed=false,needsRestore=false,finalPower:Power = .unknown
    public var error:Fault?,independentWorker=false
    public init() {}
}
/// No throwing/cancellation exit exists after a possible OFF. All paths converge
/// on finite ON cleanup. Native execution places this routine in a local worker.
@MainActor public enum PowerCycle {
    public static func run(port:RadioPort,interface:String,permitUntil:Double,clock:Clock,
        cancelled:()->Bool = {Task.isCancelled},event:(Phase,String)->Void = {_,_ in}) async -> CycleResult {
        var result=CycleResult()
        guard !cancelled(),clock.now<=permitUntil else {result.error=Fault("WiFiSentinel.Cancelled",1,"执行许可取消或过期；未关闭");return result}
        let before=await port.readPower(interface:interface)
        guard before == .on,!cancelled(),clock.now<=permitUntil else {
            result.finalPower=before;result.off=CommandResult(began:false,power:before,error:Fault("WiFiSentinel.UserPower",1,"执行前关闭／未知或许可取消；不发送开关"));result.error=result.off?.error;return result
        }
        event(.poweringOff,"本地事务：发送关闭命令，单命令6秒期限")
        let off=await port.command(on:false,interface:interface);result.off=off
        result.finalPower=await port.readPower(interface:interface);result.offConfirmed=result.finalPower == .off
        guard off.began else {result.error=off.error ?? Fault("WiFiSentinel",1,"关闭未开始；不打开用户已关闭的无线电");return result}
        result.needsRestore=true
        if result.finalPower == .on && !off.timedOut {
            result.needsRestore=false;result.error=off.error ?? Fault("WiFiSentinel.Verify",3,"系统未确认关闭，不能声称完成关开");return result
        }
        if result.finalPower == .off && !cancelled(){await clock.wait(2)}
        result=await restore(port:port,interface:interface,clock:clock,result:result,event:event)
        return result
    }
    public static func restore(port:RadioPort,interface:String,clock:Clock,result original:CycleResult,
        event:(Phase,String)->Void = {_,_ in}) async -> CycleResult {
        var result=original;result.needsRestore=true
        event(.restoringOn,"本地事务：完成开启清理，最多两次；不再关闭")
        for index in 0..<2 {
            guard port.commandsSettled else {result.error=Fault("WiFiSentinel.Worker",11,"旧命令未确认退出，禁止并发操作；需要手动检查Wi-Fi");return result}
            let on=await port.command(on:true,interface:interface);result.onResults.append(on)
            result.finalPower=await port.readPower(interface:interface)
            if result.finalPower == .on && port.commandsSettled {result.needsRestore=false;break}
            result.error=on.error ?? Fault("WiFiSentinel",2,"重新开启未读回确认")
            event(.restoringOn,"开启第\(index+1)次未确认："+result.error!.description)
            if index==0 {await clock.wait(1)}
        }
        result.error=result.error ?? result.off?.error ?? result.onResults.last?.error
        return result
    }
}
