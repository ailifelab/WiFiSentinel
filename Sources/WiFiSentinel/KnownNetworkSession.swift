import Foundation
import AppKit
import Darwin
import RecoveryCore

/// A compatibility session must not race a production instance at any install
/// location. Keep the legacy pause proof separate from production policy.
enum IsolatedSessionSafety {
    static func anotherInstanceIsRunning(processIDs:[Int32],currentPID:Int32)->Bool {
        processIDs.contains{$0 != currentPID}
    }
    static func allowsLegacyPauseSnapshot(_ raw:Data,anotherInstanceRunning:Bool,now:TimeInterval)->Bool {
        guard raw.count<=32768,let value=(try?JSONSerialization.jsonObject(with:raw)) as? [String:Any],
              value["build"] as? String == "rewrite3",value["monitoring"] as? Bool == false,
              value["busy"] as? Bool == false,value["needsRestore"] as? Bool == false else{return false}
        if !anotherInstanceRunning{return true}
        guard let at=value["generatedWall"] as? Double,at.isFinite,now.isFinite else{return false}
        return now-at>=0 && now-at<120
    }
}

/// This compatibility probe is deliberately separate from production recovery.
/// An already-associated request never qualifies detached-network recovery.
@MainActor final class SingleCurrentNetworkProbe {
    typealias Reader=() throws ->CurrentSavedNetwork
    private let reader:Reader,preflight:(CurrentSavedNetwork)->Bool
    private let runner:([String]) async ->ProcessReply
    private(set) var consumed=false
    init(reader:Reader?=nil,preflight:((CurrentSavedNetwork)->Bool)?=nil,runner:(([String]) async ->ProcessReply)?=nil){
        self.reader=reader ?? {try CurrentSavedNetwork.read()}
        self.preflight=preflight ?? {target in
            Self.allowedCurrent(snapshot:NativeKnownNetworkAdapter.read(target.interface,target.ssid),target:target)
        }
        self.runner=runner ?? {arguments in
            var env=ProcessInfo.processInfo.environment;env["LC_ALL"]="C";env["LANG"]="C"
            return await BoundedProcess.run(URL(fileURLWithPath:"/usr/sbin/networksetup"),arguments,seconds:8,environment:env,cancelWithTERM:true)
        }
    }
    static func allowedCurrent(snapshot:NativeKnownNetworkAdapter.Snapshot,target:CurrentSavedNetwork)->Bool {
        // The test stays on the already-authenticated current saved network.
        // Including legacy Personal/Mixed metadata here does not change the
        // production recovery adapter or the system's encryption settings.
        snapshot.readable && snapshot.power == .on && snapshot.locationAllowed && snapshot.saved &&
        !snapshot.associationRequiresAdmin && snapshot.administrator && snapshot.attachment == .attached &&
        snapshot.activeID == target.networkID && [2,3,4,11,13].contains(target.security)
    }
    func run(target:CurrentSavedNetwork,receipt:URL) async ->ProcessReply {
        func blocked(_ reason:String)->ProcessReply {ProcessReply(status:-1,timedOut:false,reaped:true,output:Data(),error:reason)}
        guard !consumed else{return blocked("单次关联额度已消费，禁止重试")}
        guard !Task.isCancelled,let actual=try?reader(),actual==target,preflight(actual) else{return blocked("当前网络或现有权限不再与授权目标相同，未发送命令")}
        let fd=Darwin.open(receipt.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0 else{return blocked("单次执行标记已存在或不可保存；未发送命令")}
        consumed=true
        let intent=Data("one current-saved-network password-free request; never a recovery qualification\n".utf8)
        let wrote=intent.withUnsafeBytes{Darwin.write(fd,$0.baseAddress,intent.count)}
        let synced=fsync(fd);Darwin.close(fd)
        guard wrote==intent.count,synced==0 else{return blocked("无法持久记录单次请求，未发送命令")}
        return await runner(["-setairportnetwork",target.interface,target.ssid])
    }
}

@MainActor final class KnownNetworkSession:NSObject,NSApplicationDelegate {
    private let directory:URL,location=LocationAccess(),probe=SingleCurrentNetworkProbe()
    private var window:NSWindow!,text:NSTextField!,requestButton:NSButton!,readButton:NSButton!,testButton:NSButton!
    private var target:CurrentSavedNetwork?,report:[String:Any]=[:],busy=false
    private let expires=Date().addingTimeInterval(900)
    init(directory:URL){self.directory=directory;super.init()}
    private var formatter:ISO8601DateFormatter {ISO8601DateFormatter()}
    private func save(_ phase:String,_ message:String){
        report["phase"]=phase;report["message"]=message;report["updatedUTC"]=formatter.string(from:Date())
        report["pid"]=ProcessInfo.processInfo.processIdentifier;report["bundleID"]=Bundle.main.bundleIdentifier ?? ""
        report["locationAuthorizationRaw"]=location.status.rawValue;report["locationRequested"]=location.requested;report["locationGranted"]=location.granted
        report["associationConsumed"]=probe.consumed;report["automaticRecovery"]=false;report["productionStoreUsed"]=false
        if let data=try?JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]){try?data.write(to:directory.appendingPathComponent("SESSION_STATE.json"),options:.atomic)}
        text?.stringValue=message
    }
    func applicationDidFinishLaunching(_ notification:Notification){
        report=["initialLocationAuthorizationRaw":location.status.rawValue,"startedUTC":formatter.string(from:Date()),"expiresUTC":formatter.string(from:expires),"mode":"isolated-current-network-compatibility-only","detachedRecoveryQualified":false]
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:420),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="WiFi 哨兵 · 定位与单次关联验证";window.isReleasedWhenClosed=false
        let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=18;stack.edgeInsets=NSEdgeInsets(top:25,left:25,bottom:25,right:25)
        let title=NSTextField(labelWithString:"仅验证当前已保存网络，不预先断网");title.font = .systemFont(ofSize:21,weight:.semibold);stack.addArrangedSubview(title)
        text=NSTextField(wrappingLabelWithString:"准备标准定位授权…");text.font = .systemFont(ofSize:15);text.isSelectable=true;stack.addArrangedSubview(text)
        requestButton=NSButton(title:"请求定位授权",target:self,action:#selector(requestLocation));requestButton.identifier=NSUserInterfaceItemIdentifier("requestLocation");stack.addArrangedSubview(requestButton)
        readButton=NSButton(title:"读取当前已保存网络",target:self,action:#selector(readCurrent));readButton.identifier=NSUserInterfaceItemIdentifier("readCurrentSavedNetwork");stack.addArrangedSubview(readButton)
        testButton=NSButton(title:"执行一次已授权关联…",target:self,action:#selector(testOnce));testButton.identifier=NSUserInterfaceItemIdentifier("singleCurrentAssociation");testButton.isEnabled=false;stack.addArrangedSubview(testButton)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:"系统定位弹窗请由用户确认。此模式没有自动恢复、定时关开或生产设置写入。已连接时的命令空操作不能证明断线恢复。"))
        let quit=NSButton(title:"关闭验证窗口",target:self,action:#selector(closeSession));stack.addArrangedSubview(quit)
        window.contentView=stack;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        location.onChange={[weak self] in self?.locationChanged()}
        save("permission","正在检查标准定位授权；尚未执行关联")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.7){[weak self] in self?.requestLocation()}
        DispatchQueue.main.asyncAfter(deadline:.now()+900){[weak self] in guard let self,!self.busy else{return};self.testButton.isEnabled=false;self.save("expired","本次授权验证窗口已过期；未再执行请求")}
    }
    @objc private func requestLocation(){guard Date()<expires else{return};location.request(existingAuthorizationOnly:CommandLine.arguments.contains("--existing-location-only"));locationChanged()}
    private func locationChanged(){
        requestButton?.isEnabled = !location.requested && location.status == .notDetermined
        guard !busy,!probe.consumed else{return}
        save(location.granted ? "permission-granted":"permission",location.message)
        if location.granted{readCurrent()}
    }
    @objc private func readCurrent(){
        guard Date()<expires,!busy,!probe.consumed else{return}
        do {
            let current=try CurrentSavedNetwork.read();target=current
            report["selectedCurrentNetwork"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(current))
            testButton.isEnabled=true;save("ready","已通过合法权限读取当前SSID：\(current.ssid)\n已确认属于系统已保存网络，接口\(current.interface)。等待单次关联；未授予断线恢复能力。")
        }catch{target=nil;testButton.isEnabled=false;report["selectionError"]=String(describing:error);save("blocked","无法可靠读取或核对当前实际网络；停止，不从历史列表猜测。\n\(error)")}
    }
    private func oldAppSafelyPaused()->Bool {
        let path=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WiFiSentinel/runtime-snapshot-v3.json")
        guard let raw=try?Data(contentsOf:path) else{return false}
        let processIDs=NSRunningApplication.runningApplications(withBundleIdentifier:"local.WiFiSentinel")
            .filter{!$0.isTerminated}.map(\.processIdentifier)
        let another=IsolatedSessionSafety.anotherInstanceIsRunning(processIDs:processIDs,currentPID:ProcessInfo.processInfo.processIdentifier)
        return IsolatedSessionSafety.allowsLegacyPauseSnapshot(raw,anotherInstanceRunning:another,now:Date().timeIntervalSince1970)
    }
    @objc private func testOnce(){
        guard Date()<expires,!busy,!probe.consumed,let target,oldAppSafelyPaused() else{save("blocked","旧版未确认暂停、当前目标缺失或单次请求不可执行；未发送命令");return}
        let alert=NSAlert();alert.messageText="仅对当前已保存网络关联一次？"
        alert.informativeText="目标：\(target.ssid)。不传密码、不读取钥匙串、不预先断开或关开Wi-Fi，不改变VPN、DNS或路由。可能短暂影响连接；系统授权弹窗需用户确认。已连接时的空操作仅作为兼容性结果，不证明断线恢复。"
        alert.addButton(withTitle:"取消");alert.addButton(withTitle:"按本次授权执行一次")
        guard alert.runModal() == .alertSecondButtonReturn,Date()<expires,oldAppSafelyPaused() else{return}
        busy=true;testButton.isEnabled=false;readButton.isEnabled=false;requestButton.isEnabled=false
        Task{[self] in
            let before=await connectivity(target)
            report["before"]=before
            guard before["healthy"] as? Bool == true,oldAppSafelyPaused() else{busy=false;save("blocked","关联前网络未能核实正常或旧版状态改变；未发送关联命令");return}
            save("associating","即将发送唯一一次无密码关联请求；不会重试")
            let started=formatter.string(from:Date()),reply=await probe.run(target:target,receipt:directory.appendingPathComponent("ASSOCIATION.once"))
            report["command"]=["startedUTC":started,"finishedUTC":formatter.string(from:Date()),"executable":"/usr/sbin/networksetup","arguments":["-setairportnetwork",target.interface,target.ssid],"passwordArgument":false,"status":reply.status,"launched":reply.launched,"timedOut":reply.timedOut,"reaped":reply.reaped,"stdout":String(decoding:reply.output,as:UTF8.self),"stderr":reply.error]
            let after=await connectivity(target);report["after"]=after
            let assessment=NetworksetupJoinReply.assess(reply)
            report["commandAssessment"]=try?JSONSerialization.jsonObject(with:JSONEncoder().encode(assessment))
            let verified=NetworksetupJoinReply.currentNetworkVerified(reply,connectivityVerified:after["healthy"] as? Bool == true)
            report["currentNetworkVerified"]=verified
            report["detachedRecoveryQualified"]=false;report["resultScope"]="Already-associated current-network compatibility only; no pre-disconnection and no recovery qualification"
            let message:String
            if !assessment.commandCompleted {
                report["resultStatus"]="failed"
                message="单次关联请求失败：\(assessment.error?.description ?? "命令结果不可确认")。\n之后网络健康也不追记为本次成功；不再重试。"
            }else if verified {
                report["resultStatus"]="verified-current-network-only"
                message="已核对当前目标关联、本地和双业务响应。\n未预先断网，因此不宣称已验证断线恢复。"
            }else{
                report["resultStatus"]="unverified"
                message="单次命令已结束，但实际目标关联或连通性未全部通过；不计成功。\n未预先断网，因此不宣称已验证断线恢复。"
            }
            busy=false;save("completed",message)
        }
    }
    private func connectivity(_ target:CurrentSavedNetwork) async ->[String:Any] {
        let initial=try?CurrentSavedNetwork.read(),link=NativeHelper.snapshot(expectedSSID:target.ssid)
        var local:Signal = .unknown
        if link.interface==target.interface,link.attachment == .attached,!link.gateway.isEmpty {
            let ping=await BoundedProcess.run(URL(fileURLWithPath:"/sbin/ping"),["-n","-c","1","-s","16","-W","1000","-b",target.interface,link.gateway],seconds:2)
            local=ping.status==0 ? .response:.unknown
        }
        let settings=Settings();var business=[Signal]()
        for url in settings.urls{business.append(await WebPulse.probe(URL(string:url)!))}
        let final=try?CurrentSavedNetwork.read(),after=NativeHelper.snapshot(expectedSSID:target.ssid)
        let exact=initial==target && final==target && link.networkID==target.networkID && after.networkID==target.networkID
        return ["UTC":formatter.string(from:Date()),"SSIDBefore":(initial?.ssid as Any?) ?? NSNull(),"SSIDAfter":(final?.ssid as Any?) ?? NSNull(),"interface":target.interface,"actualTargetMatched":exact,"attachment":after.attachment.rawValue,"power":after.power.rawValue,"local":local.rawValue,"business":business.map(\.rawValue),"healthy":exact && after.attachment == .attached && after.power == .on && local == .response && business==[.response,.response]]
    }
    @objc private func closeSession(){guard !busy else{return};save(probe.consumed ? "completed":"closed","验证窗口关闭；不再发起命令");NSApp.terminate(nil)}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {busy ? .terminateCancel:.terminateNow}
}
