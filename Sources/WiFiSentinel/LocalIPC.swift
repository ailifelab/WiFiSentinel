import Foundation
import Darwin

enum LocalIPC {
    static func prepare(){signal(SIGPIPE,SIG_IGN)}
    static func emit<T:Encodable>(_ value:T){
        guard let data=try?JSONEncoder().encode(value) else{return}
        let line=data+Data([10]);line.withUnsafeBytes{buffer in
            var offset=0
            while offset<buffer.count{let n=Darwin.write(STDOUT_FILENO,buffer.baseAddress!.advanced(by:offset),buffer.count-offset);if n<=0{break};offset += n}
        }
    }
}
final class LocalCancellation:@unchecked Sendable {
    private let lock=NSLock();private var value=false;private var sources:[DispatchSourceSignal]=[]
    func cancel(){lock.lock();value=true;lock.unlock()}
    var cancelled:Bool{lock.lock();defer{lock.unlock()};return value}
    func install(){
        for number in [SIGTERM,SIGINT,SIGHUP]{
            signal(number,SIG_IGN);let source=DispatchSource.makeSignalSource(signal:number,queue:.global(qos:.utility))
            source.setEventHandler{[weak self] in self?.cancel()};source.resume();sources.append(source)
        }
    }
}
