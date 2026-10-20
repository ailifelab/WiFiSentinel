import Foundation

public enum Power: String, Codable { case on, off, unknown }
public enum Attachment: String, Codable { case attached, detached, configuring, unknown }
public enum Signal: String, Codable { case response, timeout, unknown,portal,httpError,dnsFailure,tlsFailure,permissionDenied,refused }
public struct Link: Equatable, Codable {
    public var interface: String, identity: String, gateway: String
    public var power: Power, attachment: Attachment
    public var sleeping: Bool, wired: Bool, tunnel: Bool
    public var networkID:String?
    public init(interface: String = "", identity: String = "", gateway: String = "", power: Power = .unknown,
                attachment: Attachment = .unknown, sleeping: Bool = false, wired: Bool = false, tunnel: Bool = false,networkID:String?=nil) {
        self.interface=interface; self.identity=identity; self.gateway=gateway; self.power=power
        self.attachment=attachment; self.sleeping=sleeping; self.wired=wired; self.tunnel=tunnel;self.networkID=networkID
    }
}
public struct Sample: Equatable, Codable {
    public var link: Link, local: Signal, internet: [Signal]
    public var sampledAt: Double, boundInterface: String?, reason: String
    public init(link: Link, local: Signal, internet: [Signal], sampledAt: Double, boundInterface: String? = nil, reason: String = "") {
        self.link=link; self.local=local; self.internet=internet; self.sampledAt=sampledAt
        self.boundInterface=boundInterface; self.reason=reason
    }
    public func fresh(at now: Double) -> Bool { now >= sampledAt && now-sampledAt <= 5 }
    public var verifiedLocal: Bool { !link.interface.isEmpty && boundInterface == link.interface }
}
public struct Settings: Codable, Equatable {
    public var interval: Double = 60
    public var customURL = ""
    public var localTCPPort: Int = 0
    public var cooldown: Double = 300
    public var internetTrial = false
    public var knownNetworkSSID = ""
    public init() {}
    private enum CodingKeys: String,CodingKey {case interval,customURL,localTCPPort,cooldown,internetTrial,knownNetworkSSID}
    public init(from decoder:Decoder) throws {
        self.init();let c=try decoder.container(keyedBy:CodingKeys.self)
        interval=try c.decodeIfPresent(Double.self,forKey:.interval) ?? interval
        customURL=try c.decodeIfPresent(String.self,forKey:.customURL) ?? customURL
        localTCPPort=try c.decodeIfPresent(Int.self,forKey:.localTCPPort) ?? localTCPPort
        cooldown=try c.decodeIfPresent(Double.self,forKey:.cooldown) ?? cooldown
        internetTrial=try c.decodeIfPresent(Bool.self,forKey:.internetTrial) ?? false
        knownNetworkSSID=try c.decodeIfPresent(String.self,forKey:.knownNetworkSSID) ?? ""
    }
    public var urls: [String] { [customURL.isEmpty ? "https://www.apple.com/library/test/success.html":customURL,
                                "https://www.cloudflare.com/cdn-cgi/trace"] }
    public var validation: String? {
        guard interval.isFinite, (30...3600).contains(interval), cooldown.isFinite,
              (60...3600).contains(cooldown), (0...65535).contains(localTCPPort) else {return "设置超出范围"}
        guard knownNetworkSSID.isEmpty || KnownNetwork.validName(knownNetworkSSID) else{return "已保存网络名称须为1–32字节，不含控制字符或前导短横线"}
        guard urls.allSatisfy(Self.validURL), let a=URL(string:urls[0])?.host, let b=URL(string:urls[1])?.host,
              a.lowercased() != b.lowercased() else {return "目标须为独立 HTTP/HTTPS 地址，不含凭据、查询或片段"}
        return nil
    }
    public static func validURL(_ text: String) -> Bool {
        guard text.count<=512, let c=URLComponents(string:text), ["http","https"].contains(c.scheme ?? ""),
              let host=c.host, !host.isEmpty, c.user==nil, c.password==nil, c.query==nil, c.fragment==nil,
              host.unicodeScalars.allSatisfy({$0.isASCII && $0.value>32}), !text.contains("\n") else {return false}
        return c.port.map{(1...65535).contains($0)} ?? true
    }
}
public enum Trigger: String, Codable { case timer, manual, explicitRepair }
public enum Phase: String, Codable { case idle, checking, confirming, blocked, poweringOff, restoringOn, joining, verifying, recovered, attention }
public struct Fault: Error, Codable, Equatable {
    public let domain: String, code: Int, message: String
    public init(_ domain: String, _ code: Int, _ message: String) {self.domain=domain;self.code=code;self.message=String(message.prefix(240))}
    public var description: String {"\(domain) [\(code)]：\(message)"}
}
public struct CommandResult: Codable, Equatable {
    public var began: Bool, timedOut: Bool, power: Power, error: Fault?
    public init(began: Bool, timedOut: Bool = false, power: Power, error: Fault? = nil) {
        self.began=began;self.timedOut=timedOut;self.power=power;self.error=error
    }
}
public enum RepairOutcome:String,Codable {case networkVerified,radioOnNotAssociated,networkUnverified,controlUnconfirmed,verificationCancelled}
public enum RepairKind:String,Codable {case powerCycle,knownNetworkJoin}
public struct Repair: Codable, Equatable {
    public var kind:RepairKind?,rejoin:KnownNetworkResult?,targetID:String?,targetVerified:Bool?,lastVerificationNetworkID:String?
    public var attempt: Int, trigger: Trigger, reason: String
    public var off: CommandResult?, on: CommandResult?, finalPower: Power = .unknown
    public var interface = "", onResults: [CommandResult] = []
    public var offConfirmed = false
    public var limitedTrial = false
    public var localCycleWorker = false
    public var localVerified = false, internetVerified = false, needsRestore = false
    public var outcome:RepairOutcome?,lastVerificationAttachment:Attachment?,lastVerificationSampledAt:Double?
    public var verificationFailure:String?
    public var verificationSummary:String {
        switch outcome {
        case .networkVerified:return kind == .knownNetworkJoin ? "本次已保存网络重联已验证目标关联、本地和双业务响应":"本次恢复后已验证关联、本地和双业务响应"
        case .radioOnNotAssociated:return "无线电已开启，但未重新关联；本次联网恢复失败"
        case .networkUnverified:return "无线电已开启，联网仍未验证"
        case .controlUnconfirmed:return kind == .knownNetworkJoin ? "关联命令未确认结束，需人工检查":"关闭或开启未确认，需人工检查"
        case .verificationCancelled:return kind == .knownNetworkJoin ? "关联控制结束，联网验证取消":"开启清理完成，联网验证取消"
        case nil:return internetVerified && localVerified ? "已验证本地和业务响应":"本次联网未验证；电源开启不代表已重联"
        }
    }
    public var error: Fault?
    public init(attempt: Int, trigger: Trigger, reason: String) {self.attempt=attempt;self.trigger=trigger;self.reason=reason}
}
public struct Event: Codable, Identifiable, Equatable {
    public let id: UUID, time: Date, phase: Phase, message: String
    public init(_ phase: Phase, _ message: String) {id=UUID();time=Date();self.phase=phase;self.message=String(message.prefix(700))}
}
@MainActor public protocol Clock: AnyObject {var now: Double {get};var wallNow:Double{get};var awakeNow:Double{get};var bootID:String{get};func wait(_ seconds: Double) async}
public extension Clock {var wallNow:Double{now};var awakeNow:Double{now};var bootID:String{"test-boot"};var reading:ClockReading{ClockReading(boot:bootID,awake:awakeNow,continuous:now,wall:wallNow)}}
@MainActor public protocol RadioPort: AnyObject {
    var commandsSettled: Bool {get}
    func readPower(interface: String) async -> Power
    func command(on: Bool, interface: String) async -> CommandResult
}
public extension RadioPort {var commandsSettled: Bool {true}}
@MainActor public protocol Backend: RadioPort,KnownNetworkPort {
    func inspect(_ settings: Settings) async -> Sample
    func cycle(interface:String,identity:String,permitUntil:Double,clock:Clock,event:@escaping(Phase,String)->Void) async -> CycleResult
}
public extension Backend {
    func cycle(interface:String,identity:String,permitUntil:Double,clock:Clock,event:@escaping(Phase,String)->Void) async -> CycleResult {
        await PowerCycle.run(port:self,interface:interface,permitUntil:permitUntil,clock:clock,event:event)
    }
}
