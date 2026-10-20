import Foundation
import RecoveryCore

@MainActor final class Store {
    let directory: URL
    private(set) var failure: String?
    init(directory: URL) {self.directory=directory}
    func load()->Settings {
        guard let data=try?Data(contentsOf:directory.appendingPathComponent("settings-v1.json")),data.count<=8192,
              let settings=try?JSONDecoder().decode(Settings.self,from:data),settings.validation==nil else{return Settings()}
        return settings
    }
    func save(_ settings: Settings) throws {
        try prepare();try JSONEncoder().encode(settings).write(to:directory.appendingPathComponent("settings-v1.json"),options:.atomic)
    }
    func loadTrialLatch()->TrialLatch {
        let path=directory.appendingPathComponent("trial-latch-v1.json")
        let linked=(try?path.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink)==true
        if !FileManager.default.fileExists(atPath:path.path) && !linked {return TrialLatch()}
        do {
            let data=try readRegular(path)
            guard data.count<=2048 else{throw Fault("WiFiSentinel.Storage",4,"故障锁过大")}
            let value=try JSONDecoder().decode(TrialLatch.self,from:data)
            guard value.valid else{throw Fault("WiFiSentinel.Storage",4,"故障锁无效")};return value
        }catch{
            failure="故障锁无法核验；保持自动试探锁定"
            var blocked=TrialLatch();blocked.consumed=true;blocked.notBeforeWall=Date().timeIntervalSince1970+1800;blocked.lastResult="storage-unverified";return blocked
        }
    }
    func saveTrialLatch(_ state:TrialLatch)->Bool {
        do {
            guard state.valid else{return false};try prepare()
            let path=directory.appendingPathComponent("trial-latch-v1.json");try ensureRegular(path)
            let data=try JSONEncoder().encode(state);guard data.count<=2048 else{return false}
            try data.write(to:path,options:.atomic);return true
        }catch{failure="故障锁保存失败：\((error as NSError).domain) [\((error as NSError).code)]";return false}
    }
    func loadAutomaticState()->AutomaticState {
        let path=directory.appendingPathComponent("retry-policy-v3.json")
        if existsIncludingLink(path) {
            do {let data=try readRegular(path);guard data.count<=8192 else{throw Fault("Storage",3,"状态过大")}
                let value=try JSONDecoder().decode(AutomaticState.self,from:data);guard value.valid else{throw Fault("Storage",4,"状态无效")};return value
            }catch{failure="重试状态不可核验，先冷却30分钟";return AutomaticState.upgrade(legacy:nil,unverified:true)}
        }
        let legacy=directory.appendingPathComponent("trial-latch-v1.json")
        if existsIncludingLink(legacy) {return AutomaticState.upgrade(legacy:loadTrialLatch())}
        return AutomaticState()
    }
    func saveAutomaticState(_ value:AutomaticState)->Bool {
        do {guard value.valid else{return false};try prepare();let path=directory.appendingPathComponent("retry-policy-v3.json");try ensureRegular(path)
            let data=try JSONEncoder().encode(value);guard data.count<=8192 else{return false}
            try data.write(to:path,options:.atomic);let file=try FileHandle(forWritingTo:path);try file.synchronize();try file.close();return true
        }catch{failure="重试状态保存失败：\((error as NSError).domain) [\((error as NSError).code)]";return false}
    }
    func writeRuntimeSnapshot(_ value:RuntimeSnapshot)->Bool {
        do {try prepare();let path=directory.appendingPathComponent("runtime-snapshot-v3.json");try ensureRegular(path)
            let data=try JSONEncoder().encode(value);guard data.count<=16384 else{return false};try data.write(to:path,options:.atomic);return true
        }catch{failure="运行状态快照保存失败：\((error as NSError).domain) [\((error as NSError).code)]";return false}
    }
    private func prepare() throws {
        if FileManager.default.fileExists(atPath:directory.path) {
            let values=try directory.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey])
            guard values.isSymbolicLink != true,values.isDirectory==true else {throw Fault("WiFiSentinel.Storage",1,"数据目录不是普通自有目录")}
        } else {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
    }
    func append(_ event: Event) {
        do {
            try prepare();let current=directory.appendingPathComponent("events.jsonl"),previous=directory.appendingPathComponent("events.previous.jsonl")
            var data=try readRegular(current)
            let line=try JSONEncoder().encode(event)+Data([10])
            if data.count+line.count>131072 {try ensureRegular(previous);try data.write(to:previous,options:.atomic);data=Data()}
            data.append(line);try data.write(to:current,options:.atomic);failure=nil
        } catch {failure="日志保存失败：\((error as NSError).domain) [\((error as NSError).code)]"}
    }
    private func existsIncludingLink(_ path:URL)->Bool {
        FileManager.default.fileExists(atPath:path.path) || (try?FileManager.default.destinationOfSymbolicLink(atPath:path.path)) != nil
    }
    private func ensureRegular(_ path: URL) throws {
        if existsIncludingLink(path) {
            let v=try path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard v.isRegularFile==true,v.isSymbolicLink != true else {throw Fault("WiFiSentinel.Storage",2,"拒绝符号链接或非普通文件")}
        }
    }
    private func readRegular(_ path: URL) throws -> Data {
        try ensureRegular(path);guard FileManager.default.fileExists(atPath:path.path) else{return Data()}
        let attrs=try FileManager.default.attributesOfItem(atPath:path.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 131072 else {throw Fault("WiFiSentinel.Storage",3,"日志超出上限；请确认清理")}
        return try Data(contentsOf:path)
    }
    func history()->[Event] {
        ["events.previous.jsonl","events.jsonl"].flatMap{name->[Event] in
            guard let data=try?readRegular(directory.appendingPathComponent(name)) else{return []}
            return data.split(separator:10).compactMap{try?JSONDecoder().decode(Event.self,from:Data($0))}
        }.suffix(200).map{$0}
    }
    func clearLogs() throws {
        try prepare()
        for name in ["events.jsonl","events.previous.jsonl"] {let path=directory.appendingPathComponent(name);try ensureRegular(path);if existsIncludingLink(path) {try FileManager.default.removeItem(at:path)}}
    }
    var logBytes: Int { ["events.jsonl","events.previous.jsonl"].reduce(0){sum,name in sum+((try?FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? 0)} }
}
