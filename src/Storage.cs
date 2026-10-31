using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Web.Script.Serialization;

namespace NetWatcher
{
    // ---------- 按日聚合模型（序列化到 data\YYYY-MM-DD.json） ----------

    public class IpConnAgg
    {
        public string ip = "";
        public long bytesIn = 0;
        public long bytesOut = 0;
        public int connCount = 0;               // 连接出现次数（按连接 key 去重，不随采样累加）
        public List<int> ports = new List<int>();
        public string proto = "TCP";
        public string city = "", region = "", country = "", isp = "", hostname = "";
        public long firstSeenUnix = 0;

        public IpConnAgg Clone()
        {
            IpConnAgg c = new IpConnAgg();
            c.ip = ip; c.bytesIn = bytesIn; c.bytesOut = bytesOut; c.connCount = connCount;
            c.ports = new List<int>(ports); c.proto = proto;
            c.city = city; c.region = region; c.country = country; c.isp = isp; c.hostname = hostname;
            c.firstSeenUnix = firstSeenUnix;
            return c;
        }
    }

    public class ProcAgg
    {
        public string name = "";
        public string path = "";
        public int pid = 0;
        public long processStartUnix = 0;        // 用于区分 PID 复用
        public long bytesIn = 0;
        public long bytesOut = 0;
        public int connCount = 0;
        public long firstSeenUnix = 0;
        public long lastSeenUnix = 0;
        public Dictionary<string, IpConnAgg> ips = new Dictionary<string, IpConnAgg>();

        public ProcAgg Clone()
        {
            ProcAgg p = new ProcAgg();
            p.name = name; p.path = path; p.pid = pid; p.processStartUnix = processStartUnix;
            p.bytesIn = bytesIn; p.bytesOut = bytesOut; p.connCount = connCount;
            p.firstSeenUnix = firstSeenUnix; p.lastSeenUnix = lastSeenUnix;
            p.ips = new Dictionary<string, IpConnAgg>();
            foreach (KeyValuePair<string, IpConnAgg> kv in ips) p.ips[kv.Key] = kv.Value.Clone();
            return p;
        }
    }

    public class IpAggregate
    {
        public string ip = "";
        public long bytesIn = 0;
        public long bytesOut = 0;
        public long peakInBps = 0;
        public long peakOutBps = 0;
        public long connectedSeconds = 0;
        public int sampleCount = 0;              // 出现过的采样次数
        public int sessionCount = 0;             // 真实会话数（由无连接到有连接）
        public long firstSeenUnix = 0;
        public long lastSeenUnix = 0;
        public Dictionary<string, int> processes = new Dictionary<string, int>();
        public Dictionary<string, int> states = new Dictionary<string, int>();
        public List<int> ports = new List<int>();
        public string city = "", region = "", country = "", isp = "", hostname = "";
        public bool bytesPrecise = false;
        [ScriptIgnore] public bool isNew = false;   // 今天首次出现（仅 UI 用，不落盘）

        public IpAggregate Clone()
        {
            IpAggregate a = new IpAggregate();
            a.ip = ip; a.bytesIn = bytesIn; a.bytesOut = bytesOut;
            a.peakInBps = peakInBps; a.peakOutBps = peakOutBps;
            a.connectedSeconds = connectedSeconds; a.sampleCount = sampleCount; a.sessionCount = sessionCount;
            a.firstSeenUnix = firstSeenUnix; a.lastSeenUnix = lastSeenUnix;
            a.processes = new Dictionary<string, int>(processes);
            a.states = new Dictionary<string, int>(states);
            a.ports = new List<int>(ports);
            a.city = city; a.region = region; a.country = country; a.isp = isp; a.hostname = hostname;
            a.bytesPrecise = bytesPrecise; a.isNew = isNew;
            return a;
        }
    }

    public class DayData
    {
        public string date = "";
        public long bytesIn = 0;
        public long bytesOut = 0;
        public long peakInBps = 0;
        public long peakOutBps = 0;
        public long firstSampleUnix = 0;
        public long lastSampleUnix = 0;
        public int sampleCount = 0;
        public bool bytesPrecise = false;
        public Dictionary<string, IpAggregate> ips = new Dictionary<string, IpAggregate>();
        public Dictionary<string, ProcAgg> procs = new Dictionary<string, ProcAgg>();
        public List<long[]> samples = new List<long[]>();   // [minuteUnix, bytesIn, bytesOut]，最多 1440 条

        [ScriptIgnore] public int ipCount = 0;      // 汇总用（历史缓存剥离明细后仍可用）
        [ScriptIgnore] public int procCount = 0;

