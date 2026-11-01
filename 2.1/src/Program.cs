using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.NetworkInformation;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace NetWatcher
{
    public static class Startup
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string ValueName = "NetWatcher2.1";

        public static string ExePath()
        {
            return System.Reflection.Assembly.GetExecutingAssembly().Location;
        }

        public static bool IsEnabled()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey, false))
                {
                    if (k == null) return false;
                    return k.GetValue(ValueName) != null;
                }
            }
            catch { return false; }
        }

        public static void SetEnabled(bool enabled)
        {
            SetEnabled(enabled, "");
        }

        // dataDir 非空时把 --datadir 一起写进自启命令行
        public static void SetEnabled(bool enabled, string dataDir)
        {
            try
            {
                string val = "\"" + ExePath() + "\" --background";
                if (!string.IsNullOrEmpty(dataDir)) val += " --datadir \"" + dataDir + "\"";
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (k == null)
                    {
                        using (RegistryKey k2 = Registry.CurrentUser.CreateSubKey(RunKey))
                        {
                            if (enabled) k2.SetValue(ValueName, val);
                        }
                        return;
                    }
                    if (enabled) k.SetValue(ValueName, val);
                    else k.DeleteValue(ValueName, false);
                }
            }
            catch { }
        }

        // 2.1 修复（P0-3）：自检不能改真实自启项——用临时值名做写入/读取/删除往返测试。
        internal static string SelfTestAutoStart()
        {
            string testName = ValueName + "_SelfTest_" + Process.GetCurrentProcess().Id;
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (k == null) return "注册表不可写（HKCU Run 不存在）";
                    k.SetValue(testName, "\"selftest\" --selftest");
                    bool on = k.GetValue(testName) != null;
                    k.DeleteValue(testName, false);
                    bool off = k.GetValue(testName) != null;   // True=仍存在（期望 False=已删除成功）
                    return "临时值写入后=" + on + " 删除后=" + off + " (期望 True/False)";
                }
            }
            catch (Exception ex) { return "异常: " + ex.Message; }
        }
    }

    static class Program
    {
        static Mutex mutex;

        const string MainWindowTitle = "IP监控2.1 · 网络连接监控 (NetWatcher)";

        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern IntPtr FindWindow(string className, string windowTitle);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern bool IsWindowVisible(IntPtr hWnd);

        [STAThread]
        static void Main(string[] args)
        {
            AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e)
            {
                try
                {
                    File.WriteAllText(Path.Combine(Path.GetTempPath(), "NetWatcher-crash.log"),
                        "Unhandled: " + (e.ExceptionObject == null ? "" : e.ExceptionObject.ToString()));
                }
                catch { }
            };
            try
            {
                string dataDir = "";
                bool background = false;
                bool showRequested = false;
                bool selfTest = false;
                bool autostartOn = false, autostartOff = false;
                int daemonSeconds = 0;
                string mutexTag = "";
                bool quitRequested = false;
                for (int i = 0; i < args.Length; i++)
                {
                    string a = args[i];
                    if (a == "--background" || a == "-b" || a == "--minimized") background = true;
                    else if (a == "--show") { showRequested = true; /* 已有实例则唤出窗口；没有则以可见窗口启动 */ }
                    else if (a == "--selftest" || a == "--test") selfTest = true;
                    else if (a == "--autostart-on") autostartOn = true;
                    else if (a == "--autostart-off") autostartOff = true;
                    else if (a == "--datadir" && i + 1 < args.Length) { dataDir = args[++i]; }
                    else if (a == "--daemon" && i + 1 < args.Length) { int.TryParse(args[++i], out daemonSeconds); }
                    else if (a == "--mutex-tag" && i + 1 < args.Length) { mutexTag = args[++i]; }
                    else if (a == "--quit" || a == "--exit") { quitRequested = true; }
                }

                if (autostartOn) { Startup.SetEnabled(true, dataDir); return; }
                if (autostartOff) { Startup.SetEnabled(false); return; }

                // 2.1.1：--quit / --exit —— 请求已在运行的实例优雅退出（保存数据、移除托盘图标），
                // 便于脚本/自动化测试停掉程序，不必强制结束进程（强杀容易在通知区域留下幽灵图标）。
                if (quitRequested)
                {
                    string qMutex = "NetWatcher2.1_SingleInstance_Mutex";
                    if (!string.IsNullOrEmpty(mutexTag)) qMutex += "_" + mutexTag;
                    try
                    {
                        using (EventWaitHandle qe = EventWaitHandle.OpenExisting(qMutex + "_Quit"))
                        {
                            qe.Set();
                            // 最多等 5 秒，确认主实例已退出（名字对应的 Mutex 内核对象消失）
                            for (int i = 0; i < 50; i++)
                            {
                                try { using (Mutex probe = Mutex.OpenExisting(qMutex)) { Thread.Sleep(100); } }
                                catch { break; }
                            }
                        }
                        return;
                    }
                    catch
                    {
                        Environment.ExitCode = 1;   // 没有正在运行的实例
                        return;
                    }
                }

                AppConfig cfg = AppConfig.Load(dataDir);
                // 2.1 修复（P1-5）：开机自启以注册表实际状态为准（install.ps1 / --autostart-on 不写 config.json）
                try { cfg.AutoStart = Startup.IsEnabled(); } catch { }
                string effectiveDir = cfg.EffectiveDataDir();
                Store.Init(effectiveDir);

                // 2.1 修复（P0-4）：同一数据目录只允许一个写入实例。
                // 注意：GUI 的写锁必须在「单实例唤出」判断之后才抢（见下方），否则第二次双击启动
                // 会先报"数据目录被占用"，把 2.0 时代的"重复双击 = 唤出已有窗口"体验弄坏。
                // --selftest 已改为只读（不写 data\、不改注册表），因此不参与该锁。
                if (daemonSeconds > 0 && !Store.AcquireDataLock())
                {
                    string busy = "数据目录已被另一个 IP监控 实例占用，为避免互相覆盖，本次实例不启动：" + effectiveDir;
                    AppendStartup(effectiveDir, "Program: daemon " + busy + " (lock=" + Store.DataLockName + ")");
                    try
                    {
                        File.AppendAllText(Path.Combine(effectiveDir, "daemon.log"),
                            DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " daemon 放弃启动: " + busy + "\r\n");
                    }
                    catch { }
                    Environment.ExitCode = 2;
                    return;
                }

                GeoIp.Init(effectiveDir, cfg.GeoApi, cfg.GeoEnabled);
                AppendStartup(effectiveDir, "Program: 启动 exe=" + Startup.ExePath() + " 数据目录=" + effectiveDir
                    + " 管理员=" + NativeMethods.IsAdministrator() + " 间隔=" + cfg.ScanIntervalSeconds + "s");

                if (selfTest)
                {
                    RunSelfTest(cfg, effectiveDir);
                    return;
                }

                if (daemonSeconds > 0)
                {
                    Monitor dm = new Monitor(cfg);
                    dm.Start();
                    Thread.Sleep(daemonSeconds * 1000);
                    dm.Stop();
                    DayData d = Store.LoadDay(DateTime.Now.ToString("yyyy-MM-dd"));
                    try
                    {
                        File.AppendAllText(Path.Combine(effectiveDir, "daemon.log"),
                            string.Format("{0} daemon 结束: 采样={1} 总下载={2} 上传={3} IP={4} 进程={5} 精确={6}\r\n",
                                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"), d.sampleCount, d.bytesIn, d.bytesOut,
                                d.ips.Count, d.procs.Count, d.bytesPrecise));
                    }
                    catch { }
                    return;
                }

                // 单实例（--mutex-tag 可让测试实例互不干扰）
                // 第二次启动不再弹「已经在运行」，而是通知第一个实例把窗口显示出来，然后自己退出。
                string mutexName = "NetWatcher2.1_SingleInstance_Mutex";
                if (!string.IsNullOrEmpty(mutexTag)) mutexName += "_" + mutexTag;
                string activateName = mutexName + "_Activate";
                bool createdNew;
                mutex = new Mutex(true, mutexName, out createdNew);
                if (!createdNew)
                {
                    // 已有实例：先通知它显示窗口
                    bool signaled = false;
                    try
                    {
                        using (EventWaitHandle ev = EventWaitHandle.OpenExisting(activateName))
                        {
                            ev.Set();
                            signaled = true;
                        }
                    }
                    catch { }
                    // 最多等 5 秒确认窗口真的出来了（第一个实例 UI 忙时 1.5 秒可能不够）；
                    // 若第一个实例确实卡死，再给出可操作的提示（历史 bug 的兜底）。
                    bool windowShown = false;
                    for (int i = 0; i < 25 && !windowShown; i++)
                    {
                        Thread.Sleep(200);
                        IntPtr h = FindWindow(null, MainWindowTitle);
                        if (h != IntPtr.Zero && IsWindowVisible(h)) windowShown = true;
                    }
                    if (signaled && windowShown) return;
                    try
                    {
                        MessageBox.Show(
                            "检测到 IP监控 已在后台运行，但窗口没有响应。\n\n" +
                            "处理办法：\n" +
                            "1) 打开任务管理器 → 详细信息 → 结束 NetWatcher.exe\n" +
                            "2) 重新双击程序启动\n\n" +
                            "排查日志：数据目录下的 startup.log / crash.log",
                            "IP监控2.1", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                    catch { }
                    return;
                }

                // 2.1 修复（P0-4）：GUI 抢数据目录写锁（放在单实例唤出逻辑之后，保证双击唤出不被误报占用）。
                bool gotGuiDataLock = Store.AcquireDataLock();
                if (!gotGuiDataLock)
                {
                    // 管理员重启/升级时旧实例可能正在退出：最多等 5 秒接管数据目录
                    for (int i = 0; i < 20 && !gotGuiDataLock; i++) { Thread.Sleep(250); gotGuiDataLock = Store.AcquireDataLock(); }
                }
                if (!gotGuiDataLock)
                {
                    string busy = "数据目录已被另一个 IP监控 实例占用，为避免互相覆盖，本次实例不启动：" + effectiveDir;
                    AppendStartup(effectiveDir, "Program: GUI " + busy + " (lock=" + Store.DataLockName + ")");
                    if (!background)
                    {
                        try { MessageBox.Show(busy + "\n\n请先退出另一个实例；测试请用 --datadir 指定独立目录。", "IP监控2.1", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
                        catch { }
                    }
                    Environment.ExitCode = 2;
                    return;
                }

                EventWaitHandle activateEvent = null;
                try { activateEvent = new EventWaitHandle(false, EventResetMode.AutoReset, activateName); }
                catch { }
                EventWaitHandle quitEvent = null;
                try { quitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, mutexName + "_Quit"); }
                catch { }

                AppendStartup(effectiveDir, "Program: 单实例就绪 args=" + string.Join(" ", args));

                // 监控引擎与界面解耦：引擎在界面创建之前启动，界面/托盘异常也不会导致"进程活着但不采集"
                Monitor monitor = new Monitor(cfg);
                try
                {
                    monitor.Start();
                    AppendStartup(effectiveDir, "Program: 监控引擎已启动");
                }
                catch (Exception mex) { LogFatal(effectiveDir, "Monitor.Start", mex); }

                // UI 线程异常也写日志，避免"静默退出"
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += delegate(object s, System.Threading.ThreadExceptionEventArgs te)
                {
                    try
                    {
                        File.AppendAllText(Path.Combine(effectiveDir, "ui-error.log"),
                            DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " UI EXCEPTION: " + te.Exception + "\r\n\r\n");
                    }
                    catch { }
                    try { MessageBox.Show("界面异常: " + te.Exception.Message + "\n\n详情见数据目录 ui-error.log", "IP监控2.1", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                    catch { }
                };

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                try
                {
                    // 2.1 修复（P1-6）：「启动时最小化」原来是死设置，现在与 --background 一样生效；--show 强制显示
                    bool startHidden = background || (cfg.StartMinimized && !showRequested);
                    MainForm form = new MainForm(cfg, startHidden, monitor, activateEvent, quitEvent, effectiveDir);
                    AppendStartup(effectiveDir, "Program: MainForm 已创建");
                    Application.Run(form);
                    AppendStartup(effectiveDir, "Program: Application.Run 退出");
                }
                catch (Exception uiEx)
                {
                    LogFatal(effectiveDir, "MainForm/Application.Run", uiEx);
                    try
                    {
                        MessageBox.Show("启动失败: " + uiEx.Message + "\n\n日志: " + Path.Combine(effectiveDir, "crash.log"),
                            "IP监控2.1", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                    catch { }
                }
                finally
                {
                    try { monitor.Stop(); } catch { }
                }
            }
            catch (Exception ex)
            {
                LogFatal("", "Main", ex);
            }
        }

        // 启动过程日志：用于诊断"进程活着但没界面 / 不采集"这类问题
        internal static void AppendStartup(string dir, string message)
        {
            try
            {
                if (string.IsNullOrEmpty(dir)) return;
                Directory.CreateDirectory(dir);
                string p = Path.Combine(dir, "startup.log");
                try
                {
                    FileInfo fi = new FileInfo(p);
                    if (fi.Exists && fi.Length > 256 * 1024) File.Delete(p);
                }
                catch { }
                File.AppendAllText(p, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + message + "\r\n");
            }
            catch { }
        }

        // 致命异常统一落盘：优先数据目录（WMI 启动时 %TEMP% 可能为空且不可写）
        internal static void LogFatal(string dir, string where, Exception ex)
        {
            string text = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [" + where + "] " + ex + "\r\n\r\n";
            string[] paths = new string[] { "", "" };
            try
            {
                if (!string.IsNullOrEmpty(dir)) paths[0] = Path.Combine(dir, "crash.log");
                paths[1] = Path.Combine(AppConfig.DefaultDataDir(), "crash.log");
            }
            catch { }
            for (int i = 0; i < paths.Length; i++)
            {
                if (string.IsNullOrEmpty(paths[i])) continue;
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(paths[i]));
                    File.AppendAllText(paths[i], text);
                    return;
                }
                catch { }
            }
            try { File.AppendAllText(Path.Combine(Path.GetTempPath(), "NetWatcher-crash.log"), text); } catch { }
        }

        // ---------- 自检（管理员运行时同时是 EStats 精确模式诊断） ----------
        static void RunSelfTest(AppConfig cfg, string dataDir)
        {
            string logPath = Path.Combine(dataDir, "selftest.log");
            StringBuilder sb = new StringBuilder();
            Action<string> L = delegate(string s)
            {
                sb.AppendLine(s);
                try { File.AppendAllText(logPath, s + "\r\n"); } catch { }
            };

            L("=== IP监控2.1 自检 ===");
            L("时间: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            L("数据目录: " + dataDir);
            L("程序: " + Startup.ExePath());
            L("管理员权限: " + (NativeMethods.IsAdministrator() ? "是" : "否"));
            L("进程位数: " + (IntPtr.Size == 8 ? "64 位" : "32 位"));
            try { L("操作系统: " + Environment.OSVersion + " / " + (Environment.Is64BitOperatingSystem ? "64" : "32")); } catch { }
            L("扫描间隔: " + cfg.ScanIntervalSeconds + " 秒");
            L("IP 归属地: " + (cfg.GeoEnabled ? "开" : "关"));

            // 网卡
            L("");
            L("--- 网卡统计（Loopback/Tunnel 不计数）---");
            long totalIn = 0, totalOut = 0;
            try
            {
                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    bool excluded = nic.NetworkInterfaceType == NetworkInterfaceType.Loopback
                        || nic.NetworkInterfaceType == NetworkInterfaceType.Tunnel
                        || nic.OperationalStatus != OperationalStatus.Up;
                    long bIn = 0, bOut = 0;
                    try { IPInterfaceStatistics st = nic.GetIPStatistics(); bIn = st.BytesReceived; bOut = st.BytesSent; } catch { }
                    if (!excluded) { totalIn += bIn; totalOut += bOut; }
                    L("  " + (excluded ? "[跳过] " : "[计入] ") + nic.Name + " (" + nic.NetworkInterfaceType + ", "
                        + nic.OperationalStatus + ") 收=" + FmtBytes(bIn) + " 发=" + FmtBytes(bOut));
                }
            }
            catch (Exception ex) { L("  网卡枚举失败: " + ex.Message); }
            L("合计计入: 收=" + FmtBytes(totalIn) + " 发=" + FmtBytes(totalOut));

            // TCP 连接
            NativeMethods.ClearProcessCache();
            List<ConnEntry> conns = NativeMethods.EnumTcpConnections();
            int est = 0;
            List<ConnEntry> remote = new List<ConnEntry>();
            for (int i = 0; i < conns.Count; i++)
            {
                ConnEntry c = conns[i];
                if (c.State != "ESTABLISHED") continue;
                est++;
                string rip = GeoIp.NormalizeIp(c.RemoteIp);
                if (string.IsNullOrEmpty(rip) || rip == "0.0.0.0" || rip == "127.0.0.1" || rip == "::1") continue;
                c.RemoteIp = rip;
                remote.Add(c);
            }
            L("");
            L("--- TCP 连接 ---");
            L("TCP 行数(含监听): " + conns.Count + "   ESTABLISHED: " + est + "   其中远端连接: " + remote.Count);
            for (int i = 0; i < remote.Count && i < 15; i++)
            {
                ConnEntry c = remote[i];
                L("  " + c.RemoteIp + ":" + c.RemotePort + "  <-  " + (string.IsNullOrEmpty(c.ProcessName) ? "(未知)" : c.ProcessName)
                    + " (PID " + c.Pid + ") " + c.Proto + "  路径=" + (string.IsNullOrEmpty(c.ProcessPath) ? "-" : c.ProcessPath));
            }
            if (remote.Count > 15) L("  ... 共 " + remote.Count + " 条");

            // EStats 诊断（关键）
            L("");
            L("--- EStats 逐连接字节诊断（精确模式判据）---");
            bool anyOk = false;
            string firstDiag = "";
            int tried = 0;
            for (int i = 0; i < remote.Count && tried < 5; i++)
            {
                ConnEntry c = remote[i];
                if (c.Proto != "TCP") continue;
                tried++;
                string detail;
                bool ok = NativeMethods.ProbeEStats(c, out detail);
                if (ok) anyOk = true;
                if (firstDiag.Length == 0) firstDiag = detail;
                L("  连接 " + c.RemoteIp + ":" + c.RemotePort + " (PID " + c.Pid + ") → " + (ok ? "成功" : "失败"));
                L("    " + detail);
            }
            if (tried == 0) L("  没有可测试的 IPv4 TCP 远端连接");
            if (tried > 0)
            {
                L("EStats 结论: " + (anyOk ? "可用（管理员模式下逐 IP 精确流量生效）"
                    : "不可用（" + (NativeMethods.IsAdministrator() ? "以管理员运行仍失败，见上面 rc/winerr" : "当前非管理员，需以管理员身份运行") + "）"));
            }

            // 直读一次做对照
            if (anyOk)
            {
                for (int i = 0; i < remote.Count; i++)
                {
                    if (remote[i].Proto != "TCP") continue;
                    ulong o, inb; uint rc; int werr;
                    if (NativeMethods.EStatsRead(remote[i], out o, out inb, out rc, out werr))
                    {
                        L("  抽样读 " + remote[i].RemoteIp + ":" + remote[i].RemotePort + " 累计发送=" + o + " 接收=" + inb);
                        break;
                    }
                }
            }

            // GeoIP
            L("");
            L("--- IP 归属地 ---");
            GeoInfo g1 = GeoIp.LookupSync("8.8.8.8");
            L("  GeoIP(8.8.8.8): " + g1.Display() + "  [来源:" + g1.Source + "]");
            GeoInfo g2 = GeoIp.LookupSync("192.168.1.1");
            L("  GeoIP(192.168.1.1): " + g2.Display() + "  [来源:" + g2.Source + "]");

            // 存储（2.3.0：加密小时文件 .nwipdb；2.1 修复 P0-2 延续：在独立临时子目录做往返测试，绝不覆盖 data\ 当天真实数据）
            L("");
            L("--- 存储（加密小时文件 .nwipdb） ---");
            List<string> datesBefore = Store.ListDates();
            string stTestDir = Path.Combine(dataDir, "selftest-store");
            int dataFilesBefore = 0;
            try { dataFilesBefore = Directory.GetFiles(Path.Combine(dataDir, "data")).Length; } catch { }
            try
            {
                try { if (Directory.Exists(stTestDir)) Directory.Delete(stTestDir, true); } catch { }
                Store.Init(stTestDir);
                string dstr = DateTime.Now.ToString("yyyy-MM-dd");
                long hs = Monitor.LocalHourStartUnix(DateTime.Now);
                long ss = Monitor.NowUnix();
                DayData hd = new DayData { date = dstr, hourStartUnix = hs, sessionStartUnix = ss };
                hd.bytesIn = 123456; hd.bytesOut = 65432;
                hd.peakInBps = 1111; hd.peakOutBps = 2222;
                hd.sampleCount = 3; hd.bytesPrecise = true;
                hd.firstSampleUnix = ss; hd.lastSampleUnix = ss + 120;
                hd.samples.Add(new long[] { ss - (ss % 60), 100, 20 });
                hd.samples.Add(new long[] { ss - (ss % 60) + 60, 200, 30 });
                IpAggregate agg = new IpAggregate { ip = "203.0.113.9", bytesIn = 1000, bytesOut = 200, sampleCount = 2, sessionCount = 1 };
                agg.firstSeenUnix = ss; agg.lastSeenUnix = ss + 60;
                hd.ips["203.0.113.9"] = agg;
                ProcAgg pagg = new ProcAgg { name = "selftest.exe", pid = 4242, path = "C:\\selftest.exe" };
                IpConnAgg iagg = new IpConnAgg { ip = "203.0.113.9", bytesIn = 1000, bytesOut = 200, connCount = 1 };
                iagg.firstSeenUnix = ss;
                pagg.ips["203.0.113.9"] = iagg;
                pagg.firstSeenUnix = ss; pagg.lastSeenUnix = ss + 60;
                hd.procs["selftest.exe|4242|0"] = pagg;

                bool savedHour = Store.SaveHour(hd);
                string[] nwFiles = Directory.GetFiles(Path.Combine(stTestDir, "data"), "*" + Store.HourFileSuffix);
                string hourFile = nwFiles.Length > 0 ? nwFiles[0] : "";
                DayData backHour = Store.LoadDay(dstr);
                bool rt = savedHour && hourFile.Length > 0 && backHour != null
                    && backHour.bytesIn == hd.bytesIn && backHour.bytesOut == hd.bytesOut
                    && backHour.sampleCount == hd.sampleCount
                    && backHour.ips.ContainsKey("203.0.113.9") && backHour.procs.Count == 1;
                byte[] hb = null;
                try { if (hourFile.Length > 0) hb = File.ReadAllBytes(hourFile); } catch { }
                bool looksEncrypted = hb != null && hb.Length > 96
                    && hb[0] == (byte)'N' && hb[1] == (byte)'W' && hb[2] == (byte)'I' && hb[3] == (byte)'P'
                    && hb[4] == (byte)'D' && hb[5] == (byte)'B' && hb[6] == (byte)'0' && hb[7] == (byte)'1';
                bool noPlainIp = hb != null
                    && Encoding.ASCII.GetString(hb).IndexOf("203.0.113.9", StringComparison.Ordinal) < 0
                    && Encoding.ASCII.GetString(hb).IndexOf("\"ips\"", StringComparison.Ordinal) < 0;
                L("  小时文件加密往返: " + (rt ? "OK" : "FAIL") + "  文件=" + Path.GetFileName(hourFile) + "  大小=" + (hb == null ? 0 : hb.Length) + "B");
                L("  加密性（二进制 magic=NWIPDB01 / 无明文 IP）: " + ((looksEncrypted && noPlainIp) ? "OK" : "FAIL"));
                L("  明文头快速摘要: 下载=" + Store.LoadDaySummary(dstr).bytesIn + " 采样=" + Store.LoadDaySummary(dstr).sampleCount);

                // legacy JSON 迁移：合成旧明文日文件 → 加密 legacy 块 → 回读校验 → 删除明文
                string legacyDate = DateTime.Now.AddDays(-1).ToString("yyyy-MM-dd");
                DayData old = new DayData { date = legacyDate, bytesIn = 987654, bytesOut = 123456, peakInBps = 77, peakOutBps = 88, sampleCount = 5 };
                old.ips["198.51.100.7"] = new IpAggregate { ip = "198.51.100.7", bytesIn = 987654, bytesOut = 123456 };
                string legacyJson = Store.DataPath(legacyDate);
                bool wroteJson = Store.SaveDay(old);
                int migrated = Store.MigrateLegacyOnce();
                bool jsonGone = !File.Exists(legacyJson);
                DayData legacyBack = Store.LoadDay(legacyDate);
                bool migOk = wroteJson && migrated >= 1 && jsonGone && legacyBack != null
                    && legacyBack.bytesIn == old.bytesIn && legacyBack.bytesOut == old.bytesOut
                    && legacyBack.ips.Count == 1;
                string[] legacyFiles = Directory.GetFiles(Path.Combine(stTestDir, "data"), "*legacy*" + Store.HourFileSuffix);
                L("  legacy JSON 迁移: " + (migOk ? "OK" : "FAIL") + "（迁移 " + migrated + " 个，原 JSON 已删=" + jsonGone
                    + "，回读汇总=" + (legacyBack == null ? "null" : legacyBack.bytesIn + "/" + legacyBack.bytesOut)
                    + "，legacy 文件数=" + legacyFiles.Length + "）");

                // H7 性能（合成数据，全部写在 selftest-store；供 QA 引用）：
                // 1) 一天 24 个小时文件的解密合并耗时；2) 历史页 30 天首载（只读明文头、免 AES 解密）耗时
                string perfDate = DateTime.Now.AddDays(-2).ToString("yyyy-MM-dd");
                long perfDayStart = Monitor.LocalDayStartUnix(DateTime.Now.AddDays(-2).Date);
                for (int h = 0; h < 24; h++)
                {
                    DayData ph = new DayData { date = perfDate, hourStartUnix = perfDayStart + h * 3600L, sessionStartUnix = ss };
                    ph.bytesIn = 1000L * (h + 1);
                    ph.bytesOut = 100L * (h + 1);
                    ph.peakInBps = 100L + h;
                    ph.peakOutBps = 50L + h;
                    ph.sampleCount = 60;
                    ph.firstSampleUnix = perfDayStart + h * 3600L;
                    ph.lastSampleUnix = ph.firstSampleUnix + 3540;
                    for (int m = 0; m < 60; m++) ph.samples.Add(new long[] { perfDayStart + h * 3600L + m * 60L, 100L + h, 20L + h });
                    IpAggregate pag = new IpAggregate { ip = "203.0.113." + (10 + h), bytesIn = 1000L * (h + 1), bytesOut = 100L * (h + 1), sampleCount = 60, sessionCount = 1 };
                    pag.firstSeenUnix = ph.firstSampleUnix; pag.lastSeenUnix = ph.lastSampleUnix;
                    ph.ips[pag.ip] = pag;
                    Store.SaveHour(ph);
                }
                Stopwatch swMerge = Stopwatch.StartNew();
                DayData merged = Store.LoadDay(perfDate);
                swMerge.Stop();
                L("  小时文件合并 24 文件: " + swMerge.ElapsedMilliseconds + " ms（下载=" + merged.bytesIn + "，采样=" + merged.sampleCount + "，IP=" + merged.ips.Count + "）");

                for (int d = 0; d < 30; d++)
                {
                    string histDate = DateTime.Now.AddDays(-3 - d).ToString("yyyy-MM-dd");
                    long histDayStart = Monitor.LocalDayStartUnix(DateTime.Now.AddDays(-3 - d).Date);
                    DayData dh = new DayData { date = histDate, hourStartUnix = histDayStart, sessionStartUnix = ss };
                    dh.bytesIn = 5000 + d; dh.bytesOut = 500 + d; dh.peakInBps = 10; dh.peakOutBps = 5; dh.sampleCount = 10;
                    dh.ips["198.51.100." + (d % 200 + 1)] = new IpAggregate { ip = "198.51.100.x", bytesIn = dh.bytesIn, bytesOut = dh.bytesOut };
                    Store.SaveHour(dh);
                }
                Stopwatch swHist = Stopwatch.StartNew();
                List<string> histDates = Store.ListDates();
                for (int i = 0; i < histDates.Count; i++) Store.LoadDaySummary(histDates[i]);
                swHist.Stop();
                L("  历史概览 30 天首载: " + swHist.ElapsedMilliseconds + " ms（" + histDates.Count + " 天，仅读明文头免解密）");
                L("  selftest 迁移策略: 不触碰真实 data\\（legacy 迁移只在 GUI/daemon 拿到数据写锁后由 Monitor 构造调用）");
            }
            catch (Exception stEx) { L("  存储自检异常: " + stEx.Message); }
            finally
            {
                try { Store.Init(dataDir); } catch { }
                try { if (Directory.Exists(stTestDir)) Directory.Delete(stTestDir, true); } catch { }
            }
            int dataFilesAfter = 0;
            try { dataFilesAfter = Directory.GetFiles(Path.Combine(dataDir, "data")).Length; } catch { }
            L("  真实 data\\ 未被 selftest 改写: " + (dataFilesBefore == dataFilesAfter ? "OK" : "FAIL")
                + "（文件数 " + dataFilesBefore + "→" + dataFilesAfter + "）");
            L("  已存在日期文件: " + string.Join(", ", datesBefore.ToArray()));

            // 开机自启（2.1 修复 P0-3：只测临时值名，不触碰真实自启项）
            L("");
            L("--- 开机自启 ---");
            L("  " + Startup.SelfTestAutoStart());
            L("  真实自启项(只读): HKCU Run\\NetWatcher2.1 " + (Startup.IsEnabled() ? "已启用" : "未启用"));

            // 趋势页绘制性能（2.2.0 收口：1440 点自绘到内存位图，只读、不写数据目录）
            L("");
            L("--- 趋势页绘制（2.2.0）---");
            try { L("  " + MainForm.TrendPerfSelfTest()); }
            catch (Exception tpEx) { L("  趋势绘制自测异常: " + tpEx.Message); }

            L("");
            L("=== 自检结束 ===");
            try { File.WriteAllText(logPath, sb.ToString()); } catch { }
            try { Console.WriteLine(sb.ToString()); } catch { }
        }

        internal static string FmtBytes(long b)
        {
            if (b < 0) b = 0;
            if (b < 1024) return b + " B";
            double kb = b / 1024.0;
            if (kb < 1024) return kb.ToString("0.0") + " KB";
            double mb = kb / 1024.0;
            if (mb < 1024) return mb.ToString("0.00") + " MB";
            double gb = mb / 1024.0;
            if (gb < 1024) return gb.ToString("0.00") + " GB";
            return (gb / 1024.0).ToString("0.00") + " TB";
        }
    }
}
