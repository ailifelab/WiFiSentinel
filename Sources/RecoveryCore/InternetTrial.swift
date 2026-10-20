import Foundation

/// Read-only legacy migration type; new policy does not use a permanent latch.
public struct TrialLatch:Codable,Equatable {
    public var consumed=false,notBeforeWall=0.0,generation=0,lastResult="none"
    public init(){}
    public var valid:Bool{notBeforeWall.isFinite && notBeforeWall>=0 && generation>=0 && lastResult.count<=160}
}
public struct TrialSnapshot:Codable,Equatable {public let failureRounds:Int,elapsedSeconds:Double}
public enum TrialDecision:Equatable {case irrelevant,healthy,pending,ready}
public struct InternetTrial {
    private var started:Double?,lastCounted:Double?,lastObserved:Double?,identity="",rounds=0
    public init(){}
    public mutating func resetWindows(){started=nil;lastCounted=nil;lastObserved=nil;identity="";rounds=0}
    public func snapshot(now:Double)->TrialSnapshot{TrialSnapshot(failureRounds:rounds,elapsedSeconds:started.map{max(0,now-$0)} ?? 0)}
    public mutating func observe(_ s:Sample,observedAt:Double,policyTime:Double,qualifies:Bool,armed:Bool,maximumGap:Double)->TrialDecision {
        if Self.healthy(s,at:observedAt){resetWindows();return .healthy}
        guard armed,qualifies else{resetWindows();return .irrelevant}
        // Continuity uses the last actual observation, not the last counted round.
        if identity != s.link.identity || lastObserved.map({policyTime-$0>maximumGap})==true{resetWindows();identity=s.link.identity}
        lastObserved=policyTime
        // Distinct rounds at least30s apart; total fault duration still>=120s.
        if lastCounted==nil || policyTime-lastCounted!>=30{if started==nil{started=policyTime};rounds=min(3,rounds+1);lastCounted=policyTime}
        return rounds>=3 && policyTime-(started ?? policyTime)>=120 ? .ready:.pending
    }
    public static func healthy(_ s:Sample,at now:Double)->Bool {
        s.fresh(at:now) && s.link.power == .on && !s.link.sleeping && !s.link.wired && s.link.attachment == .attached &&
        !s.link.interface.isEmpty && !s.link.identity.isEmpty && s.verifiedLocal && s.local == .response && s.internet.count==2 && s.internet.allSatisfy{$0 == .response}
    }
}