        public DayData Clone()
        {
            DayData d = new DayData();
            d.date = date; d.bytesIn = bytesIn; d.bytesOut = bytesOut;
            d.peakInBps = peakInBps; d.peakOutBps = peakOutBps;
            d.firstSampleUnix = firstSampleUnix; d.lastSampleUnix = lastSampleUnix;
            d.sampleCount = sampleCount; d.bytesPrecise = bytesPrecise;
            d.ips = new Dictionary<string, IpAggregate>();
            foreach (KeyValuePair<string, IpAggregate> kv in ips) d.ips[kv.Key] = kv.Value.Clone();
            d.procs = new Dictionary<string, ProcAgg>();
            foreach (KeyValuePair<string, ProcAgg> kv in procs) d.procs[kv.Key] = kv.Value.Clone();
            d.samples = new List<long[]>();
            for (int i = 0; i < samples.Count; i++)
            {
                long[] s = samples[i];
                d.samples.Add(new long[] { s[0], s[1], s[2] });
            }
            d.ipCount = ips.Count;
            d.procCount = procs.Count;
            return d;
        }

        // 只保留汇总字段，丢掉明细（历史概览用，省内存）
        public DayData SummaryOnly()
        {
            DayData d = new DayData();
            d.date = date; d.bytesIn = bytesIn; d.bytesOut = bytesOut;
            d.peakInBps = peakInBps; d.peakOutBps = peakOutBps;
            d.firstSampleUnix = firstSampleUnix; d.lastSampleUnix = lastSampleUnix;
            d.sampleCount = sampleCount; d.bytesPrecise = bytesPrecise;
            d.ipCount = ips.Count; d.procCount = procs.Count;
            return d;
        }
    }

    // ---------- 存储 ----------

    public static class Store
    {
        static readonly object Lock = new object();
        static string _dataDir = "";

        public static string DataDir { get { return _dataDir; } }

        public static void Init(string dataDir)
        {
            _dataDir = dataDir;
            lock (Lock)
            {
                Directory.CreateDirectory(_dataDir);
                Directory.CreateDirectory(Path.Combine(_dataDir, "data"));
            }
        }

        public static string DataPath(string date)
        {
            return Path.Combine(_dataDir, "data", date + ".json");
        }

        public static DayData LoadDay(string date)
        {
            lock (Lock)
            {
                try
                {
                    string p = DataPath(date);
                    if (File.Exists(p))
                    {
                        DayData d = Json.Deserialize<DayData>(File.ReadAllText(p));
                        if (d != null)
                        {
                            d.date = date;
                            if (d.ips == null) d.ips = new Dictionary<string, IpAggregate>();
                            if (d.procs == null) d.procs = new Dictionary<string, ProcAgg>();
                            if (d.samples == null) d.samples = new List<long[]>();
                            d.ipCount = d.ips.Count;
                            d.procCount = d.procs.Count;
                            return d;
                        }
                    }
                }
                catch { }
                return new DayData { date = date };
            }
        }

        // 原子写：先写 .tmp，再 Replace/Move 覆盖，避免断电写坏当天文件
        public static bool SaveDay(DayData d)
        {
            lock (Lock)
            {
                try
                {
                    Directory.CreateDirectory(_dataDir);
                    Directory.CreateDirectory(Path.Combine(_dataDir, "data"));
                    string target = DataPath(d.date);
                    string tmp = target + ".tmp";
                    string text = Json.Serialize(d);
                    File.WriteAllText(tmp, text);
                    try
                    {
                        if (File.Exists(target)) File.Replace(tmp, target, null);
                        else File.Move(tmp, target);
                    }
                    catch
                    {
                        // 极端情况（被占用等）回退
                        try { if (File.Exists(target)) File.Delete(target); } catch { }
                        File.Move(tmp, target);
                    }
                    return true;
                }
                catch (Exception ex)
                {
                    try
                    {
                        File.AppendAllText(Path.Combine(_dataDir, "monitor.log"),
                            DateTime.Now.ToString("HH:mm:ss") + " SAVEDAY ERROR: " + ex.Message + "\r\n");
                    }
                    catch { }
                    return false;
                }
            }
        }

        public static List<string> ListDates()
        {
            List<string> r = new List<string>();
            lock (Lock)
            {
                try
                {
                    string dir = Path.Combine(_dataDir, "data");
                    if (Directory.Exists(dir))
                    {
                        foreach (string f in Directory.GetFiles(dir, "*.json"))
                        {
                            string d = Path.GetFileNameWithoutExtension(f);
                            if (d.Length == 10) r.Add(d);
                        }
                    }
                }
                catch { }
            }
            r.Sort();
            r.Reverse();
            return r;
        }

        public static void EnforceRetention(int days)
        {
            if (days <= 0) return;
            lock (Lock)
            {
                try
                {
                    DateTime cutoff = DateTime.Now.Date.AddDays(-days);
                    string dir = Path.Combine(_dataDir, "data");
                    if (!Directory.Exists(dir)) return;
                    foreach (string f in Directory.GetFiles(dir, "*.json"))
                    {
                        DateTime dt;
                        if (DateTime.TryParseExact(Path.GetFileNameWithoutExtension(f), "yyyy-MM-dd",
                                CultureInfo.InvariantCulture, DateTimeStyles.None, out dt))
                        {
                            if (dt < cutoff) File.Delete(f);
                        }
                    }
                }
                catch { }
            }
        }
    }
}
