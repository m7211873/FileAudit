using System;
using System.Collections.Generic;
using System.Threading;

namespace NetWatcher
{
    public class LiveIp
    {
        public string Ip = "", City = "", Region = "", Country = "", Isp = "";
        public int ConnCount = 0;
        public long SpeedInBps = 0, SpeedOutBps = 0;
        public long BytesInDelta = 0, BytesOutDelta = 0;
    }

    public class LiveConn
    {
        public string Ip = "", ProcessName = "", State = "", Proto = "";
        public int RemotePort = 0, LocalPort = 0, Pid = 0;
        public string City = "", Region = "", Country = "", Isp = "";
        public long BytesIn = 0, BytesOut = 0;          // 累计（估算或精确）
        public long DurationSeconds = 0;                 // 连接持续时间
        public long SpeedInBps = 0, SpeedOutBps = 0;     // 本采样速率
    }

    public class Snapshot
    {
        public List<ConnEntry> Connections = new List<ConnEntry>();
        public List<LiveConn> LiveConns = new List<LiveConn>();
        public List<LiveIp> LiveIps = new List<LiveIp>();
        public long TotalInBps = 0, TotalOutBps = 0;
        public long TodayInBytes = 0, TodayOutBytes = 0;
        public bool BytesPrecise = false;
        public bool IsAdmin = false;
        public DateTime LastScan = DateTime.MinValue;
        public string LastError = "";
    }

    public class Monitor
    {
        readonly AppConfig cfg;
        Thread thread;
        volatile bool stop = false;
        readonly object liveLock = new object();

        DayData current;
        string currentDate = "";
        readonly HashSet<string> prevActiveIps = new HashSet<string>();
        readonly Dictionary<string, ulong[]> estatsLast = new Dictionary<string, ulong[]>();
        readonly Dictionary<string, long> connFirstSeen = new Dictionary<string, long>();
        readonly Dictionary<string, long[]> connCumBytes = new Dictionary<string, long[]>();
        long lastTotalIn = 0, lastTotalOut = 0;
        bool haveLastTotal = false;
        DateTime lastSampleTime = DateTime.MinValue;

        Snapshot snap = new Snapshot();

        public Monitor(AppConfig cfg)
        {
            this.cfg = cfg;
            current = new DayData { date = DateTime.Now.ToString("yyyy-MM-dd") };
            currentDate = current.date;
        }

        public void Start()
        {
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Name = "NetWatcherMonitor";
            thread.Start();
        }

        public void Stop()
        {
            stop = true;
            try { if (thread != null) thread.Join(3000); } catch { }
        }

        public static long NowUnix()
        {
            return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        }

        void Run()
        {
            while (!stop)
            {
                try
                {
                    int interval = cfg.ScanIntervalSeconds;
                    Sample(interval);
                }
                catch (Exception ex)
                {
                    lock (liveLock) { snap.LastError = ex.Message; }
                    try { System.IO.File.AppendAllText(System.IO.Path.Combine(cfg.EffectiveDataDir(), "monitor.log"), DateTime.Now.ToString("HH:mm:ss") + " SAMPLE ERROR: " + ex + "\r\n"); } catch { }
                }
                int slept = 0;
                while (!stop && slept < cfg.ScanIntervalSeconds * 1000)
                {
                    Thread.Sleep(200);
                    slept += 200;
                }
            }
        }

