import Foundation

public struct ClockReading:Codable,Equatable {
    public let boot:String,awake:Double,continuous:Double,wall:Double
    public init(boot:String,awake:Double,continuous:Double,wall:Double){self.boot=boot;self.awake=awake;self.continuous=continuous;self.wall=wall}
    public var valid:Bool{!boot.isEmpty && boot.count<=128 && [awake,continuous].allSatisfy{$0.isFinite && (0...1e12).contains($0)} && wall.isFinite && (0...1e13).contains(wall)}
}
public struct SafePolicyTime:Codable,Equatable {
    public var boot="",awakeAnchor=0.0,continuousAnchor=0.0,logical=0.0
    public init(){}
    public var valid:Bool{boot.count<=128 && [awakeAnchor,continuousAnchor,logical].allSatisfy{$0.isFinite && (0...1e12).contains($0)}}
    public mutating func advance(_ r:ClockReading)->(interrupted:Bool,trusted:Bool,checkpoint:Bool) {
        guard r.valid else{return (true,false,false)}
        if boot.isEmpty || boot != r.boot {let changed = !boot.isEmpty;boot=r.boot;awakeAnchor=r.awake;continuousAnchor=r.continuous;return (changed,true,true)}
        let a=r.awake-awakeAnchor,c=r.continuous-continuousAnchor
        // Retain high-water anchors on rollback, so replayed time gets no credit.
        guard a>=0,c>=0,a<=c+0.05,logical+a<=1e12 else{return (true,false,false)}
        logical += a;awakeAnchor=r.awake;continuousAnchor=r.continuous
        return (c-a>2,true,false)
    }
}
/// Two failed attempts ->30minutes cooling ->fresh fault evaluation ->new round.
/// No per-launch automatic quota and no permanent ordinary-failure latch.
public struct AutomaticState:Codable,Equatable {
    public var schema=3,time=SafePolicyTime(),failures=0,round=0
    public var retryAt=0.0,sharedNotBefore=0.0,manualNotBefore=0.0
    public var inFlight="",manualIntervention=false,automaticTotal=0,manualTotal=0
    public var lastResult="none",note=""
    public init(){}
    public var valid:Bool{schema==3 && time.valid && (0...2).contains(failures) && round>=0 &&
        [retryAt,sharedNotBefore,manualNotBefore].allSatisfy{$0.isFinite && $0>=0 && $0<=time.logical+86400} &&
        ["","automatic","manual"].contains(inFlight) && automaticTotal>=0 && manualTotal>=0 && lastResult.count<=160 && note.count<=200}
    public var retryWait:Double{max(0,retryAt-time.logical)}
    public var sharedWait:Double{max(0,sharedNotBefore-time.logical)}
    public var manualWait:Double{max(0,manualNotBefore-time.logical)}
    public var cooling:Bool{failures==2 && retryWait>0}
    public mutating func prepare(automatic:Bool) {
        inFlight=automatic ? "automatic":"manual";lastResult="attempt-prepared"
        if automatic {if automaticTotal<Int.max{automaticTotal += 1}}
        else if manualTotal<Int.max{manualTotal += 1}
    }
    public mutating func verifiedHealth(_ reason:String){failures=0;retryAt=0;manualIntervention=false;lastResult=reason}
    public mutating func reopenIfDue()->Bool {
        guard failures==2,retryWait==0 else{return false}
        failures=0;retryAt=0;if round<Int.max{round += 1};lastResult="cooldown-ended-awaiting-fresh-fault";return true
    }
    public mutating func finish(automatic:Bool,success:Bool,radioSafe:Bool,manualDelay:Double) {
        inFlight="";sharedNotBefore=max(sharedNotBefore,time.logical+60)
        if !automatic{manualNotBefore=max(manualNotBefore,time.logical+manualDelay)}
        if success{verifiedHealth("verified-network-success")}
        else if automatic{failures=min(2,failures+1);retryAt=time.logical+(failures==2 ? 1800:60);lastResult=failures==2 ? "two-failures-cooling":"first-failure-awaiting-reconfirmation"}
        else{lastResult="manual-network-not-verified"}
        if !radioSafe{manualIntervention=true;lastResult="radio-cleanup-needs-human"}
    }
    public mutating func recoverInterruptedTransaction() {
        guard !inFlight.isEmpty else{return};let auto=inFlight=="automatic";inFlight="";manualIntervention=true
        if auto{failures=min(2,failures+1);retryAt=max(retryAt,time.logical+(failures==2 ? 1800:60))}
        sharedNotBefore=max(sharedNotBefore,time.logical+90);lastResult="interrupted-transaction-needs-human"
    }
    public static func upgrade(legacy:TrialLatch?,unverified:Bool=false)->AutomaticState {
        var s=AutomaticState()
        if unverified || legacy.map({$0.consumed || $0.notBeforeWall>0})==true {
            s.failures=2;s.retryAt=1800;s.lastResult="legacy-or-unverified-cooling";s.note="旧锁或未知状态迁移为30分钟清醒时间冷却，不保留永久锁"
        };return s
    }
}
public struct ExecutionAvailability:Codable,Equatable {
    public let permission:Bool,eligibleForFreshFault:Bool,blockers:[String]
    public let consecutiveFailures:Int,cooling:Bool,retryWaitAwakeSeconds:Double,sharedWaitAwakeSeconds:Double
    public let estimatedRetryWall:Double?
    public var text:String{blockers.isEmpty ? "已授权；等待新鲜故障满足3轮及120秒":"自动执行暂停："+blockers.joined(separator:"；")}
}
public struct RuntimeSnapshot:Codable {
    public var knownNetwork:KnownNetworkStatus?
    public let build:String,policyVersion:String
    public let settings:Settings
    public let schema:Int,generatedWall:Double,generatedContinuous:Double,boot:String
    public let automaticPermission:Bool,internetTrialSelected:Bool,monitoring:Bool,busy:Bool,needsRestore:Bool
    public let phase:Phase,reason:String,manualSessionAttempts:Int,automaticSessionAttempts:Int
    public let state:AutomaticState,availability:ExecutionAvailability,trial:TrialSnapshot
    public let sample:Sample?,repair:Repair?
    public init(settings:Settings,wall:Double,continuous:Double,boot:String,automatic:Bool,selected:Bool,monitoring:Bool,busy:Bool,needsRestore:Bool,phase:Phase,reason:String,manual:Int,auto:Int,state:AutomaticState,availability:ExecutionAvailability,trial:TrialSnapshot,sample:Sample?,repair:Repair?){build="rewrite5-exit0";policyVersion="two-failures-30m-v3";self.settings=settings;schema=3;generatedWall=wall;generatedContinuous=continuous;self.boot=boot;automaticPermission=automatic;internetTrialSelected=selected;self.monitoring=monitoring;self.busy=busy;self.needsRestore=needsRestore;self.phase=phase;self.reason=reason;manualSessionAttempts=manual;automaticSessionAttempts=auto;self.state=state;self.availability=availability;self.trial=trial;self.sample=sample;self.repair=repair}
}
