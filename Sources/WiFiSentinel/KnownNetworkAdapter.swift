import Foundation
import CoreWLAN
import CoreLocation
import Darwin
import RecoveryCore

/// A silent, clean exit only permits independent network verification. It is
/// never proof of association. networksetup has returned exit0 with an explicit
/// Failed to join / -3900 message on this Mac. Reject all non-whitespace output
/// conservatively, including localized or unknown messages, instead of trying
/// to maintain a success/failure phrase allowlist. Raw names stay out of logs.
enum NetworksetupJoinReply {
    static func assess(_ reply:ProcessReply)->KnownNetworkResult {
        let state:KnownNetworkCommandState,reason:String?
        if !reply.reaped{state = .unconfirmed;reason="关联子进程未确认退出；禁止新控制"}
        else if reply.timedOut{state = .timedOut;reason="关联请求8秒超时；不再重试"}
        else if !reply.launched{state = .failed;reason="关联请求未启动；不取密码、不提权"}
        else if reply.cancelled{state = .failed;reason="关联请求取消；不再重试"}
        else if reply.status != 0{state = .failed;reason="关联命令返回非零状态；自动关联已锁定"}
        else if !String(decoding:reply.output,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !reply.error.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            state = .failed;reason="关联命令有失败或未识别输出；即使退出码为0也按失败处理，不将之后自然健康追记为成功"
        }else{state = .completed;reason=nil}
        return KnownNetworkResult(state,began:reply.launched,reaped:reply.reaped,exitCode:reply.status,
            error:reason.map{Fault("WiFiSentinel.Networksetup",reply.status==0 ? -2:Int(reply.status),$0)})
    }
    static func currentNetworkVerified(_ reply:ProcessReply,connectivityVerified:Bool)->Bool {
        assess(reply).commandCompleted && connectivityVerified
    }
}

