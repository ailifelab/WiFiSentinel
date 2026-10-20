import Foundation
import CoreLocation
import CoreWLAN
import Combine
import RecoveryCore

@MainActor final class LocationAccess:NSObject,ObservableObject,CLLocationManagerDelegate {
    @Published private(set) var status:CLAuthorizationStatus
    @Published private(set) var requested=false
    @Published private(set) var message=""
    var onChange:(()->Void)?
    private let manager=CLLocationManager()
    override init(){status=manager.authorizationStatus;super.init();manager.delegate=self;refresh()}
    static func mayRequest(descriptionPresent:Bool,servicesEnabled:Bool,status:CLAuthorizationStatus,requested:Bool,existingAuthorizationOnly:Bool=false)->Bool {
        descriptionPresent && servicesEnabled && status == .notDetermined && !requested && !existingAuthorizationOnly
    }
    var granted:Bool {status == .authorizedAlways && CLLocationManager.locationServicesEnabled()}
    func request(existingAuthorizationOnly:Bool=false){
        refresh()
        guard Self.mayRequest(descriptionPresent:Bundle.main.object(forInfoDictionaryKey:"NSLocationUsageDescription") is String,
            servicesEnabled:CLLocationManager.locationServicesEnabled(),status:status,requested:requested,existingAuthorizationOnly:existingAuthorizationOnly) else{return}
        requested=true;message="已向 macOS 请求定位授权；系统弹窗须由用户确认"
        manager.requestWhenInUseAuthorization();onChange?()
    }
    private func refresh(){
        status=manager.authorizationStatus
        if !CLLocationManager.locationServicesEnabled(){message="系统定位服务关闭；请由用户在系统设置中启用"}
        else{switch status {
        case .notDetermined:message=requested ? "等待用户处理 macOS 定位授权弹窗":"尚未请求定位授权"
        case .authorizedAlways:message="定位授权已允许；仅用于核对当前 Wi-Fi 名称"
        case .denied:message="定位授权已拒绝；不会重复弹窗，请由用户在系统设置修改"
        case .restricted:message="定位权限受系统策略限制；不请求绕过"
        default:message="当前定位授权状态不支持核对；停止"
        }}
        onChange?()
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager:CLLocationManager){Task{@MainActor [weak self] in self?.refresh()}}
}

struct CurrentSavedNetwork:Codable,Equatable {
    let interface:String,ssid:String,networkID:String,security:Int
    @MainActor static func read() throws ->CurrentSavedNetwork {
        guard NativeKnownNetworkAdapter.existingLocationAllowed() else{throw Fault("WiFiSentinel.Location",1,"定位未授权，不能读取实际SSID")}
        guard let device=NativeHelper.interface(),device.powerOn(),let name=device.interfaceName,
              let data=device.ssidData(),let ssid=device.ssid(),KnownNetwork.validName(ssid),data==Data(ssid.utf8) else {
            throw Fault("WiFiSentinel.CurrentNetwork",2,"当前实际SSID或唯一无线接口不可可靠读取；不从历史网络猜测")
        }
        guard let config=device.configuration() else{throw Fault("WiFiSentinel.CurrentNetwork",3,"系统已保存网络元数据不可读")}
        let matching=config.networkProfiles.array.compactMap{$0 as? CWNetworkProfile}.filter{$0.ssidData==data}
        let security=Set(matching.map{Int($0.security.rawValue)})
        guard !matching.isEmpty,security.count==1,let actual=security.first else{throw Fault("WiFiSentinel.CurrentNetwork",4,"当前SSID不能与唯一明确的已保存网络安全类型匹配")}
        return CurrentSavedNetwork(interface:name,ssid:ssid,networkID:KnownNetwork.id(data),security:actual)
    }
}
