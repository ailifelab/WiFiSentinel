import AppKit
import Foundation
import Combine
import RecoveryCore

@MainActor final class PreviewClock:Clock {
    private let base=Monotonic.now,wall=Date().timeIntervalSince1970
    private var elapsed=0.0
    var now:Double{base+elapsed};var awakeNow:Double{now};var wallNow:Double{wall+elapsed};var bootID:String{"offline-preview"}
    func advance(_ seconds:Double){elapsed += seconds}
    func wait(_ seconds:Double) async{advance(seconds);await Task.yield()}
}
@MainActor final class PreviewBackend: Backend {
    let clock:Clock,scenario:String
    private var fakePower:Power = .on
    init(_ clock:Clock,scenario:String=""){self.clock=clock;self.scenario=scenario}
    func inspect(_ settings:Settings) async -> Sample {Sample(link:Link(interface:"preview0",identity:"preview",gateway:"",power:scenario=="human" ? .unknown:fakePower,attachment:scenario=="unassociated" ? .detached:.attached,tunnel:true),local:scenario=="unassociated" ? .unknown:.response,internet:scenario.isEmpty ? [.response,.response]:[.timeout,.timeout],sampledAt:clock.now,boundInterface:"preview0")}
    func readPower(interface:String) async -> Power {fakePower}
    func command(on:Bool,interface:String) async -> CommandResult {guard scenario=="unassociated" else{return CommandResult(began:false,power:.on,error:Fault("Preview",1,"预览不操作硬件"))};fakePower=on ? .on:.off;return CommandResult(began:true,power:fakePower)}
}
@MainActor final class AppModel: ObservableObject {
    let engine:Coordinator,store:Store,preview:Bool
    let locationAccess=LocationAccess()
    private var adoptCurrentAfterAuthorization=false
    @Published var tab=0
    @Published var page=0
    @Published var settingsPage=0
    @Published var history:[Event]=[]
    @Published var detail:String?
    @Published var notice=""
    @Published var draft=Settings()
    private var proofScenario="",proofClock:PreviewClock?
    private var timer:Timer?,observers:[NSObjectProtocol]=[],resumeAfterWake=false
    init(preview:Bool) {
        self.preview=preview
        let directory=preview ? URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("WiFiSentinel-preview-\(UUID().uuidString)"):
            FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WiFiSentinel")
        store=Store(directory:directory)
        let args=CommandLine.arguments
        let scenario:String = {guard preview,let i=args.firstIndex(of:"--policy-preview"),args.indices.contains(i+1),["first","cooling","human","unassociated"].contains(args[i+1]) else{return ""};return args[i+1]}()
        var settings=preview ? Settings():store.load();if !scenario.isEmpty{settings.internetTrial=true};draft=settings
        let clock:Clock=preview ? PreviewClock():RealClock();proofClock=clock as? PreviewClock;proofScenario=scenario
        let backend:Backend=preview ? PreviewBackend(clock,scenario:scenario):NativeBackend()
        var initial=preview ? AutomaticState():store.loadAutomaticState()
        if !scenario.isEmpty && scenario != "unassociated"{_=initial.time.advance(clock.reading);initial.failures=scenario=="cooling" ? 2:1;initial.retryAt=initial.time.logical+(scenario=="cooling" ? 1800:60);initial.manualIntervention=scenario=="human";initial.lastResult="offline-ui-"+scenario}
        let logger=store,writer=SnapshotWriter(store:store)
        engine=Coordinator(settings:settings,backend:backend,clock:clock,automaticState:initial,saveState:{logger.saveAutomaticState($0)},snapshot:{writer.submit($0)},persist:{logger.append($0)})
        if preview && !scenario.isEmpty{engine.setAutomatic(true)}
        history=preview ? (0..<24).map{Event(.blocked,"界面预览事件 \($0+1)：本地通路有响应，业务异常不自动等同 Wi-Fi 故障；详细结果可分页查看或导出。"+($0 % 2 == 0 ? String(repeating:" 这是用于检查双行摘要和详情分页的离线假数据。",count:3):""))} : store.history()
    }
    func start() {
        if preview,proofScenario=="unassociated",let clock=proofClock{
            Task{[weak self] in guard let self else{return};for i in 0..<3{self.engine.request(.timer);await self.engine.waitForIdle();if i<2{clock.advance(60)}}};return
        }
        engine.request(.timer);guard !preview else{return};schedule()
        let center=NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self] _ in
            Task{@MainActor in guard let self else{return};self.resumeAfterWake=self.engine.monitoring;self.engine.setMonitoring(false)}})
        observers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self] _ in
            Task{@MainActor in guard let self,self.resumeAfterWake else{return};self.notice="唤醒后等待系统30秒，不立即关开"
                try?await Task.sleep(nanoseconds:30_000_000_000);guard self.resumeAfterWake else{return};self.resumeAfterWake=false;self.engine.setMonitoring(true);self.notice="";self.engine.request(.timer)}})
    }
    private func schedule() {timer?.invalidate();timer=Timer.scheduledTimer(withTimeInterval:engine.settings.interval,repeats:true){[weak self] _ in Task{@MainActor in self?.engine.request(.timer)}}}
    func toggleMonitoring() {resumeAfterWake=false;engine.setMonitoring(!engine.monitoring)}
    func save() {
        guard !engine.busy else{notice="任务进行中，完成后再保存";return}
        if let error=draft.validation{notice=error;return}
        if engine.automatic && draft.internetTrial && !engine.settings.internetTrial {
            let alert=NSAlert();alert.messageText="启用上网异常循环恢复？"
            alert.informativeText="总开关已开启。每次双目标3轮且至少120秒超时后可关开，即使LAN正常；上游或VPN故障也可能触发并中断连接。连续两次联网验证失败后冷却30分钟，到期重新判定后可再一轮。开启未确认需人工处理。"
            alert.addButton(withTitle:"取消");alert.addButton(withTitle:"理解并应用")
            guard alert.runModal() == .alertSecondButtonReturn else{return}
        }
        if let error=engine.configure(draft){notice=error;return}
        do{try store.save(draft);notice="设置已保存；总开关与当前策略分别显示";schedule()}catch{notice="保存失败：\((error as NSError).domain) [\((error as NSError).code)]"}
    }
    func authorizeCurrentNetwork(){
        guard !preview,!engine.busy else{return}
        adoptCurrentAfterAuthorization=true
        locationAccess.onChange={[weak self] in
            guard let self,self.adoptCurrentAfterAuthorization else{return}
            self.notice=self.locationAccess.message
            if self.locationAccess.granted{
                self.adoptCurrentAfterAuthorization=false
                do{let current=try CurrentSavedNetwork.read();self.draft.knownNetworkSSID=current.ssid;self.notice="已读取当前实际且已保存网络；请保存目标后再验证。"}
                catch{self.notice="当前SSID不可可靠读取或不属于明确已保存网络；停止，不从历史列表猜测。"}
            }
        }
        locationAccess.request();locationAccess.onChange?()
    }
    func validateKnownNetwork(){
        guard !preview,!engine.busy else{return}
        guard draft == engine.settings,!engine.settings.knownNetworkSSID.isEmpty else{notice="请先保存明确的已保存网络名称";return}
        let alert=NSAlert();alert.messageText="单次验证已保存网络重联？"
        alert.informativeText="仅在自然未关联且现有权限可核对目标时，对所选已保存网络发送一次无密码关联请求；当前仍关联时停止，绝不为验证主动断开。不关闭Wi-Fi、不读取钥匙串、不提权、不申请定位权限。现有权限或系统凭据不足时停止；只有目标关联、本地及双业务响应都通过，才允许本次运行自动使用此路径。下次启动须重新验证。"
        alert.addButton(withTitle:"取消");alert.addButton(withTitle:"理解并单次验证")
        guard alert.runModal() == .alertSecondButtonReturn else{return}
        engine.validateKnownNetwork(confirmed:true)
    }
    func automatic(_ enabled:Bool) {
        if enabled {
            guard !engine.busy else{notice="本轮检测／恢复完成后再启用，避免风险弹窗阻塞重新开启";return}
            let alert=NSAlert();alert.messageText="允许本次启动自动关开 Wi-Fi？"
            let mode=engine.settings.internetTrial ? "已选择上网异常循环恢复：每次双目标3轮且至少120秒超时可关开，即使LAN正常；上游或VPN故障也可能触发。连续两次联网验证失败后冷却30分钟，到期重新判定后可继续。":"保守策略仅允许可信本地故障或持续未关联；同样需3轮及120秒，连续两次失败后冷却30分钟再判定。"
            alert.informativeText=mode+"\n\n关开会中断SSH、传输和VPN；先等待macOS加入；已选择且本次验证过的已保存网络可单次请求重联。未关联但无可用目标时停止，不读取密码。系统拒绝会显示错误。没有每次启动总次数上限；两次失败后30分钟冷却和失败计数跨重启保存。下次启动总开关重新关闭。"
            alert.addButton(withTitle:"取消");alert.addButton(withTitle:"理解并启用")
            guard alert.runModal() == .alertSecondButtonReturn else{return}
        }
        engine.setAutomatic(enabled)
    }
    func repairOnce() {
        guard !engine.busy else{notice="当前任务进行中；不会再打开修复确认";return}
        let alert=NSAlert();alert.messageText="现在执行一次 Wi-Fi 恢复？"
        alert.informativeText="这是明确确认的一次恢复，不是检测。已关联时可能关开 Wi-Fi，中断无线、VPN、SSH及传输；未关联时只对所选且本次已验证的已保存网络请求关联，否则停止。不会猜网络、取密码或提权。手动与自动串行，不占自动失败计数；两次自动失败的冷却期内不执行。"
        alert.addButton(withTitle:"取消");alert.addButton(withTitle:"确认恢复一次")
        if alert.runModal() == .alertSecondButtonReturn {engine.request(.explicitRepair,repairConfirmed:true)}
    }
    var allEvents:[Event] {Array((history+engine.events).suffix(200).reversed())}
    var pageCount:Int {max(1,Int(ceil(Double(allEvents.count)/5)))}
    var pageEvents:[Event] {let start=min(page,pageCount-1)*5;return Array(allEvents.dropFirst(start).prefix(5))}
    func clearLogs() {
        guard !engine.busy else{notice="恢复／检测进行中，完成后再清理日志";return}
        let alert=NSAlert();alert.messageText="清理 WiFi 哨兵异常日志？";alert.informativeText="只删除本软件两份有界异常日志；保留设置和当前恢复许可。"
        alert.addButton(withTitle:"取消");alert.addButton(withTitle:"清理日志")
        guard alert.runModal() == .alertSecondButtonReturn else{return}
        do{try store.clearLogs();history=[];engine.clearVisibleEvents();page=0;notice="日志已清理"}catch{notice="清理失败：\((error as NSError).domain) [\((error as NSError).code)]"}
    }
    func export() {
        guard !engine.busy else{notice="当前任务进行中，完成后再导出";return}
        let panel=NSSavePanel();panel.nameFieldStringValue="WiFiSentinel-diagnostics.json"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        let value:[String:Any]=["build":"rewrite5-exit0","phase":engine.phase.rawValue,"reason":engine.reason,"attempts":engine.attempts,
            "automatic":engine.automatic,"joinedRequests":engine.joinedRequests,"needsRestore":engine.needsRestore,
            "repair":(try?JSONEncoder().encode(engine.repair)).flatMap{try?JSONSerialization.jsonObject(with:$0)} ?? NSNull(),
            "internetTrialSelected":engine.settings.internetTrial,
            "runtimeSnapshot":(try?JSONEncoder().encode(engine.runtimeSnapshot())).flatMap{try?JSONSerialization.jsonObject(with:$0)} ?? NSNull(),
            "events":(try?JSONEncoder().encode(allEvents)).flatMap{try?JSONSerialization.jsonObject(with:$0)} ?? []]
        do{try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)}catch{notice="导出失败"}
    }
    func shutdown() async -> Bool {resumeAfterWake=false;timer?.invalidate();return await engine.shutdown()}
}