/// Finite, non-elevating subprocess; no password argument, Keychain API, scan,
/// privacy request, preferred-network edit, Apple event, or UI automation.
@MainActor final class NativeKnownNetworkAdapter {
    struct Snapshot {
        var readable=true,power:Power = .on,locationAllowed=true,saved=true
        var supportedSecurity=true,associationRequiresAdmin=false,administrator=true
        var activeID:String?,signature="",attachment:Attachment = .detached
    }
    typealias Reader=(String,String)->Snapshot
    private let reader:Reader
    private let runner:([String]) async ->ProcessReply
    private var proof:String?,pending:String?,locked:String?,busy=false
    private(set) var settled=true
    init(reader:Reader?=nil,runner:(([String]) async ->ProcessReply)?=nil) {
        self.reader=reader ?? Self.read
        self.runner=runner ?? {arguments in
            var environment=ProcessInfo.processInfo.environment
            environment["LC_ALL"]="C";environment["LANG"]="C"
            return await BoundedProcess.run(URL(fileURLWithPath:"/usr/sbin/networksetup"),arguments,
                seconds:8,environment:environment,cancelWithTERM:true)
        }
    }
    func invalidate(){proof=nil;pending=nil}
    func status(_ settings:Settings,interface:String)->KnownNetworkStatus {
        let name=settings.knownNetworkSSID
        guard !name.isEmpty else{return KnownNetworkStatus(.noTarget,"未选择已保存网络；未发送关联命令")}
        guard KnownNetwork.validName(name),!interface.isEmpty else{return KnownNetworkStatus(.unavailable,"网络名称或物理接口无效")}
        let id=KnownNetwork.id(name),s=reader(interface,name)
        if !settled || busy{return KnownNetworkStatus(.unavailable,targetID:id,"旧关联命令尚未退出；禁止并发控制")}
        if let block=Self.block(s,id:id){return block}
        if let locked{return KnownNetworkStatus(.locked,targetID:id,locked)}
        if proof != s.signature || s.signature.isEmpty{return KnownNetworkStatus(.needsValidation,targetID:id,"已保存目标可核对；无密码重联尚未完成本次运行的单次验证")}
        return KnownNetworkStatus(.ready,targetID:id,"已通过本次运行的无密码关联和连通验证；每次执行前重新核对现有权限与目标")
    }
    private static func block(_ s:Snapshot,id:String)->KnownNetworkStatus? {
        if !s.readable{return KnownNetworkStatus(.unavailable,targetID:id,"系统网络元数据或管理策略不可读；未发送命令")}
        if s.power != .on{return KnownNetworkStatus(.powerOff,targetID:id,"Wi-Fi 已关闭或不可读；尊重用户操作，不打开无线电")}
        if !s.locationAllowed{return KnownNetworkStatus(.locationUnavailable,targetID:id,"现有定位权限不足，无法核对实际 SSID；本应用不会自动请求权限")}
        if !s.saved{return KnownNetworkStatus(.notSaved,targetID:id,"目标不能与系统已保存网络精确匹配；未发送命令")}
        if !s.supportedSecurity{return KnownNetworkStatus(.unsupportedSecurity,targetID:id,"目标安全类型不在此候选支持范围（WPA2/WPA3个人网络），或保存项有歧义")}
        if s.associationRequiresAdmin || !s.administrator{return KnownNetworkStatus(.permissionRequired,targetID:id,"现有系统策略或账户权限不足；不提权、不触发授权重试")}
        if let current=s.activeID,current != id{return KnownNetworkStatus(.wrongNetwork,targetID:id,"已加入其他网络；不会主动切换到所选目标")}
        return nil
    }
    func join(_ settings:Settings,interface:String,validation:Bool) async ->KnownNetworkResult {
        if validation && settled && !busy{locked=nil;invalidate()}
        let available=status(settings,interface:interface)
        guard !Task.isCancelled,available.state == .ready || (validation && available.state == .needsValidation) else {
            return KnownNetworkResult(.blocked,error:Fault("WiFiSentinel.KnownNetwork",1,Task.isCancelled ? "关联许可取消":available.message))
        }
        // Fresh preflight again immediately before the one allowed subprocess.
        let snapshot=reader(interface,settings.knownNetworkSSID),id=KnownNetwork.id(settings.knownNetworkSSID)
        guard let block=Self.block(snapshot,id:id) else {
            guard snapshot.attachment == .detached,snapshot.activeID == nil else{return KnownNetworkResult(.blocked,error:Fault("WiFiSentinel.KnownNetwork",4,"系统已关联或状态改变；不把空操作当作重联能力验证"))}
            guard validation || proof == snapshot.signature else{return KnownNetworkResult(.blocked,error:Fault("WiFiSentinel.KnownNetwork",2,"系统状态改变，单次验证已失效"))}
            proof=nil;pending=nil;busy=true
            let reply=await runner(["-setairportnetwork",interface,settings.knownNetworkSSID])
            busy=false;settled=reply.reaped
            let result=NetworksetupJoinReply.assess(reply)
            if result.commandCompleted{pending=snapshot.signature}
            else{locked="关联命令失败或权限不足；已锁定自动关联，不重复请求授权。请检查系统后另行确认单次验证。"}
            // Preserve exit status separately from semantic failure. Explicit
            // CLI failure cannot become a pending proof after external healing.
            return result
        }
        return KnownNetworkResult(.blocked,error:Fault("WiFiSentinel.KnownNetwork",3,block.message))
    }
    func complete(_ settings:Settings,interface:String,verified:Bool) {
        let snapshot=reader(interface,settings.knownNetworkSSID)
        if verified,settled,!busy,let pending,pending == snapshot.signature,
           snapshot.activeID == KnownNetwork.id(settings.knownNetworkSSID),Self.block(snapshot,id:KnownNetwork.id(settings.knownNetworkSSID)) == nil {
            proof=pending;locked=nil
        }else{proof=nil;locked="实际目标关联或连通性未验证；自动关联已锁定，需另行确认单次验证"}
        pending=nil
    }
    static func existingLocationAllowed()->Bool {
        guard Bundle.main.object(forInfoDictionaryKey:"NSLocationUsageDescription") is String else{return false}
        let manager=CLLocationManager()
        return manager.authorizationStatus == .authorizedAlways && CLLocationManager.locationServicesEnabled()
    }
    static func read(_ interface:String,_ name:String)->Snapshot {
        var result=Snapshot();result.readable=false
        guard let device=NativeHelper.interface(interface),let configuration=device.configuration() else{return result}
        result.readable=true;result.power=device.powerOn() ? .on:.off
        result.attachment=NativeHelper.snapshot().attachment
        // Only read protected SSID data under an existing declaration/grant.
        // This metadata read never requests or repeats permission.
        result.locationAllowed=Self.existingLocationAllowed()
        let matches=configuration.networkProfiles.array.compactMap{$0 as? CWNetworkProfile}.filter{$0.ssidData == Data(name.utf8)}
        result.saved = !matches.isEmpty
        let security=Set(matches.map{Int($0.security.rawValue)})
        result.supportedSecurity=security.count==1 && security.allSatisfy{[4,11,13].contains($0)}
        result.associationRequiresAdmin=configuration.requireAdministratorForAssociation
        var groups=[gid_t](repeating:0,count:max(1,Int(getgroups(0,nil))))
        let count=getgroups(Int32(groups.count),&groups)
        result.administrator = geteuid()==0 || (count>=0 && (getegid()==80 || groups.prefix(Int(count)).contains(80)))
        if result.locationAllowed,let bytes=device.ssidData(){result.activeID=KnownNetwork.id(bytes)}
        result.signature=KnownNetwork.id([ProcessInfo.processInfo.operatingSystemVersionString,interface,
            KnownNetwork.id(name),security.sorted().map(String.init).joined(separator:","),String(result.associationRequiresAdmin)].joined(separator:"|"))
        return result
    }
}
