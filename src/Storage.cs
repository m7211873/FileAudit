using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace NetWatcher
{
    public class IpAggregate
    {
        public string ip = "";
        public long bytesIn = 0;
        public long bytesOut = 0;
        public long peakInBps = 0;
        public long peakOutBps = 0;
        public long connectedSeconds = 0;
        public int sampleCount = 0;      // 出现的采样次数
        public int sessionCount = 0;     // 连接会话次数（由无到有）
        public long firstSeenUnix = 0;
        public long lastSeenUnix = 0;
        public Dictionary<string, int> processes = new Dictionary<string, int>();
        public Dictionary<string, int> states = new Dictionary<string, int>();
        public List<int> ports = new List<int>();
        public string city = "", region = "", country = "", isp = "";
        public bool bytesPrecise = false; // 该 IP 字节是否来自精确统计
    }

    public class IpConnAgg
    {
        public string ip = "";
        public long bytesIn = 0;
        public long bytesOut = 0;
        public int connCount = 0;
        public List<int> ports = new List<int>();
        public string proto = "";
        public string city = "", region = "", country = "", isp = "";
    }

    public class ProcAgg
    {
        public string name = "";
        public int pid = 0;
        public long bytesIn = 0;
        public long bytesOut = 0;
        public int connCount = 0;
        public long firstSeenUnix = 0;
        public long lastSeenUnix = 0;
        public Dictionary<string, IpConnAgg> ips = new Dictionary<string, IpConnAgg>();
    }

    public class DayData
    {
        public string date = "";
        public long bytesIn = 0;         // 当日总下行（精确）
        public long bytesOut = 0;        // 当日总上行（精确）
        public long peakInBps = 0;
        public long peakOutBps = 0;
        public long firstSampleUnix = 0;
        public long lastSampleUnix = 0;
        public int sampleCount = 0;
        public bool bytesPrecise = false; // 逐 IP 字节是否精确
        public Dictionary<string, IpAggregate> ips = new Dictionary<string, IpAggregate>();
        public Dictionary<string, ProcAgg> procs = new Dictionary<string, ProcAgg>();
        public List<long[]> samples = new List<long[]>(); // [unixSeconds, bytesInDelta, bytesOutDelta] 每间隔总流量
    }

    public static class Store
    {
        static readonly object Lock = new object();
        static string DataDir = "";

        public static void Init(string dataDir)
        {
            DataDir = dataDir;
            lock (Lock)
            {
                Directory.CreateDirectory(DataDir);
                Directory.CreateDirectory(Path.Combine(DataDir, "data"));
            }
        }

        public static string DataPath(string date)
        {
            return Path.Combine(DataDir, "data", date + ".json");
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
                        if (d != null) { d.date = date; return d; }
                    }
                }
                catch { }
                return new DayData { date = date };
            }
        }

        public static void SaveDay(DayData d)
        {
            lock (Lock)
            {
                try { File.WriteAllText(DataPath(d.date), Json.Serialize(d)); }
                catch (Exception ex)
                {
                    try { File.AppendAllText(Path.Combine(DataDir, "monitor.log"), DateTime.Now.ToString("HH:mm:ss") + " SAVEDAY ERROR: " + ex + "\r\n"); }
                    catch { }
                }
            }
        }

        public static List<string> ListDates()
        {
            var r = new List<string>();
            lock (Lock)
            {
                try
                {
                    string dir = Path.Combine(DataDir, "data");
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
                    string dir = Path.Combine(DataDir, "data");
                    if (!Directory.Exists(dir)) return;
                    foreach (string f in Directory.GetFiles(dir, "*.json"))
                    {
                        DateTime dt;
                        if (DateTime.TryParseExact(Path.GetFileNameWithoutExtension(f), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out dt))
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