        void Sample(int interval)
        {
            NativeMethods.ClearProcessCache();
            List<ConnEntry> conns = NativeMethods.EnumTcpConnections();

            DateTime now = DateTime.Now;
            long unix = NowUnix();
            string date = now.ToString("yyyy-MM-dd");

            // 跨日：保存旧数据，载入/新建当日
            if (date != currentDate)
            {
                lock (liveLock)
                {
                    Store.SaveDay(current);
                    current = Store.LoadDay(date);
                }
                currentDate = date;
                prevActiveIps.Clear();
                estatsLast.Clear();
                haveLastTotal = false;
                lastSampleTime = DateTime.MinValue;
            }

            // 筛选：已建立连接 + 非本地远端
            var active = new List<ConnEntry>();
            foreach (ConnEntry c in conns)
            {
                string rip = GeoIp.NormalizeIp(c.RemoteIp);
                if (c.State == "ESTABLISHED" && rip != "0.0.0.0" && rip != "" && !GeoIp.IsLocalIp(rip))
                {
                    c.RemoteIp = rip; // 归一化（v4-mapped → v4）
                    active.Add(c);
                }
            }

            // 总流量增量（精确）
            long tin, tout;
            NativeMethods.GetTotalBytes(out tin, out tout);
            double elapsed = interval;
            if (lastSampleTime != DateTime.MinValue) elapsed = (now - lastSampleTime).TotalSeconds;
            if (elapsed < 1) elapsed = 1;
            lastSampleTime = now;

            long deltaIn = 0, deltaOut = 0;
            if (!haveLastTotal) { lastTotalIn = tin; lastTotalOut = tout; haveLastTotal = true; }
            else
            {
                deltaIn = tin >= lastTotalIn ? tin - lastTotalIn : 0;
                deltaOut = tout >= lastTotalOut ? tout - lastTotalOut : 0;
                lastTotalIn = tin; lastTotalOut = tout;
            }
            long totalInBps = (long)(deltaIn / elapsed);
            long totalOutBps = (long)(deltaOut / elapsed);

            // 按 IP 分组（先做 GeoIP，可能较慢，放在锁外）
            var byIp = new Dictionary<string, List<ConnEntry>>();
            foreach (ConnEntry c in active)
            {
                if (!byIp.ContainsKey(c.RemoteIp)) byIp[c.RemoteIp] = new List<ConnEntry>();
                byIp[c.RemoteIp].Add(c);
            }

            var geoMap = new Dictionary<string, GeoInfo>();
            foreach (string ip in byIp.Keys)
            {
                geoMap[ip] = GeoIp.Lookup(ip);
            }

            // 逐连接 / 逐 IP / 逐进程字节
            bool isAdmin = NativeMethods.IsAdministrator();
            bool precise = false;
            var connDelta = new Dictionary<string, long[]>(); // ConnKey -> [in, out]
            var perIpBytes = new Dictionary<string, long[]>(); // ip -> [in, out]
            foreach (string ip in byIp.Keys) perIpBytes[ip] = new long[2];
            var procIpBytes = new Dictionary<string, long[]>(); // procKey|ip -> [in, out]

            if (isAdmin)
            {
                precise = true;
                var curKeys = new HashSet<string>();
                foreach (ConnEntry c in active)
                {
                    if (c.Proto != "TCP") continue;
                    string key = c.Pid + "|" + c.LocalAddrRaw + "|" + c.LocalPortRaw + "|" + c.RemoteAddrRaw + "|" + c.RemotePortRaw;
                    curKeys.Add(key);
                    ulong bo, bi;
                    if (NativeMethods.ReadTcpDataBytes(c, out bo, out bi))
                    {
                        long dOut = 0, dIn = 0;
                        if (estatsLast.ContainsKey(key))
                        {
                            ulong lastOut = estatsLast[key][0], lastIn = estatsLast[key][1];
                            if (bo >= lastOut) dOut = (long)(bo - lastOut);
                            if (bi >= lastIn) dIn = (long)(bi - lastIn);
                        }
                        estatsLast[key] = new ulong[] { bo, bi };
                        string ck = ConnKey(c);
                        if (!connDelta.ContainsKey(ck)) connDelta[ck] = new long[2];
                        connDelta[ck][0] += dIn;
                        connDelta[ck][1] += dOut;
                    }
                }
                var gone = new List<string>();
                foreach (string k in estatsLast.Keys) if (!curKeys.Contains(k)) gone.Add(k);
                foreach (string k in gone) estatsLast.Remove(k);
            }
            else
            {
                int totalConns = active.Count;
                if (totalConns > 0)
                {
                    long sIn = deltaIn / totalConns;
                    long sOut = deltaOut / totalConns;
                    foreach (ConnEntry c in active)
                    {
                        string ck = ConnKey(c);
                        if (!connDelta.ContainsKey(ck)) connDelta[ck] = new long[2];
                        connDelta[ck][0] += sIn;
                        connDelta[ck][1] += sOut;
                    }
                }
            }

            // 由逐连接增量汇总出逐 IP / 逐进程
            foreach (ConnEntry c in active)
            {
                string ck = ConnKey(c);
                long[] cd = connDelta.ContainsKey(ck) ? connDelta[ck] : new long[2];
                perIpBytes[c.RemoteIp][0] += cd[0];
                perIpBytes[c.RemoteIp][1] += cd[1];
                string pk = ProcKey(c) + "|" + c.RemoteIp;
                if (!procIpBytes.ContainsKey(pk)) procIpBytes[pk] = new long[2];
                procIpBytes[pk][0] += cd[0];
                procIpBytes[pk][1] += cd[1];
            }

            // 更新内存数据 + 实时快照（加锁）
            lock (liveLock)
            {
                if (current.firstSampleUnix == 0) current.firstSampleUnix = unix;
                current.lastSampleUnix = unix;
                current.sampleCount++;
                current.bytesIn += deltaIn;
                current.bytesOut += deltaOut;
                if (totalInBps > current.peakInBps) current.peakInBps = totalInBps;
                if (totalOutBps > current.peakOutBps) current.peakOutBps = totalOutBps;
                if (precise) current.bytesPrecise = true;
                current.samples.Add(new long[] { unix, deltaIn, deltaOut });

                var newActive = new HashSet<string>();
                foreach (var kv in byIp)
                {
                    string ip = kv.Key;
                    var list = kv.Value;
                    newActive.Add(ip);
                    IpAggregate a;
                    if (!current.ips.ContainsKey(ip))
                    {
                        a = new IpAggregate { ip = ip };
                        current.ips[ip] = a;
                    }
                    else a = current.ips[ip];

                    a.sampleCount++;
                    a.connectedSeconds += (long)Math.Round(elapsed);
                    if (a.firstSeenUnix == 0) a.firstSeenUnix = unix;
                    a.lastSeenUnix = unix;
                    if (!prevActiveIps.Contains(ip)) a.sessionCount++;

                    long[] b = perIpBytes.ContainsKey(ip) ? perIpBytes[ip] : new long[2];
                    a.bytesIn += b[0];
                    a.bytesOut += b[1];
                    long ipInBps = (long)(b[0] / elapsed);
                    long ipOutBps = (long)(b[1] / elapsed);
                    if (ipInBps > a.peakInBps) a.peakInBps = ipInBps;
                    if (ipOutBps > a.peakOutBps) a.peakOutBps = ipOutBps;
                    a.bytesPrecise = precise;

                    GeoInfo g = geoMap.ContainsKey(ip) ? geoMap[ip] : null;
                    if (g != null && (g.Country != "" || g.City != ""))
                    {
                        a.city = g.City; a.region = g.Region; a.country = g.Country; a.isp = g.Isp;
                    }

                    var seenProc = new HashSet<string>();
                    foreach (ConnEntry c in list)
                    {
                        string pn = c.ProcessName != "" ? c.ProcessName : "(未知)";
                        if (!seenProc.Contains(pn)) { seenProc.Add(pn); IncInt(a.processes, pn); }
                        IncInt(a.states, c.State);
                        if (!a.ports.Contains(c.RemotePort)) a.ports.Add(c.RemotePort);
                    }
                }
                prevActiveIps.Clear();
                foreach (string ip in newActive) prevActiveIps.Add(ip);

                // 进程级聚合（进程名|PID -> 各远端IP）
                var byProcIp = new Dictionary<string, List<ConnEntry>>();
                foreach (ConnEntry c in active)
                {
                    string k = ProcKey(c) + "|" + c.RemoteIp;
                    if (!byProcIp.ContainsKey(k)) byProcIp[k] = new List<ConnEntry>();
                    byProcIp[k].Add(c);
                }
                foreach (var kv in byProcIp)
                {
                    List<ConnEntry> clist = kv.Value;
                    ConnEntry c0 = clist[0];
                    string pk = ProcKey(c0);
                    ProcAgg pa;
                    if (!current.procs.ContainsKey(pk))
                    {
                        pa = new ProcAgg { name = string.IsNullOrEmpty(c0.ProcessName) ? "(未知)" : c0.ProcessName, pid = c0.Pid };
                        current.procs[pk] = pa;
                    }
                    else pa = current.procs[pk];
                    if (pa.firstSeenUnix == 0) pa.firstSeenUnix = unix;
                    pa.lastSeenUnix = unix;
                    pa.connCount += clist.Count;

                    IpConnAgg ia;
                    if (!pa.ips.ContainsKey(c0.RemoteIp))
                    {
                        ia = new IpConnAgg { ip = c0.RemoteIp, proto = c0.Proto };
                        pa.ips[c0.RemoteIp] = ia;
                    }
                    else ia = pa.ips[c0.RemoteIp];
                    ia.connCount += clist.Count;
                    foreach (ConnEntry cc in clist)
                    {
                        if (!ia.ports.Contains(cc.RemotePort)) ia.ports.Add(cc.RemotePort);
                    }
                    GeoInfo g2 = geoMap.ContainsKey(c0.RemoteIp) ? geoMap[c0.RemoteIp] : null;
                    if (g2 != null && (g2.Country != "" || g2.City != ""))
                    {
                        ia.city = g2.City; ia.region = g2.Region; ia.country = g2.Country; ia.isp = g2.Isp;
                    }
                    long[] pb = procIpBytes.ContainsKey(kv.Key) ? procIpBytes[kv.Key] : new long[2];
                    ia.bytesIn += pb[0];
                    ia.bytesOut += pb[1];
                    pa.bytesIn += pb[0];
                    pa.bytesOut += pb[1];
                }

                // 构建快照
                var s = new Snapshot();
                s.IsAdmin = isAdmin;
                s.BytesPrecise = precise;
                s.TotalInBps = totalInBps;
                s.TotalOutBps = totalOutBps;
                s.TodayInBytes = current.bytesIn;
                s.TodayOutBytes = current.bytesOut;
                s.LastScan = now;
                foreach (ConnEntry c in active) s.Connections.Add(c);

                // 逐连接实时信息（累计字节 + 时长）
                var curConnKeys = new HashSet<string>();
                foreach (ConnEntry c in active)
                {
                    string ck = ConnKey(c);
                    curConnKeys.Add(ck);
                    long[] cd = connDelta.ContainsKey(ck) ? connDelta[ck] : new long[2];
                    if (!connFirstSeen.ContainsKey(ck)) connFirstSeen[ck] = unix;
                    if (!connCumBytes.ContainsKey(ck)) connCumBytes[ck] = new long[2];
                    connCumBytes[ck][0] += cd[0];
                    connCumBytes[ck][1] += cd[1];

                    var lc = new LiveConn();
                    lc.Ip = c.RemoteIp;
                    lc.RemotePort = c.RemotePort;
                    lc.LocalPort = c.LocalPort;
                    lc.Pid = c.Pid;
                    lc.ProcessName = c.ProcessName;
                    lc.State = c.State;
                    lc.Proto = c.Proto;
                    lc.BytesIn = connCumBytes[ck][0];
                    lc.BytesOut = connCumBytes[ck][1];
                    lc.DurationSeconds = unix - connFirstSeen[ck];
                    lc.SpeedInBps = (long)(cd[0] / elapsed);
                    lc.SpeedOutBps = (long)(cd[1] / elapsed);
                    GeoInfo gc = geoMap.ContainsKey(c.RemoteIp) ? geoMap[c.RemoteIp] : null;
                    if (gc != null)
                    {
                        lc.City = gc.City; lc.Region = gc.Region; lc.Country = gc.Country; lc.Isp = gc.Isp;
                    }
                    s.LiveConns.Add(lc);
                }
                // 清理已消失连接的累计/首见
                var goneConns = new List<string>();
                foreach (string k in connFirstSeen.Keys) if (!curConnKeys.Contains(k)) goneConns.Add(k);
                foreach (string k in goneConns) { connFirstSeen.Remove(k); connCumBytes.Remove(k); }
                s.LiveConns.Sort(delegate(LiveConn x, LiveConn y) { return (y.BytesIn + y.BytesOut).CompareTo(x.BytesIn + x.BytesOut); });

                foreach (var kv in byIp)
                {
                    string ip = kv.Key;
                    long[] b = perIpBytes.ContainsKey(ip) ? perIpBytes[ip] : new long[2];
                    GeoInfo g = geoMap.ContainsKey(ip) ? geoMap[ip] : null;
                    var li = new LiveIp();
                    li.Ip = ip;
                    li.ConnCount = kv.Value.Count;
                    li.BytesInDelta = b[0];
                    li.BytesOutDelta = b[1];
                    li.SpeedInBps = (long)(b[0] / elapsed);
                    li.SpeedOutBps = (long)(b[1] / elapsed);
                    if (g != null)
                    {
                        li.City = g.City; li.Region = g.Region; li.Country = g.Country; li.Isp = g.Isp;
                    }
                    s.LiveIps.Add(li);
                }
                s.LiveIps.Sort(delegate(LiveIp x, LiveIp y)
                {
                    return (y.SpeedInBps + y.SpeedOutBps).CompareTo(x.SpeedInBps + x.SpeedOutBps);
                });
                snap = s;

                Store.SaveDay(current);
            }

            Store.EnforceRetention(cfg.RetentionDays);
        }

