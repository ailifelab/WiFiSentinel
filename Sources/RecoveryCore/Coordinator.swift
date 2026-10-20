import Foundation
import Combine

@MainActor public final class Coordinator:ObservableObject {
    @Published public private(set) var phase:Phase = .idle
    @Published public private(set) var reason="仅监测；自动恢复本次启动默认关闭"
    @Published public private(set) var sample:Sample?
    @Published public private(set) var failures=0
@Published public private(set) var attempts=0
@Published public private(set) var manualAttempts=0
@Published public private(set) var automaticAttempts=0
@Published public private(set) var joinedRequests=0
    @Published public private(set) var automatic=false
@Published public private(set) var monitoring=true
@Published public private(set) var busy=false
@Published public private(set) var needsRestore=false
    @Published public private(set) var repair:Repair?
    @Published public private(set) var events:[Event]=[]
    @Published public private(set) var knownNetworkStatus=KnownNetworkStatus(.noTarget,"未选择或验证已保存网络")
    @Published public private(set) var settings:Settings
    private let backend:Backend,clock:Clock,persist:(Event)->Void,saveState:(AutomaticState)->Bool,snapshotSink:(RuntimeSnapshot)->Void
    private var task:Task<Void,Never>?,knownLocal:[String:Double]=[:],stopRequested=false
    private var state:AutomaticState,trial=InternetTrial(),storageOK=true,clockOK=true,dirty=false
    private var lastLogKey="",abnormalActive=false
    public init(settings:Settings=Settings(),backend:Backend,clock:Clock,automaticState:AutomaticState=AutomaticState(),saveState:@escaping(AutomaticState)->Bool={_ in true},snapshot:@escaping(RuntimeSnapshot)->Void={_ in},persist:@escaping(Event)->Void={_ in}) {
        self.settings=settings;self.backend=backend;self.clock=clock;self.state=automaticState.valid ? automaticState:AutomaticState.upgrade(legacy:nil,unverified:true)
        self.saveState=saveState;self.snapshotSink=snapshot;self.persist=persist
        if !self.state.inFlight.isEmpty{self.state.recoverInterruptedTransaction();needsRestore=true;dirty=true}
    }
    public var automaticState:AutomaticState{state}
    private var projected:AutomaticState{var copy=state;_=copy.time.advance(clock.reading);return copy}
    public var trialSnapshot:TrialSnapshot{trial.snapshot(now:projected.time.logical)}
    public var cooldownRemaining:Double{max(projected.retryWait,projected.sharedWait)}
    public var availability:ExecutionAvailability {
        let s=projected;var b:[String]=[]
        if !automatic{b.append("本次自动许可关闭")};if !monitoring{b.append("监测已暂停")}
        if !clockOK{b.append("时间基准不可核验")};if !storageOK{b.append("持久状态保存失败")}
        if s.manualIntervention || needsRestore || !backend.commandsSettled{b.append("开启或旧事务未确认，需人工检查")}
        if s.cooling{b.append("两次失败，冷却尚余\(Int(ceil(s.retryWait)))秒清醒时间")}
        else if s.failures==2{b.append("冷却已到，等待新鲜检测")}
        else if s.retryWait>0{b.append("下次复核最早还需\(Int(ceil(s.retryWait)))秒清醒时间")}
        if s.sharedWait>0{b.append("串行间隔尚余\(Int(ceil(s.sharedWait)))秒")}
        return ExecutionAvailability(permission:automatic,eligibleForFreshFault:b.isEmpty && !busy,blockers:b,consecutiveFailures:s.failures,cooling:s.cooling,retryWaitAwakeSeconds:s.retryWait,sharedWaitAwakeSeconds:s.sharedWait,estimatedRetryWall:max(s.retryWait,s.sharedWait)>0 ? clock.wallNow+max(s.retryWait,s.sharedWait):nil)
    }
    public func runtimeSnapshot()->RuntimeSnapshot{var value=RuntimeSnapshot(settings:settings,wall:clock.wallNow,continuous:clock.now,boot:clock.bootID,automatic:automatic,selected:settings.internetTrial,monitoring:monitoring,busy:busy,needsRestore:needsRestore,phase:phase,reason:reason,manual:manualAttempts,auto:automaticAttempts,state:projected,availability:availability,trial:trialSnapshot,sample:sample,repair:repair);value.knownNetwork=knownNetworkStatus;return value}
    private func emitSnapshot(){snapshotSink(runtimeSnapshot())}
    private func commit()->Bool{storageOK=saveState(state);dirty = !storageOK;return storageOK}
    private func syncTime()->Bool{
        let change=state.time.advance(clock.reading);clockOK=change.trusted
        if change.interrupted{trial.resetWindows();knownLocal.removeAll()}
        if change.checkpoint || dirty || !storageOK{guard commit() else{return false}}
        return clockOK
    }
    public func configure(_ value:Settings)->String?{guard !busy else{return "检测／恢复进行中，完成后再保存"};if let error=value.validation{return error};if value.knownNetworkSSID != settings.knownNetworkSSID{backend.invalidateKnownNetwork();knownNetworkStatus=KnownNetworkStatus(value.knownNetworkSSID.isEmpty ? .noTarget:.needsValidation,"已保存网络目标改变；须单次验证")}
        settings=value;knownLocal.removeAll();trial.resetWindows();emitSnapshot();return nil}
    public func setAutomatic(_ value:Bool){if automatic != value{trial.resetWindows()};automatic=value;announce(.idle,value ? "已确认启用本次启动自动恢复":"自动恢复已关闭；未来检查只诊断");emitSnapshot()}
    public func setMonitoring(_ value:Bool){monitoring=value;if !value{knownLocal.removeAll();trial.resetWindows();announce(.idle,"已暂停；正在进行的安全重新开启会完成")};emitSnapshot()}
    public func request(_ trigger:Trigger = .manual,repairConfirmed:Bool=false){
        if busy{joinedRequests += 1;return};guard !stopRequested else{return}
        guard monitoring || trigger == .explicitRepair else{announce(.blocked,"监测已暂停");return}
        guard trigger != .explicitRepair || repairConfirmed else{announce(.blocked,"单次修复尚未确认中断风险");return}
        busy=true;emitSnapshot();task=Task{[weak self] in guard let self else{return};await self.run(trigger);self.busy=false;self.task=nil;self.emitSnapshot()}
    }
    /// A separate, user-confirmed join request; never a timer-driven probe of
    /// an unqualified CLI capability. It does not switch radio power.
    public func validateKnownNetwork(confirmed:Bool){
        guard confirmed,!busy,!stopRequested,monitoring,!settings.knownNetworkSSID.isEmpty else{announce(.blocked,"单次已保存网络验证尚未确认、目标缺失或当前不可执行");return}
        busy=true;emitSnapshot();task=Task{[weak self] in
            guard let self else{return}
            let current=await self.backend.inspect(self.settings);self.sample=current
            await self.execute(current,trigger:.explicitRepair,explanation:"用户确认单次无密码已保存网络重联验证",validation:true)
            self.busy=false;self.task=nil;self.emitSnapshot()
        }
    }
    public func waitForIdle() async{await task?.value}
    public func shutdown() async->Bool{
        stopRequested=true;monitoring=false;automatic=false;await task?.value
        if needsRestore,backend.commandsSettled,let i=repair?.interface,await backend.readPower(interface:i) == .on{needsRestore=false;repair?.needsRestore=false;repair?.finalPower = .on}
        emitSnapshot();return !needsRestore
    }
    public func cancelShutdown(){stopRequested=false;emitSnapshot()}
    public func clearVisibleEvents(){events.removeAll()}
    private func announce(_ next:Phase,_ message:String){
        let changed=phase != next || reason != message;phase=next;reason=message;guard changed else{return};emitSnapshot();if next == .checking{return}
        var logged=message
        if next == .idle && message=="检测正常"{guard abnormalActive else{return};abnormalActive=false;logged=(repair != nil && repair?.internetVerified != true) ? "异常结束：当前本地和业务探测恢复健康；最近关开未验证成功，可能由系统或用户重联，不追记为本次修复成功":"异常结束：本轮本地和业务探测均响应"}
        else if [.blocked,.attention,.confirming].contains(next){abnormalActive=true}
        if next == .recovered{abnormalActive=false}
        let key=next.rawValue+":"+logged;guard key != lastLogKey else{return};lastLogKey=key
        let e=Event(next,logged);events.append(e);events=Array(events.suffix(200));persist(e)
    }
    private func protection(_ s:Sample,manual:Bool=false)->String?{
        if !s.fresh(at:clock.now){return "本轮观测已过期；未授权恢复"};if s.link.sleeping{return "电脑睡眠；不恢复"}
        if s.link.power != .on{return s.link.power == .off ? "Wi-Fi 已关闭；尊重用户操作":"无线电状态不可读"}
        if s.link.interface.isEmpty || s.link.identity.isEmpty{return "物理 Wi-Fi 接口未知"}
        if s.link.wired{return "存在有线通路；不自动关开 Wi-Fi"}
        if needsRestore || state.manualIntervention || !backend.commandsSettled{return "上次开启或命令退出未确认；禁止再次关闭，请人工检查"}
        if stopRequested || (!monitoring && !manual){return "已暂停或正在退出"};return nil
    }
    private func faultReason(_ s:Sample)->String?{
        if s.link.attachment == .detached{return "明确未关联持续3轮且至少120秒，系统尚未加入"}
        guard s.link.attachment == .attached else{return nil}
        let both=s.internet.count==2 && s.internet.allSatisfy{$0 == .timeout};guard both else{return nil}
        if settings.internetTrial{return "按用户选择试探：双业务3轮且至少120秒超时；上游／VPN也可能触发，非Wi-Fi故障诊断"}
        guard s.verifiedLocal,s.local == .timeout,let prior=knownLocal[s.link.identity],clock.now-prior<=600 else{return nil}
        return "本链路曾有可信本地响应，当前本地和双业务3轮且至少120秒超时；根因未定"
    }
    private func run(_ trigger:Trigger) async{
        guard syncTime() else{announce(.attention,"时间或持久状态不可核验；暂停执行");return}
        announce(.checking,"正在检测（\(trigger.rawValue)）");let current=await backend.inspect(settings);sample=current
        guard syncTime() else{announce(.attention,"时间或持久状态不可核验；暂停执行");return}
        if needsRestore,backend.commandsSettled,let i=repair?.interface,await backend.readPower(interface:i) == .on{needsRestore=false;repair?.needsRestore=false;repair?.finalPower = .on}
        if current.fresh(at:clock.now),current.link.power == .on,!current.link.sleeping,!current.link.wired,current.link.attachment == .attached,current.verifiedLocal,current.local == .response,!current.link.identity.isEmpty{knownLocal[current.link.identity]=clock.now}
        let healthy=InternetTrial.healthy(current,at:clock.now) && backend.commandsSettled
        if healthy{
            knownLocal=[current.link.identity:clock.now]
            if (state.failures>0 || state.manualIntervention) && (!state.manualIntervention || state.sharedWait==0){
                state.verifiedHealth("natural-verified-health");needsRestore=false
                guard commit() else{announce(.attention,"健康已观测但状态保存失败；暂停执行");return}
            }
        }else if state.reopenIfDue(){guard commit() else{announce(.attention,"新轮状态保存失败；暂停执行");return}}
        if trigger == .explicitRepair{await execute(current,trigger:trigger,explanation:"用户确认单次修复；不代表已证明 Wi-Fi 是故障根因");return}
        if let block=protection(current){trial.resetWindows();failures=0;announce(.blocked,block);return}
        let explanation=faultReason(current)
        let decision=trial.observe(current,observedAt:clock.now,policyTime:state.time.logical,qualifies:explanation != nil,armed:automatic && monitoring,maximumGap:max(90,settings.interval+30));failures=trialSnapshot.failureRounds
        if decision == .healthy{announce(.idle,"检测正常");return}
        guard automatic else{announce(.blocked,"本次启动自动恢复未启用；仅检测");return}
        if state.cooling{announce(.blocked,"本轮连续失败2/2；30分钟冷却尚余\(Int(ceil(state.retryWait)))秒清醒时间，继续低频检测");return}
        if state.retryWait>0 || state.sharedWait>0{announce(.blocked,availability.text);return}
        // A third minute-timer sample may be a few milliseconds before120s.
        // Wait only the tiny remainder, then obtain a new sample; never lower120s.
        let remaining=120-trialSnapshot.elapsedSeconds
        if decision == .pending,failures>=3,remaining>0,remaining<=1 {
            await clock.wait(remaining)
            guard automatic,monitoring,!stopRequested,!Task.isCancelled else{announce(.blocked,"复核等待期间许可撤销或暂停；未执行");return}
            await run(trigger);return
        }
        if decision == .ready,let explanation{await execute(current,trigger:trigger,explanation:explanation)}
        else if decision == .pending{announce(.confirming,"故障复核\(failures)/3轮，持续\(Int(trialSnapshot.elapsedSeconds))秒；每次关开前均须3轮及120秒")}
        else{announce(.blocked,settings.internetTrial ? "没有两个独立目标的连续传输超时；单站、门户、HTTP/DNS/TLS或权限错误不触发":"保守策略尚无可信本地故障证据；LAN仍响应或本地证据未知时不自动关开")}
    }
    private func execute(_ evidence:Sample,trigger:Trigger,explanation:String,validation:Bool=false) async{
        let auto=trigger != .explicitRepair
        if let block=protection(evidence,manual:!auto){announce(.blocked,block);return}
        guard syncTime() else{announce(.attention,"时间或持久状态不可核验；未执行");return}
        guard !state.cooling else{announce(.blocked,"两次失败后的30分钟冷却中；不执行手动或自动恢复");return}
        guard state.sharedWait==0,(!auto || state.retryWait==0),(auto || state.manualWait==0) else{announce(.blocked,auto ? availability.text:"手动修复间隔尚余\(Int(ceil(max(state.manualWait,state.sharedWait))))秒");return}
        if validation,evidence.link.attachment != .detached {
            announce(.blocked,"当前仍关联或状态不明确；不把同网络重复设置当作重联验证，不主动断网。请在自然未关联时另行确认单次验证。");return
        }
        let target=settings.knownNetworkSSID.isEmpty ? nil:KnownNetwork.id(settings.knownNetworkSSID)
        let joinOnly=validation || evidence.link.attachment == .detached
        if target != nil || joinOnly {
            knownNetworkStatus=await backend.knownNetworkStatus(settings,interface:evidence.link.interface)
            guard validation ? knownNetworkStatus.canValidate:knownNetworkStatus.state == .ready else{
                announce(.blocked,"Wi-Fi 重联未执行："+knownNetworkStatus.message+"；不通过反复关开代替关联");return
            }
            if evidence.link.attachment == .attached,evidence.link.networkID != target{
                announce(.blocked,"当前关联不能核对为所选已保存网络；不会切换网络或关闭 Wi-Fi");return
            }
        }
        guard await backend.readPower(interface:evidence.link.interface) == .on else{announce(.blocked,"执行前 Wi-Fi 已关闭或不可读；不发送控制命令");return}
        guard evidence.fresh(at:clock.now) else{announce(.blocked,"执行前观测已过期；等待新一轮检测");return}
        guard !stopRequested && (!auto || automatic && monitoring) else{announce(.blocked,"执行前自动恢复许可已撤销");return}
        let previous=state;state.prepare(automatic:auto)
        guard commit() else{state=previous;trial.resetWindows();announce(.attention,"无法保存执行前状态；未执行恢复");return}
        attempts += 1;if auto{automaticAttempts += 1}else{manualAttempts += 1}
        var record=Repair(attempt:attempts,trigger:trigger,reason:explanation)
        record.interface=evidence.link.interface;record.limitedTrial=auto;record.targetID=target
        record.kind=joinOnly ? .knownNetworkJoin:.powerCycle
        if joinOnly {
            announce(.joining,"单次请求加入已核对的已保存网络；不提供密码、不关闭 Wi-Fi")
            record.rejoin=await backend.joinKnownNetwork(settings,interface:evidence.link.interface,validation:validation)
            record.finalPower=await backend.readPower(interface:evidence.link.interface)
        }else{
            needsRestore=true;announce(.poweringOff,"第\(attempts)次：独立本地关开事务执行中（\(auto ? "自动":"手动")）")
            let c=await backend.cycle(interface:evidence.link.interface,identity:evidence.link.identity,permitUntil:evidence.sampledAt+5,clock:clock,event:{[self] p,m in announce(p,m)})
            record.off=c.off;record.onResults=c.onResults;record.on=c.onResults.last;record.offConfirmed=c.offConfirmed;record.finalPower=c.finalPower;record.error=c.error;record.needsRestore=c.needsRestore;record.localCycleWorker=c.independentWorker;needsRestore=c.needsRestore
            if c.off?.began != true || !c.offConfirmed || c.needsRestore{
                record.outcome = .controlUnconfirmed;record.error=c.error ?? Fault("WiFiSentinel.Verify",3,"关闭／开启未确认；不声称完成关开");repair=record;automatic=false;_=finish(auto:auto,success:false,radioSafe:false)
                announce(.attention,"控制结果未确认，自动执行暂停；请人工检查系统 Wi-Fi："+record.error!.description);return
            }
        }
        if stopRequested || !monitoring || Task.isCancelled{record.outcome = .verificationCancelled;repair=record;_=finish(auto:auto,success:false,radioSafe:backend.commandsSettled);announce(.attention,"控制已结束；检测取消，联网结果未验证");return}
        announce(.verifying,"电源开启不代表联网；验证实际关联、本地和双业务响应，最多30秒")
        let deadline=clock.now+30,joinAfter=clock.now+6
        var joined=record.rejoin != nil
        while clock.now<deadline{
            if let result=record.rejoin,!result.commandCompleted{record.error=result.error;break}
            let left=deadline-clock.now;if left<9{await clock.wait(left);break}
            let s=await backend.inspect(settings);sample=s
            if s.fresh(at:clock.now),s.link.interface==evidence.link.interface {
                record.lastVerificationAttachment=s.link.attachment;record.lastVerificationSampledAt=s.sampledAt;record.lastVerificationNetworkID=s.link.networkID
                if s.link.power != .on {record.verificationFailure="验证期间 Wi-Fi 已关闭或状态未知；尊重用户操作，不重新开启";break}
                if let target,let actual=s.link.networkID,actual != target {record.verificationFailure="验证期间加入了其他网络；未把其他网络连通算作目标重联成功";break}
            }
            if s.link.interface==evidence.link.interface,InternetTrial.healthy(s,at:clock.now),target == nil || s.link.networkID == target {
                record.localVerified=true;record.internetVerified=true;record.targetVerified=target == nil ? nil:true;knownLocal=[s.link.identity:clock.now];break
            }
            if s.fresh(at:clock.now),s.verifiedLocal,s.local == .response{record.localVerified=true}
            if stopRequested || !monitoring || Task.isCancelled{break}
            if let target,!joined,clock.now>=joinAfter,s.fresh(at:clock.now),s.link.interface==evidence.link.interface,
               s.link.power == .on,s.link.attachment == .detached,!auto || automatic {
                guard knownNetworkStatus.targetID == target else{break}
                announce(.joining,"系统等待后仍未关联；仅发送一次已验证的已保存网络重联请求")
                record.rejoin=await backend.joinKnownNetwork(settings,interface:evidence.link.interface,validation:false);joined=true
                continue
            }
            await clock.wait(min(3,max(0,deadline-clock.now)))
        }
        var success=record.localVerified && record.internetVerified && (record.rejoin == nil || record.rejoin?.commandCompleted == true)
        if stopRequested || !monitoring || Task.isCancelled{success=false;record.outcome = .verificationCancelled;record.verificationFailure="控制已结束，联网验证取消"}
        if record.rejoin != nil {
            await backend.completeKnownNetwork(settings,interface:evidence.link.interface,verified:success)
            knownNetworkStatus=await backend.knownNetworkStatus(settings,interface:evidence.link.interface)
        }
        if !backend.commandsSettled{success=false;automatic=false;record.outcome = .controlUnconfirmed;record.error=record.rejoin?.error ?? Fault("WiFiSentinel.Worker",11,"关联命令未确认退出；禁止新控制")}
        else if success{record.outcome = .networkVerified}
        else if record.outcome == nil {
            if record.lastVerificationAttachment == .detached{record.outcome = .radioOnNotAssociated;record.verificationFailure=record.verificationFailure ?? "无线电已开启，但尚未重新关联；请在macOS Wi-Fi菜单选择已知网络。"}
            else{record.outcome = .networkUnverified;record.verificationFailure=record.verificationFailure ?? "目标关联或本地、双业务响应未全部验证；命令返回成功不代表联网恢复。"}
        }
        repair=record
        guard finish(auto:auto,success:success,radioSafe:backend.commandsSettled) else{return}
        if success{announce(.recovered,"已验证实际关联、本地和双业务响应；本轮自动失败计数清零")}
        else{
            let next = !automatic ? "自动许可已关闭，后续只诊断":(state.failures==2 ? "冷却30分钟后重新判定":"下一次仍需新鲜3轮及120秒故障证据")
            announce(.attention,(record.verificationFailure ?? record.error?.description ?? "联网尚未验证")+(auto ? " 本轮连续失败\(state.failures)/2；"+next:" 手动失败不占自动失败次数。"))
        }
    }
    private func finish(auto:Bool,success:Bool,radioSafe:Bool)->Bool{
        _=syncTime();state.finish(automatic:auto,success:success,radioSafe:radioSafe,manualDelay:settings.cooldown);trial.resetWindows();failures=0
        guard commit() else{announce(.attention,"执行结果状态保存失败；自动执行暂停");return false};return true
    }
}
