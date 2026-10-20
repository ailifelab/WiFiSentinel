import Foundation
import CoreWLAN
import SystemConfiguration
import CryptoKit
import Darwin
import RecoveryCore

@MainActor final class RealClock: Clock {
    var now: Double {Monotonic.now}
    var wallNow:Double {Date().timeIntervalSince1970}
    var awakeNow:Double {var t=mach_timebase_info_data_t();mach_timebase_info(&t);return Double(mach_absolute_time())*Double(t.numer)/Double(t.denom)/1e9}
    var bootID:String {
        var length=0
        guard sysctlbyname("kern.bootsessionuuid",nil,&length,nil,0)==0,length>0,length<=128 else{return ""}
        var data=[CChar](repeating:0,count:length)
        guard sysctlbyname("kern.bootsessionuuid",&data,&length,nil,0)==0 else{return ""}
        return String(cString:data)
    }
    func wait(_ seconds: Double) async {try?await Task.sleep(nanoseconds:UInt64(max(0,seconds)*1e9))}
}
struct CycleEnvelope:Codable {
    var phase:Phase?,message:String?,result:CycleResult?
}
@MainActor class NativeRadioPort:RadioPort {
    let binary=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
    var unsafeWorker=false
    var commandsSettled:Bool {!unsafeWorker}
    var expectedIdentity=""
    func readPower(interface: String) async -> Power {
        let reply=await BoundedProcess.run(binary,["--power",interface],seconds:3)
        guard reply.reaped,!reply.timedOut,let value=try?JSONDecoder().decode(Power.self,from:reply.output) else {return .unknown}
        return value
    }
    func command(on: Bool,interface: String) async -> CommandResult {
        guard !unsafeWorker else {return CommandResult(began:false,power:.unknown,error:Fault("WiFiSentinel.Worker",11,"旧命令进程未确认退出，禁止并发新命令"))}
        let nonce=UUID().uuidString
        var env=ProcessInfo.processInfo.environment;env["WIFISENTINEL_REPAIR_GRANT"]=nonce
        let reply=await BoundedProcess.run(binary,["--radio",on ? "on":"off",interface,nonce,expectedIdentity],seconds:6,environment:env)
        unsafeWorker = !reply.reaped
        let lines=String(decoding:reply.output,as:UTF8.self).split(separator:"\n")
        if let last=lines.last,let result=try?JSONDecoder().decode(CommandResult.self,from:Data(last.utf8)),!reply.timedOut {return result}
        let began=lines.contains{$0.contains("\"began\":true") || $0.contains("\"began\" : true")} || reply.timedOut || (reply.status>=0 && reply.output.isEmpty)
        return CommandResult(began:began,timedOut:reply.timedOut,power:.unknown,
            error:Fault("WiFiSentinel.Worker",reply.reaped ? 10:11,reply.reaped ? "系统命令超时／未返回；保留重新开启责任":"命令进程未确认结束；请手动检查 Wi-Fi"))
    }
}
@MainActor final class NativeBackend:NativeRadioPort,Backend {
    private let knownNetworks=NativeKnownNetworkAdapter()
    override var commandsSettled:Bool {super.commandsSettled && knownNetworks.settled}
    func knownNetworkStatus(_ settings:Settings,interface:String) async ->KnownNetworkStatus {knownNetworks.status(settings,interface:interface)}
    func joinKnownNetwork(_ settings:Settings,interface:String,validation:Bool) async ->KnownNetworkResult {await knownNetworks.join(settings,interface:interface,validation:validation)}
    func completeKnownNetwork(_ settings:Settings,interface:String,verified:Bool) async {knownNetworks.complete(settings,interface:interface,verified:verified)}
    func invalidateKnownNetwork(){knownNetworks.invalidate()}

