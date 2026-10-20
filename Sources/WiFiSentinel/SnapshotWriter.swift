import Foundation
import RecoveryCore

/// Overwrite one bounded snapshot; coalesce rapid phase changes to at most1Hz.
@MainActor final class SnapshotWriter {
    let store:Store
    private var last = -Double.infinity,pending:RuntimeSnapshot?,task:Task<Void,Never>?
    init(store:Store){self.store=store}
    func submit(_ snapshot:RuntimeSnapshot){
        pending=snapshot
        let delay=max(0,1-(Monotonic.now-last))
        if delay==0{task?.cancel();task=nil;flush();return}
        guard task==nil else{return}
        task=Task{[weak self] in try?await Task.sleep(nanoseconds:UInt64(delay*1e9));guard !Task.isCancelled else{return};self?.task=nil;self?.flush()}
    }
    private func flush(){guard let value=pending else{return};pending=nil;_=store.writeRuntimeSnapshot(value);last=Monotonic.now}
}
