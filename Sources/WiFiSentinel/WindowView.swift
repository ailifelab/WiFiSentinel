import SwiftUI
import RecoveryCore

struct WindowView: View {
    @ObservedObject var model:AppModel
    @ObservedObject var engine:Coordinator
    let scale:CGFloat
    init(model:AppModel,scale:CGFloat=1){self.model=model;engine=model.engine;self.scale=scale}
    var body:some View {
        GeometryReader { bounds in
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.firstTextBaseline) {
                VStack(alignment:.leading,spacing:5){Text("WiFi 哨兵").font(.system(size:26*scale,weight:.semibold));Text(model.preview ? "界面预览 · 无硬件操作":"本地检测与有限恢复 · 已保存网络须单次验证").foregroundStyle(.secondary)}
                Spacer();Text(engine.automatic ? "本次自动恢复：已启用":"本次自动恢复：关闭").foregroundStyle(engine.automatic ? .orange:.secondary)
            }
            Divider()
            HStack(spacing:10) {
                ForEach(Array(["状态与操作","检测设置","异常日志","执行与权限"].enumerated()),id:\.offset){index,label in
                    Button{model.tab=index}label:{Text(label).fontWeight(model.tab==index ? .semibold:.regular).padding(.horizontal,20).padding(.vertical,10)
                        .background(model.tab==index ? Color.accentColor.opacity(0.16):Color.clear).clipShape(RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)
                }
                Spacer()
            }
            Group {
                switch model.tab {case 1:settings;case 2:logs;case 3:diagnostics;default:status}
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            HStack{Text(model.notice.isEmpty ? "版本 0.1 · 重写版5.3　|　默认60秒　|　日志最多256 KiB":model.notice).lineLimit(1);Spacer();Button("导出完整诊断…"){model.export()}.disabled(engine.busy)}
                .foregroundStyle(.secondary)
        }.font(.system(size:14*scale)).padding(22)
            .frame(width:bounds.size.width,height:bounds.size.height,alignment:.topLeading)
        }.frame(minWidth:1000,minHeight:700)
            .sheet(item:Binding(get:{model.detail.map{Detail(value:$0)}},set:{model.detail=$0?.value})){detail in DetailView(text:detail.value,scale:scale)}
    }
    private var status:some View {
        VStack(alignment:.leading,spacing:18) {
            GroupBox("当前结论") {
                VStack(alignment:.leading,spacing:12) {
                    Text(title(engine.phase)).font(.system(size:22*scale,weight:.medium))
                    Text(engine.reason).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
                    if let s=engine.sample {Text("局域网：\(signal(s.local))　业务：\(s.internet.map(signal).joined(separator:" / "))　接口：\(s.link.interface.isEmpty ? "未知":s.link.interface)").foregroundStyle(.secondary).lineLimit(2)}
                    Button("查看完整原因"){model.detail=engine.reason}
                }.padding(10).frame(maxWidth:.infinity,minHeight:130,alignment:.topLeading)
            }
            HStack(spacing:20) {
                metric(engine.settings.internetTrial ? "持续超时复核":"失败复核", "\(engine.settings.internetTrial ? engine.trialSnapshot.failureRounds:engine.failures) / 3")
                metric("本轮自动失败", "\(engine.automaticState.failures) / 2")
                metric("自动 / 手动次数", "\(engine.automaticAttempts) / \(engine.manualAttempts)")
            }
            HStack(spacing:14) {
                Button(engine.busy ? "检测／复核进行中（点击合并）":"检测并按策略处理"){engine.request(.manual)}.accessibilityIdentifier("inspectNetwork")
                Button(engine.monitoring ? "暂停监测":"继续监测"){model.toggleMonitoring()}
                Spacer();Button("一键重联 Wi-Fi…"){model.repairOnce()}.fixedSize().disabled(engine.busy || model.preview).accessibilityIdentifier("repairOnce")
            }
            Toggle("允许本次启动自动恢复",isOn:Binding(get:{engine.automatic},set:{model.automatic($0)})).disabled(model.preview || (engine.busy && !engine.automatic)).accessibilityIdentifier("automaticRecovery")
            Text(engine.availability.text).foregroundStyle(engine.automatic ? .orange:.secondary).lineLimit(2)
            if let next=engine.availability.estimatedRetryWall {Text("最早重新判定：\(Date(timeIntervalSince1970:next).formatted(date:.omitted,time:.standard))；睡眠顺延，仍须新鲜故障证据").foregroundStyle(.secondary).lineLimit(2)}
            Text(engine.repair.map{"最近一次恢复："+$0.verificationSummary} ?? (engine.settings.internetTrial ? "已选择循环试探：上游／VPN故障也可能触发；两次验证失败后冷却30分钟再判定。一键重联仍需确认。":"保守策略：LAN仍响应时不自动关开；可选择上网异常循环恢复，或另行确认一键重联。")).foregroundStyle(Color.secondary).lineLimit(3)
            Spacer(minLength:0)
        }.padding(18)
    }
    private func metric(_ label:String,_ value:String)->some View {GroupBox(label){Text(value).font(.system(size:22*scale,weight:.medium)).frame(maxWidth:.infinity).padding(8)}}
    private var settings:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:14){
                Button("检测参数"){model.settingsPage=0}.buttonStyle(.bordered)
                Button("自动恢复策略"){model.settingsPage=1}.buttonStyle(.bordered)
                Spacer();Text(model.settingsPage==0 ? "参数页":"策略页").foregroundStyle(.secondary)
            }
            if model.settingsPage==0 {
                Text("检测参数").font(.system(size:22*scale,weight:.medium))
                HStack{Text("检测间隔（秒）").frame(width:190,alignment:.leading);TextField("60",value:$model.draft.interval,formatter:Self.number).frame(width:140);Text("30–3600；默认60秒").foregroundStyle(.secondary)}
                HStack{Text("可选业务目标").frame(width:190,alignment:.leading);TextField("留空使用默认 HTTPS 地址",text:$model.draft.customURL)}
                HStack{Text("已保存网络名称（可选）").frame(width:190,alignment:.leading);TextField("须与系统已保存名称完全一致",text:$model.draft.knownNetworkSSID)}
                HStack{Button("授权并读取当前 Wi-Fi 名称…"){model.authorizeCurrentNetwork()}.disabled(engine.busy || model.preview);Text("系统定位弹窗由用户确认；只采用当前实际连接且已保存的网络").foregroundStyle(.secondary).lineLimit(2)}
                HStack{Button("单次验证已保存网络重联…"){model.validateKnownNetwork()}.disabled(engine.busy || model.preview);Text(engine.knownNetworkStatus.message).foregroundStyle(.secondary).lineLimit(2)}
                Text("不取密码，不弹窗提权。须现有权限能核对SSID及保存项；单次验证通过后才供本次运行自动重联。未关联且无可用目标时不反复关开。").foregroundStyle(.secondary).lineLimit(3)
                Text("两个独立目标交叉核对；单站、门户、HTTP拒绝、DNS/TLS和权限错误不默认触发试探。").foregroundStyle(.secondary).lineLimit(3)
                HStack{Text("明确的网关 TCP 端口").frame(width:190,alignment:.leading);TextField("0",value:$model.draft.localTCPPort,formatter:Self.number).frame(width:140);Text("0仅用 Ping；不猜端口、不扫描").foregroundStyle(.secondary)}
            } else {
                Text("自动恢复策略").font(.system(size:22*scale,weight:.medium))
                Toggle("上网异常循环恢复（默认关闭）",isOn:$model.draft.internetTrial)
                Text("每次关开前均须双目标3轮且至少120秒超时，LAN正常不否决。上游／VPN故障也可能触发；两次间完整等待系统重联和业务验证。").lineLimit(4)
                Text("本轮连续失败2次后冷却30分钟，到期检测仍符合条件才开新轮。验证联网成功或可信自然恢复清零；计数和冷却跨重启保存，睡眠不抵扣。").foregroundStyle(.secondary).lineLimit(4)
                Text(engine.automatic && engine.settings.internetTrial ? "当前：总开关已确认，此策略已选择":"当前：此策略未生效或总恢复开关关闭").foregroundStyle(.secondary).lineLimit(2)
                HStack{Text("手动修复间隔（秒）").frame(width:190,alignment:.leading);TextField("300",value:$model.draft.cooldown,formatter:Self.number).frame(width:140);Text("60–3600；自动两次失败固定1800").foregroundStyle(.secondary)}
                Text("自动无每启动总配额；手动独立计数，双方串行互斥。开启未确认时暂停自动执行并提示人工检查。").foregroundStyle(.secondary).lineLimit(3)
            }
            HStack{Button("保存设置"){model.save()}.disabled(engine.busy);Text("保存策略不会继承总恢复许可。").foregroundStyle(.secondary)}
            Spacer(minLength:0)
        }.padding(22)
    }
    private var logs:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack{Text("只记录异常、恢复阶段与错误").font(.system(size:20*scale,weight:.medium));Spacer();Button("清理日志…"){model.clearLogs()}.disabled(model.preview || engine.busy)}
            Text("每页5条；长内容在详情中翻页或导出。当前磁盘日志 \(model.store.logBytes) 字节。").foregroundStyle(.secondary)
            Divider()
            ForEach(model.pageEvents){entry in
                HStack(alignment:.top,spacing:14) {
                    Text(entry.time.formatted(date:.omitted,time:.standard)).monospacedDigit().frame(width:90,alignment:.leading)
                    Text(entry.message).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                    Button("详情"){model.detail=entry.message}
                }.frame(height:42*scale,alignment:.top)
            }
            Spacer(minLength:0)
            HStack{Button("上一页"){model.page=max(0,model.page-1)}.disabled(model.page==0);Text("第 \(min(model.page+1,model.pageCount)) / \(model.pageCount) 页");Button("下一页"){model.page=min(model.pageCount-1,model.page+1)}.disabled(model.page+1>=model.pageCount);Spacer();Text("最多保留最近200条供分页查看").foregroundStyle(.secondary)}
        }.padding(18)
    }
    private var diagnostics:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("执行器与系统权限").font(.system(size:22*scale,weight:.medium))
            GroupBox("最近一次执行") {
                VStack(alignment:.leading,spacing:10) {
                    Text(engine.repair.map{"尝试 \($0.attempt)：\($0.reason)"} ?? "尚未执行任何关开命令").lineLimit(3)
                    Text("重新开启责任：\(engine.needsRestore ? "未完成，请处理":"无未完成责任")").foregroundStyle(engine.needsRestore ? .red:.secondary)
                    if let r=engine.repair {Text("电源：\(r.finalPower.rawValue)；本地验证：\(r.localVerified ? "通过":"未通过")；业务验证：\(r.internetVerified ? "通过":"未通过")").lineLimit(2)}
                    if let r=engine.repair{Text(r.verificationSummary).foregroundStyle(r.internetVerified ? Color.green:Color.orange).lineLimit(2)}
                    Text(engine.repair?.error?.description ?? (engine.repair == nil ? "尚未执行控制命令；实际权限未验证":"没有记录控制API错误；联网结果以关联和本地、双业务验证为准")).lineLimit(3)
                    Button("完整执行详情"){model.detail=engine.repair.map{String(decoding:(try?JSONEncoder().encode($0)) ?? Data(),as:UTF8.self)} ?? "未执行；实际系统控制能力待单独确认后测试"}
                }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
            }
            Text("独立本地事务持有关闭和开启清理责任；单命令6秒。取消／超时先给开启清理留出期限。系统错误原样保留，不提权、不安装后台服务。").lineLimit(4)
            Text("Wi-Fi 开启后先等系统加入；仍未关联时，仅对用户选择且本次运行已验证的已保存目标请求一次重联。不收集密码；需要新增权限时停止。命令、实际关联和连通分别验证。").foregroundStyle(.secondary).lineLimit(3)
            Text(model.store.failure ?? "日志为两份128 KiB文件；健康检测不追加事件；独立状态快照持续更新，不保存网页缓存或正文。").foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength:0)
        }.padding(20)
    }
    private static var number:NumberFormatter {let f=NumberFormatter();f.numberStyle = .decimal;f.maximumFractionDigits=0;return f}
    private func signal(_ value:Signal)->String {switch value{case .response:return "有响应";case .timeout:return "超时";case .unknown:return "未知";case .portal:return "重定向／门户";case .httpError:return "HTTP拒绝／错误";case .dnsFailure:return "DNS失败";case .tlsFailure:return "TLS失败";case .permissionDenied:return "权限受限";case .refused:return "连接拒绝"}}
    private func title(_ phase:Phase)->String {
        switch phase {case .idle:return "等待／检测正常";case .checking:return "检测中";case .confirming:return "确认持续故障";case .blocked:return "本次未恢复";case .poweringOff:return "本地关开事务执行中";case .restoringOn:return "重新开启 Wi-Fi";case .joining:return "请求已保存网络重联";case .verifying:return "验证重新联网";case .recovered:return "恢复已验证";case .attention:return "需要处理"}
    }
}
private struct Detail:Identifiable {let value:String;var id:String{value}}
private final class DetailPager:ObservableObject {@Published var page=0}
private struct DetailView:View {
    let text:String,scale:CGFloat
    @StateObject private var pager=DetailPager()
    @Environment(\.dismiss) private var dismiss
    private var chunks:[String] {let a=Array(text);return stride(from:0,to:max(1,a.count),by:350).map{String(a.dropFirst($0).prefix(350))}}
    var body:some View {VStack(alignment:.leading,spacing:18){Text("完整详情").font(.system(size:22*scale,weight:.medium));Text(chunks[min(pager.page,chunks.count-1)]).font(.system(size:15*scale)).textSelection(.enabled).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading);HStack{Button("上一页"){pager.page=max(0,pager.page-1)}.disabled(pager.page==0);Text("\(pager.page+1) / \(chunks.count)");Button("下一页"){pager.page=min(chunks.count-1,pager.page+1)}.disabled(pager.page+1==chunks.count);Spacer();Button("关闭"){dismiss()}}}.padding(24).frame(width:760,height:460)}
}
