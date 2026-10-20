import Foundation
import CryptoKit

/// No credential is stored here. A name is accepted only after an exact match
/// against the system's saved network metadata in the native adapter.
public enum KnownNetwork {
    public static func validName(_ name:String)->Bool {
        let bytes=Array(name.utf8)
        return !bytes.isEmpty && bytes.count<=32 && !name.hasPrefix("-") &&
            !name.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)}
    }
    public static func id(_ bytes:Data)->String {
        SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
    public static func id(_ name:String)->String {id(Data(name.utf8))}
}
public enum KnownNetworkState:String,Codable {
    case noTarget,needsValidation,ready,notSaved,unsupportedSecurity,locationUnavailable
    case permissionRequired,powerOff,wrongNetwork,unavailable,locked
}
public struct KnownNetworkStatus:Codable,Equatable {
    public var state:KnownNetworkState,targetID:String?,message:String
    public init(_ state:KnownNetworkState,targetID:String?=nil,_ message:String) {
        self.state=state;self.targetID=targetID;self.message=String(message.prefix(400))
    }
    public var canValidate:Bool {state == .needsValidation || state == .ready || state == .locked}
}
public enum KnownNetworkCommandState:String,Codable {case completed,failed,timedOut,blocked,unconfirmed}
public struct KnownNetworkResult:Codable,Equatable {
    public var state:KnownNetworkCommandState,began:Bool,reaped:Bool,exitCode:Int32?,error:Fault?
    public init(_ state:KnownNetworkCommandState,began:Bool=false,reaped:Bool=true,exitCode:Int32?=nil,error:Fault?=nil) {
        self.state=state;self.began=began;self.reaped=reaped;self.exitCode=exitCode;self.error=error
    }
    /// An accepted CLI request is not evidence of association or connectivity.
    public var commandCompleted:Bool {state == .completed && began && reaped && exitCode == 0}
}
@MainActor public protocol KnownNetworkPort:AnyObject {
    func knownNetworkStatus(_ settings:Settings,interface:String) async ->KnownNetworkStatus
    func joinKnownNetwork(_ settings:Settings,interface:String,validation:Bool) async ->KnownNetworkResult
    func completeKnownNetwork(_ settings:Settings,interface:String,verified:Bool) async
    func invalidateKnownNetwork()
}
public extension KnownNetworkPort {
    func knownNetworkStatus(_ settings:Settings,interface:String) async ->KnownNetworkStatus {
        KnownNetworkStatus(.unavailable,"此执行器没有已保存网络重联能力；未发送关联命令")
    }
    func joinKnownNetwork(_ settings:Settings,interface:String,validation:Bool) async ->KnownNetworkResult {
        KnownNetworkResult(.blocked,error:Fault("WiFiSentinel.KnownNetwork",1,"未发送关联命令"))
    }
    func completeKnownNetwork(_ settings:Settings,interface:String,verified:Bool) async {}
    func invalidateKnownNetwork() {}
}
