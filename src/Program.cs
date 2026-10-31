using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace NetWatcher
{
    public static class Startup
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string ValueName = "NetWatcher";

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
            try
            {
                string val = "\"" + ExePath() + "\" --background";
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
    }

    static class Program
    {
        static Mutex mutex;

        [STAThread]
        static void Main(string[] args)
        {
            AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e)
            {
                try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "NetWatcher-crash.log"), "Unhandled: " + (e.ExceptionObject == null ? "" : e.ExceptionObject.ToString())); } catch { }
            };
            try
            {
                string dataDir = "";
                bool background = false;
                bool selfTest = false;
                bool autostartOn = false, autostartOff = false;
                int daemonSeconds = 0;
                for (int i = 0; i < args.Length; i++)
                {
                    string a = args[i];
                    if (a == "--background" || a == "-b" || a == "--minimized") background = true;
                    else if (a == "--selftest" || a == "--test") selfTest = true;
                    else if (a == "--autostart-on") autostartOn = true;
                    else if (a == "--autostart-off") autostartOff = true;
                    else if (a == "--datadir" && i + 1 < args.Length) { dataDir = args[++i]; }
                    else if (a == "--daemon" && i + 1 < args.Length) { int.TryParse(args[++i], out daemonSeconds); }
                }

                if (autostartOn) { Startup.SetEnabled(true); return; }
                if (autostartOff) { Startup.SetEnabled(false); return; }

                AppConfig cfg = AppConfig.Load(dataDir);
                string effectiveDir = cfg.EffectiveDataDir();
                Store.Init(effectiveDir);
                GeoIp.Init(effectiveDir, cfg.GeoApi, cfg.GeoEnabled);

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
                    return;
                }

                // 单实例
                bool createdNew;
                mutex = new Mutex(true, "NetWatcher_SingleInstance_Mutex", out createdNew);
                if (!createdNew)
                {
                    MessageBox.Show("NetWatcher 已经在运行中（请查看系统托盘图标）。", "NetWatcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                MainForm form = new MainForm(cfg, background);
                Application.Run(form);
            }
            catch (Exception ex)
            {
                try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "NetWatcher-crash.log"), ex.ToString()); } catch { }
            }
        }

        static void RunSelfTest(AppConfig cfg, string dataDir)
        {
            string logPath = Path.Combine(dataDir, "selftest.log");
            var sb = new StringBuilder();
            Action<string> L = delegate(string s)
            {
                sb.AppendLine(s);
                try { File.AppendAllText(logPath, s + "\r\n"); } catch { }
            };

            L("=== NetWatcher 自检 ===");
            L("时间: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            L("数据目录: " + dataDir);
            L("管理员权限: " + (NativeMethods.IsAdministrator() ? "是" : "否"));
            L("扫描间隔: " + cfg.ScanIntervalSeconds + " 秒");

            long tin, tout;
            NativeMethods.GetTotalBytes(out tin, out tout);
            L("系统累计接收: " + tin + " B (" + FmtBytes(tin) + ")");
            L("系统累计发送: " + tout + " B (" + FmtBytes(tout) + ")");

            NativeMethods.ClearProcessCache();
            List<ConnEntry> conns = NativeMethods.EnumTcpConnections();
            int est = 0;
            foreach (ConnEntry c in conns) if (c.State == "ESTABLISHED") est++;
            L("TCP 连接总数(含监听): " + conns.Count);
            L("其中 ESTABLISHED: " + est);

            var remote = new List<ConnEntry>();
            foreach (ConnEntry c in conns)
            {
                string rip = GeoIp.NormalizeIp(c.RemoteIp);
                if (c.State == "ESTABLISHED" && rip != "0.0.0.0" && !GeoIp.IsLocalIp(rip))
                {
                    c.RemoteIp = rip;
                    remote.Add(c);
                }
            }
            L("远程已建立连接数: " + remote.Count);
            int shown = 0;
            foreach (ConnEntry c in remote)
            {
                if (shown++ >= 15) break;
                L("  " + c.RemoteIp + ":" + c.RemotePort + "  <-  " + c.ProcessName + " (PID " + c.Pid + ") " + c.Proto);
            }
            if (remote.Count > 15) L("  ... 共 " + remote.Count + " 条");

            if (NativeMethods.IsAdministrator())
            {
                int ok = 0, fail = 0; ulong sumOut = 0, sumIn = 0;
                foreach (ConnEntry c in remote)
                {
                    ulong bo, bi;
                    if (NativeMethods.ReadTcpDataBytes(c, out bo, out bi)) { ok++; sumOut += bo; sumIn += bi; }
                    else fail++;
                }
                L("EStats 逐连接字节: 成功 " + ok + " 失败 " + fail + " 累计发送 " + sumOut + " 累计接收 " + sumIn);
            }
            else
            {
                L("EStats 精确逐IP字节: 跳过（需要管理员权限，当前为估算模式）");
            }

            GeoInfo g1 = GeoIp.LookupSync("8.8.8.8");
            L("GeoIP(8.8.8.8): " + g1.Display() + "  [来源:" + g1.Source + "]");
            GeoInfo g2 = GeoIp.LookupSync("192.168.1.1");
            L("GeoIP(192.168.1.1): " + g2.Display() + "  [来源:" + g2.Source + "]");

            Store.Init(dataDir);
            DayData dd = new DayData { date = DateTime.Now.ToString("yyyy-MM-dd") };
            Store.SaveDay(dd);
            DayData loaded = Store.LoadDay(dd.date);
            L("存储读写: " + (loaded != null && loaded.date == dd.date ? "OK" : "FAIL"));
            L("已存在日期文件: " + string.Join(", ", Store.ListDates().ToArray()));

            // 开机自启注册表读写测试（进程内自检，不改变最终状态）
            bool before = Startup.IsEnabled();
            Startup.SetEnabled(true);
            bool on = Startup.IsEnabled();
            Startup.SetEnabled(false);
            bool off = Startup.IsEnabled();
            if (before) Startup.SetEnabled(true); // 还原
            L("开机自启注册表: 写入后=" + on + " 删除后=" + off + " (期望 True/False)");
            L("=== 自检结束 ===");

            string log = sb.ToString();
            try { File.WriteAllText(Path.Combine(dataDir, "selftest.log"), log); }
            catch { }
            try { Console.WriteLine(log); }
            catch { }
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