        static void IncInt(Dictionary<string, int> d, string k)
        {
            if (!d.ContainsKey(k)) d[k] = 0;
            d[k]++;
        }

        static string ProcKey(ConnEntry c)
        {
            return (string.IsNullOrEmpty(c.ProcessName) ? "(未知)" : c.ProcessName) + "|" + c.Pid;
        }

        static string ConnKey(ConnEntry c)
        {
            return c.Pid + "|" + c.RemoteIp + "|" + c.RemotePort + "|" + c.LocalPort + "|" + c.Proto;
        }

        // ---------- 供 UI 读取（线程安全） ----------
        public Snapshot GetSnapshot()
        {
            lock (liveLock) return snap;
        }

        public List<IpAggregate> GetTodayAggregates()
        {
            lock (liveLock)
            {
                var r = new List<IpAggregate>();
                foreach (var kv in current.ips) r.Add(kv.Value);
                r.Sort(delegate(IpAggregate x, IpAggregate y) { return (y.bytesIn + y.bytesOut).CompareTo(x.bytesIn + x.bytesOut); });
                return r;
            }
        }

        public List<ProcAgg> GetTodayProcs()
        {
            lock (liveLock)
            {
                var r = new List<ProcAgg>();
                foreach (var kv in current.procs) r.Add(kv.Value);
                r.Sort(delegate(ProcAgg x, ProcAgg y) { return (y.bytesIn + y.bytesOut).CompareTo(x.bytesIn + x.bytesOut); });
                return r;
            }
        }

        public DayData GetTodaySummary()
        {
            lock (liveLock)
            {
                var c = new DayData();
                c.date = current.date;
                c.bytesIn = current.bytesIn;
                c.bytesOut = current.bytesOut;
                c.peakInBps = current.peakInBps;
                c.peakOutBps = current.peakOutBps;
                c.firstSampleUnix = current.firstSampleUnix;
                c.lastSampleUnix = current.lastSampleUnix;
                c.sampleCount = current.sampleCount;
                c.bytesPrecise = current.bytesPrecise;
                return c;
            }
        }
    }
}
