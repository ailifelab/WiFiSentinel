import Foundation
import RecoveryCore

final class WebPulse: NSObject,URLSessionDataDelegate,@unchecked Sendable {
    private let lock=NSLock();private var continuation:CheckedContinuation<Signal,Never>?
    private var session:URLSession?,task:URLSessionDataTask?,deadline:DispatchWorkItem?,finished=false
    static func probe(_ url: URL) async -> Signal {await WebPulse().run(url)}
    static func nonSuccessStatus(_ status:Int)->Signal? {
        if (200...299).contains(status){return nil}
        return (300...399).contains(status) ? .portal:.httpError
    }
    static func errorSignal(_ error:NSError?)->Signal {
        guard let e=error,e.domain==NSURLErrorDomain else{return .unknown}
        if e.code==NSURLErrorTimedOut{return .timeout}
        if [NSURLErrorCannotFindHost,NSURLErrorDNSLookupFailed].contains(e.code){return .dnsFailure}
        if [NSURLErrorSecureConnectionFailed,NSURLErrorServerCertificateUntrusted,NSURLErrorServerCertificateHasBadDate,NSURLErrorServerCertificateHasUnknownRoot,NSURLErrorServerCertificateNotYetValid,NSURLErrorClientCertificateRejected].contains(e.code){return .tlsFailure}
        if e.code==NSURLErrorUserAuthenticationRequired{return .permissionDenied}
        if e.code==NSURLErrorCannotConnectToHost{return .refused}
        return .unknown
    }
    func run(_ url: URL) async -> Signal {
        await withCheckedContinuation {c in
            lock.lock();continuation=c;lock.unlock()
            let config=URLSessionConfiguration.ephemeral;config.urlCache=nil;config.httpCookieStorage=nil
            config.urlCredentialStorage=nil;config.httpShouldSetCookies=false;config.timeoutIntervalForRequest=2;config.timeoutIntervalForResource=2
            let session=URLSession(configuration:config,delegate:self,delegateQueue:nil);self.session=session
            var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:2)
            request.setValue("bytes=0-0",forHTTPHeaderField:"Range");request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
            let task=session.dataTask(with:request);self.task=task
            let item=DispatchWorkItem{[weak self] in self?.complete(.timeout)};deadline=item
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+2,execute:item);task.resume()
        }
    }
    private func complete(_ result: Signal) {
        lock.lock();guard !finished else{lock.unlock();return};finished=true
        let c=continuation;continuation=nil;let s=session,t=task,d=deadline;session=nil;task=nil;deadline=nil;lock.unlock()
        d?.cancel();t?.cancel();s?.invalidateAndCancel();c?.resume(returning:result)
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive response: URLResponse,
                    completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
        guard let http=response as? HTTPURLResponse else{completionHandler(.cancel);complete(.unknown);return}
        if let outcome=Self.nonSuccessStatus(http.statusCode){completionHandler(.cancel);complete(outcome);return}
        if response.expectedContentLength==0 || http.statusCode==204 {completionHandler(.cancel);complete(.response)}
        else {completionHandler(.allow)}
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive data: Data) {if !data.isEmpty{complete(.response)}}
    func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: Error?) {
        complete(Self.errorSignal(error as NSError?))
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,completionHandler:@escaping(URLRequest?)->Void) {completionHandler(nil);complete(.portal)}
    func urlSession(_ session: URLSession,task: URLSessionTask,didReceive challenge: URLAuthenticationChallenge,
                    completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust ? .performDefaultHandling:.cancelAuthenticationChallenge,nil)
    }
}
