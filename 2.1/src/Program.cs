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
                }

                if (autostartOn) { Startup.SetEnabled(true, dataDir); return; }
                if (autostartOff) { Startup.SetEnabled(false); return; }

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
                    MainForm form = new MainForm(cfg, startHidden, monitor, activateEvent, effectiveDir);
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

            // 存储（2.1 修复 P0-2：在独立临时子目录里做往返测试，绝不覆盖 data\ 当天真实数据）
            L("");
            L("--- 存储 ---");
            List<string> datesBefore = Store.ListDates();
            string stTestDir = Path.Combine(dataDir, "selftest-store");
            try
            {
                try { if (Directory.Exists(stTestDir)) Directory.Delete(stTestDir, true); } catch { }
                Store.Init(stTestDir);
                DayData dd = new DayData { date = DateTime.Now.ToString("yyyy-MM-dd") };
                bool saved = Store.SaveDay(dd);
                DayData loaded = Store.LoadDay(dd.date);
                L("  原子写/读: " + (saved && loaded != null && loaded.date == dd.date ? "OK" : "FAIL") + "（测试目录 selftest-store，未触碰 data\\）");
            }
            catch (Exception stEx) { L("  存储自检异常: " + stEx.Message); }
            finally
            {
                try { Store.Init(dataDir); } catch { }
                try { if (Directory.Exists(stTestDir)) Directory.Delete(stTestDir, true); } catch { }
            }
            L("  已存在日期文件: " + string.Join(", ", datesBefore.ToArray()));

            // 开机自启（2.1 修复 P0-3：只测临时值名，不触碰真实自启项）
            L("");
            L("--- 开机自启 ---");
            L("  " + Startup.SelfTestAutoStart());
            L("  真实自启项(只读): HKCU Run\\NetWatcher2.1 " + (Startup.IsEnabled() ? "已启用" : "未启用"));

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