    func inspect(_ settings:Settings) async ->Sample {
        let reply=await BoundedProcess.run(binary,["--sample",String(settings.localTCPPort)]+settings.urls+(settings.knownNetworkSSID.isEmpty ? []:[settings.knownNetworkSSID]),seconds:9)
        if reply.reaped,!reply.timedOut,let result=try?JSONDecoder().decode(Sample.self,from:reply.output){expectedIdentity=result.link.identity;return result}
        return Sample(link:Link(),local:.unknown,internet:[.unknown,.unknown],sampledAt:Monotonic.now,reason:"本地探测进程未返回有效结果；不把未知当成故障")
    }
    func cycle(interface:String,identity:String,permitUntil:Double,clock:Clock,event:@escaping(Phase,String)->Void) async ->CycleResult {
        var failure=CycleResult();failure.independentWorker=true
        guard !Task.isCancelled else{failure.error=Fault("WiFiSentinel.Cancelled",1,"启动前取消");return failure}
        let nonce=UUID().uuidString;var env=ProcessInfo.processInfo.environment;env["WIFISENTINEL_REPAIR_GRANT"]=nonce
        let reply=await BoundedProcess.run(binary,["--cycle",interface,nonce,identity,String(permitUntil)],seconds:45,environment:env,terminationGrace:36,cancelWithTERM:true)
        let messages=reply.output.split(separator:10).compactMap{try?JSONDecoder().decode(CycleEnvelope.self,from:Data($0))}
        for item in messages{if let phase=item.phase,let message=item.message{event(phase,message)}}
        if reply.reaped,let result=messages.compactMap(\.result).last {unsafeWorker=false;return result}
        // No final result means child ownership is uncertain. Never guess that a
        // user-off state belongs to us, and never start competing ON/OFF calls.
        unsafeWorker=reply.launched;failure.needsRestore=reply.launched
        failure.error=Fault("WiFiSentinel.CycleWorker",reply.reaped ? 20:21,"本地事务未给出最终清理结果；停止控制，请在系统菜单检查Wi-Fi")
        return failure
    }
}

