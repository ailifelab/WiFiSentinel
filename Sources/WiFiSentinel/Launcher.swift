import AppKit
import SwiftUI
import ScreenCaptureKit
import Combine

@main struct Launcher {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().contains(where:{["--sample","--power","--radio","--cycle"].contains($0)}) {
            Task.detached{_=await NativeHelper.runIfRequested();exit(0)};dispatchMain()
        }
        if let index=CommandLine.arguments.firstIndex(of:"--known-network-session"),CommandLine.arguments.indices.contains(index+1) {
            let directory=URL(fileURLWithPath:CommandLine.arguments[index+1]).standardizedFileURL
            guard directory.path.hasPrefix("/tmp/WiFiSentinel-location-validation-"),FileManager.default.fileExists(atPath:directory.path) else{exit(2)}
            let app=NSApplication.shared,session=KnownNetworkSession(directory:directory)
            app.delegate=session;app.setActivationPolicy(.regular);app.run();withExtendedLifetime(session){};return
        }
        let app=NSApplication.shared,delegate=AppDelegate()
        app.delegate=delegate;app.setActivationPolicy(.accessory);app.run();withExtendedLifetime(delegate){}
    }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    private var model:AppModel!,window:NSWindow!,status:NSStatusItem!,lock:Int32 = -1
    private var terminating=false
    private var previewScale:CGFloat=1
    private var subscriptions=Set<AnyCancellable>()
    func applicationDidFinishLaunching(_ notification:Notification) {
        let args=CommandLine.arguments,preview=args.contains("--ui-proof")
        if !preview {
            let path=NSTemporaryDirectory()+"local.WiFiSentinel.rewrite.instance.lock"
            lock=Darwin.open(path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
            guard lock>=0,flock(lock,LOCK_EX|LOCK_NB)==0 else{exit(1)}
        }
        model=AppModel(preview:preview)
        let scale:CGFloat=args.contains("--large-ui") ? 1.2:1.0
        previewScale=scale
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:800),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        if preview && args.contains("--compact-ui") {window.setFrame(NSRect(x:0,y:0,width:1040,height:780),display:false)}
        window.minSize=NSSize(width:1040,height:780);window.title=preview ? "WiFiSentinel · 界面预览（无硬件操作）":"WiFi 哨兵 · WiFiSentinel"
        window.contentView=NSHostingView(rootView:WindowView(model:model,scale:scale));window.isReleasedWhenClosed=false;window.center();show()
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        if let button=status.button {
            button.title="";button.image=StatusIcon.makeImage();button.imagePosition = .imageOnly
            button.setAccessibilityLabel(StatusIcon.accessibilityName)
            model.engine.$reason.sink{[weak button] reason in button?.toolTip="WiFi 哨兵\n\(reason)"}.store(in:&subscriptions)
        }
        let menu=NSMenu();add("打开 WiFi 哨兵",#selector(show),to:menu);add("检测并按策略处理",#selector(inspect),to:menu)
        add("暂停／继续",#selector(pause),to:menu)
        let automaticItem=NSMenuItem(title:"启用本次自动恢复…",action:#selector(automatic),keyEquivalent:"");automaticItem.target=self;automaticItem.isEnabled = !preview;menu.addItem(automaticItem)
        model.engine.$automatic.sink{enabled in automaticItem.state=enabled ? .on:.off;automaticItem.title=enabled ? "关闭本次自动恢复":"启用本次自动恢复…"}.store(in:&subscriptions)
        menu.addItem(.separator());add("退出 WiFi 哨兵",#selector(quit),to:menu);status.menu=menu
        model.start()
        if preview,let i=args.firstIndex(of:"--ui-proof"),args.indices.contains(i+1) {proof(directory:URL(fileURLWithPath:args[i+1]),index:0)}
    }
    private func add(_ title:String,_ action:Selector,to menu:NSMenu){let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)}
    @objc private func show(){NSApp.activate(ignoringOtherApps:true);window?.makeKeyAndOrderFront(nil)}
    @objc private func inspect(){model.engine.request(.manual)}
    @objc private func pause(){model.toggleMonitoring()}
    @objc private func automatic(){model.automatic(!model.engine.automatic)}
    @objc private func quit(){CFRunLoopPerformBlock(CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue){NSApp.terminate(nil)};CFRunLoopWakeUp(CFRunLoopGetMain())}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{show();return true}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        guard !terminating else{return .terminateLater};terminating=true
        Task{@MainActor in
            let safe=await model.shutdown()
            if safe {sender.reply(toApplicationShouldTerminate:true)} else {
                let alert=NSAlert();alert.messageText="Wi-Fi 重新开启仍未确认";alert.informativeText="请先在系统 Wi-Fi 菜单检查并手动打开；软件不会再发送关闭命令。如果仍退出，Wi-Fi可能保持关闭。"
                alert.addButton(withTitle:"留在应用中");alert.addButton(withTitle:"已知风险，仍退出")
                let leave=alert.runModal() == .alertSecondButtonReturn
                terminating=false;if !leave {model.engine.cancelShutdown()};sender.reply(toApplicationShouldTerminate:leave)
            }
        };return .terminateLater
    }
    private func proof(directory:URL,index:Int){
        guard model.preview else{exit(6)}
        let pages=[(0,0,"status"),(1,0,"parameters"),(1,1,"policy"),(2,0,"logs"),(3,0,"diagnostics")]
        let (tab,settingsPage,name)=pages[index]
        model.tab=tab;model.settingsPage=settingsPage
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35){[self] in
          Task{@MainActor in
            guard let view=window.contentView else{exit(2)};view.layoutSubtreeIfNeeded()
            do{
                guard #available(macOS 14.4,*) else{exit(3)}
                let own=try await SCShareableContent.currentProcess
                guard let target=own.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber) && $0.owningApplication?.processID==ProcessInfo.processInfo.processIdentifier}) else{exit(3)}
                let filter=SCContentFilter(desktopIndependentWindow:target),config=SCStreamConfiguration()
                config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
                let pixels=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
                let bitmap=NSBitmapImageRep(cgImage:pixels)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("page-\(name).png"))
                var scrollViews=0
                @MainActor func count(_ node:NSView){if let scroll=node as? NSScrollView,scroll.hasVerticalScroller {scrollViews += 1};for child in node.subviews{count(child)}}
                count(view)
                let audit:[String:Any]=["tab":tab,"settingsPage":settingsPage,"page":name,"automatic":model.engine.automatic,"internetTrialSelected":model.engine.settings.internetTrial,"verticalScrollViews":scrollViews,"windowWidth":window.frame.width,"windowHeight":window.frame.height,"contentWidth":view.frame.width,"contentHeight":view.frame.height,"fittingHeight":view.fittingSize.height,"fontScale":previewScale,"hardwareBackend":false,"runtimeSnapshot":(try?JSONSerialization.jsonObject(with:JSONEncoder().encode(model.engine.runtimeSnapshot()))) ?? NSNull(),"renderMethod":"ScreenCaptureKit.currentProcess own window only; NSView scroll inspection","capturedPID":ProcessInfo.processInfo.processIdentifier]
                try JSONSerialization.data(withJSONObject:audit,options:[.sortedKeys]).write(to:directory.appendingPathComponent("page-\(name)-audit.json"))
                guard scrollViews==0 else{exit(5)}
                if index+1<pages.count {proof(directory:directory,index:index+1)}else{exit(0)}
            }catch{fputs("Own window proof failed: \(error)\n",stderr);exit(4)}
          }
        }
    }
}