enum NativeHelper {
    static func emit<T:Encodable>(_ value:T){LocalIPC.emit(value)}
    static func interface(_ name: String? = nil)->CWInterface? {
        let client=CWWiFiClient.shared();guard let names=client.interfaceNames(),names.count==1,let actual=names.first,
              name==nil || name==actual else{return nil}
        return client.interface(withName:actual)
    }
    static func power(_ name: String)->Power {interface(name).map{$0.powerOn() ? .on:.off} ?? .unknown}
    @MainActor static func runIfRequested() async -> Bool {
        LocalIPC.prepare()
        let a=CommandLine.arguments
        guard a.count>1 else{return false}
        switch a[1] {
        case "--cycle":
            guard a.count==6,ProcessInfo.processInfo.environment["WIFISENTINEL_REPAIR_GRANT"]==a[3],a[3].count==36,
                  let until=Double(a[5]),until.isFinite,parentMatchesSelf() else {
                var failed=CycleResult();failed.error=Fault("WiFiSentinel.Grant",1,"缺少本次事务许可");emit(CycleEnvelope(result:failed));return true
            }
            let cancellation=LocalCancellation();cancellation.install()
            let port=NativeRadioPort();port.expectedIdentity=a[4]
            var result=await PowerCycle.run(port:port,interface:a[2],permitUntil:until,clock:RealClock(),cancelled:{cancellation.cancelled || Task.isCancelled},event:{phase,message in emit(CycleEnvelope(phase:phase,message:message))})
            result.independentWorker=true;emit(CycleEnvelope(result:result));withExtendedLifetime(cancellation){};return true
        case "--power":if a.count==3 {emit(power(a[2]))};return true
        case "--sample":
            guard (a.count==5 || a.count==6),a.count != 6 || KnownNetwork.validName(a[5]),let port=Int(a[2]),(0...65535).contains(port),Settings.validURL(a[3]),Settings.validURL(a[4]) else{return true}
            let selected=a.count==6 ? a[5]:""
            let link=snapshot(expectedSSID:selected)
            var internet:[Signal]=[]
            for url in a[3...4] {internet.append(await WebPulse.probe(URL(string:url)!))}
            var local:Signal = .unknown;var binding:String?
            if link.attachment == .attached,!link.gateway.isEmpty {
                if port==0 {
                    let ping=await BoundedProcess.run(URL(fileURLWithPath:"/sbin/ping"),["-n","-c","1","-s","16","-W","1000","-b",link.interface,link.gateway],seconds:2)
                    local=ping.status==0 ? .response:(ping.timedOut || ping.status==2 ? .timeout:.unknown)
                    if ping.error.lowercased().contains("permitted") || ping.error.lowercased().contains("permission") {local = .unknown}
                    if local != .unknown {binding=link.interface}
                } else {
                    local=localTCP(link.gateway,interface:link.interface,port:port);if local != .unknown {binding=link.interface}
                }
            }
            let after=snapshot(expectedSSID:selected)
            if after.identity != link.identity || after.power != link.power || after.attachment != link.attachment || after.networkID != link.networkID {
                emit(Sample(link:after,local:.unknown,internet:internet,sampledAt:Monotonic.now,reason:"检测期间物理链路变化"))
            } else {emit(Sample(link:link,local:local,internet:internet,sampledAt:Monotonic.now,boundInterface:binding,
                               reason:local == .unknown ? "本地通路证据未知；未读取网络名称或密码":""))}
            return true
        case "--radio":
            guard a.count==6,["on","off"].contains(a[2]),ProcessInfo.processInfo.environment["WIFISENTINEL_REPAIR_GRANT"]==a[4],
                  a[4].count==36,parentMatchesSelf() else {emit(CommandResult(began:false,power:.unknown,error:Fault("WiFiSentinel.Grant",1,"缺少本次应用执行许可")));return true}
            guard let device=interface(a[3]) else {emit(CommandResult(began:false,power:.unknown,error:Fault("CoreWLAN",-1,"唯一物理无线接口不可读")));return true}
            let on=a[2]=="on"
            if !on && snapshot().identity != a[5] {emit(CommandResult(began:false,power:power(a[3]),error:Fault("WiFiSentinel.LinkChanged",1,"执行前物理链路已变化；取消关闭")));return true}
            if !on && !device.powerOn() {emit(CommandResult(began:false,power:.off,error:Fault("WiFiSentinel.UserPowerOff",1,"用户已关闭 Wi-Fi；不会主动打开")));return true}
            emit(CommandResult(began:true,power:device.powerOn() ? .on:.off))
            do {try device.setPower(on);emit(CommandResult(began:true,power:device.powerOn() ? .on:.off))}
            catch {let e=error as NSError;emit(CommandResult(began:true,power:device.powerOn() ? .on:.off,error:Fault(e.domain,e.code,e.localizedDescription)))}
            return true
        default:return false
        }
    }
    private static func parentMatchesSelf()->Bool {
        var buffer=[CChar](repeating:0,count:4096)
        guard proc_pidpath(getppid(),&buffer,UInt32(buffer.count))>0 else{return false}
        return URL(fileURLWithPath:String(cString:buffer)).standardizedFileURL == URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
    }
    @MainActor static func snapshot(expectedSSID:String="")->Link {
        guard let device=interface(),let name=device.interfaceName else{return Link()}
        let store=SCDynamicStoreCreate(nil,"WiFiSentinel-Rewrite" as CFString,nil,nil)
        guard let store,let values=SCDynamicStoreCopyMultiple(store,
            ["State:/Network/Interface/\(name)/Link","State:/Network/Interface/\(name)/IPv4","State:/Network/Interface/\(name)/IPv6"] as CFArray,
            ["State:/Network/Service/.*/IPv4"] as CFArray) as? [String:Any] else {return Link(interface:name,power:device.powerOn() ? .on:.off)}
        let link=values["State:/Network/Interface/\(name)/Link"] as? [String:Any]
        let ip=values["State:/Network/Interface/\(name)/IPv4"] as? [String:Any]
        let v6=values["State:/Network/Interface/\(name)/IPv6"] as? [String:Any]
        let addresses=(ip?["Addresses"] as? [String] ?? [])+(v6?["Addresses"] as? [String] ?? [])
        let routes=values.compactMap{key,value->String? in
            guard key.hasPrefix("State:/Network/Service/"),let v=value as? [String:Any],v["InterfaceName"] as? String==name,
                  let router=v["Router"] as? String,numeric(router) else{return nil};return router
        }
        let routers=Set(routes);let gateway=routers.count==1 ? routers.first!:""
        let active=link?["Active"] as? Bool
        let attachment=classify(active:active,addresses:addresses,gateway:gateway)
        let identity=SHA256.hash(data:Data(([name,gateway]+addresses.sorted()).joined(separator:"|").utf8)).map{String(format:"%02x",$0)}.joined()
        let interfaces=SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let wired=interfaces.contains{item in
            guard SCNetworkInterfaceGetInterfaceType(item) as String? == kSCNetworkInterfaceTypeEthernet as String,
                  let bsd=SCNetworkInterfaceGetBSDName(item) as String?,bsd != name,
                  let value=SCDynamicStoreCopyValue(store,"State:/Network/Interface/\(bsd)/Link" as CFString) as? [String:Any],
                  value["Active"] as? Bool == true else{return false}
            return true
        }
        var list:UnsafeMutablePointer<ifaddrs>?
        var tunnel=false
        if getifaddrs(&list)==0 {var cursor=list;while let entry=cursor {if let n=entry.pointee.ifa_name,String(cString:n).hasPrefix("utun"),entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 {tunnel=true};cursor=entry.pointee.ifa_next};freeifaddrs(list)}
        var networkID:String?
        if !expectedSSID.isEmpty,NativeKnownNetworkAdapter.existingLocationAllowed(),let bytes=device.ssidData(){networkID=KnownNetwork.id(bytes)}
        return Link(interface:name,identity:identity,gateway:gateway,power:device.powerOn() ? .on:.off,attachment:attachment,wired:wired,tunnel:tunnel,networkID:networkID)
    }
    static func numeric(_ text: String)->Bool {var v4=in_addr(),v6=in6_addr();return inet_pton(AF_INET,text,&v4)==1 || inet_pton(AF_INET6,text,&v6)==1}
    static func classify(active:Bool?,addresses:[String],gateway:String)->Attachment {
        if active==false && addresses.isEmpty{return .detached}
        if active==true && !addresses.isEmpty && !gateway.isEmpty{return .attached}
        return active==true ? .configuring:.unknown
    }
    static func localTCP(_ address: String,interface: String,port: Int)->Signal {
        guard numeric(address),let indexValue=interface.withCString({if_nametoindex($0)}) as UInt32?,indexValue != 0 else{return .unknown}
        let v6=address.contains(":"),fd=socket(v6 ? AF_INET6:AF_INET,SOCK_STREAM,IPPROTO_TCP)
        guard fd>=0 else{return .unknown};defer{close(fd)}
        var index=indexValue
        guard fcntl(fd,F_SETFL,O_NONBLOCK)==0,setsockopt(fd,v6 ? IPPROTO_IPV6:IPPROTO_IP,v6 ? IPV6_BOUND_IF:IP_BOUND_IF,&index,socklen_t(MemoryLayout<UInt32>.size))==0 else{return .unknown}
        let result:Int32
        if v6 {
            var a=sockaddr_in6();a.sin6_len=UInt8(MemoryLayout<sockaddr_in6>.size);a.sin6_family=sa_family_t(AF_INET6);a.sin6_port=UInt16(port).bigEndian
            if address.hasPrefix("fe80:"){a.sin6_scope_id=index};guard inet_pton(AF_INET6,address,&a.sin6_addr)==1 else{return .unknown}
            result=withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in6>.size))}}
        } else {
            var a=sockaddr_in();a.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);a.sin_family=sa_family_t(AF_INET);a.sin_port=UInt16(port).bigEndian
            guard inet_pton(AF_INET,address,&a.sin_addr)==1 else{return .unknown}
            result=withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        }
        if result==0 || errno==ECONNREFUSED{return .response}
        guard errno==EINPROGRESS else{return .unknown}
        var pollfd=pollfd(fd:fd,events:Int16(POLLOUT),revents:0)
        let ready=poll(&pollfd,1,2000);if ready==0{return .timeout};guard ready>0 else{return .unknown}
        var error:Int32=0,length=socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length)==0 else{return .unknown}
        return error==0 || error==ECONNREFUSED ? .response:error==ETIMEDOUT ? .timeout:.unknown
    }
}
