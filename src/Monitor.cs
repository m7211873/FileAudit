using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;

namespace NetWatcher
{
    // ---------- UI 只读快照 ----------

    public class LiveConn
    {
        public string Ip = "", ProcessName = "", ProcessPath = "", State = "", Proto = "";
        public string City = "", Region = "", Country = "", Isp = "", Hostname = "";
        public int Pid = 0, RemotePort = 0, LocalPort = 0;
        public long BytesIn = 0, BytesOut = 0;              // 连接生命周期内累计（精确或估算）
        public long SpeedInBps = 0, SpeedOutBps = 0;         // 本采样速率
        public long DurationSeconds = 0;
        public long FirstSeenUnix = 0;
        public bool Precise = false;
        public bool IsNew = false;
        public bool IsLocal = false;
    }

    public class LiveIp
    {
        public string Ip = "", City = "", Region = "", Country = "", Isp = "", Hostname = "";
        public string Processes = "";
        public int ConnCount = 0;
        public long BytesIn = 0, BytesOut = 0;              // 本采样增量
        public long SpeedInBps = 0, SpeedOutBps = 0;
        public bool Precise = false;
        public bool IsNew = false;
        public bool IsLocal = false;
    }

    public class Snapshot
    {
        public List<LiveConn> Conns = new List<LiveConn>();
        public List<LiveIp> LiveIps = new List<LiveIp>();
        public long TotalInBps = 0, TotalOutBps = 0;
        public long TodayInBytes = 0, TodayOutBytes = 0;
        public long PeakInBps = 0, PeakOutBps = 0;
        public bool BytesPrecise = false;
        public bool IsAdmin = false;
        public int EstablishedCount = 0;
        public int PreciseConnCount = 0;
        public DateTime LastScan = DateTime.MinValue;
        public string LastError = "";
    }

    public class Monitor
    {
        class ConnState
        {
            public long FirstSeenUnix = 0;
            public long CumIn = 0, CumOut = 0;
            public ulong LastIn = 0, LastOut = 0;
            public bool EStatsOn = false;
            public bool EnableTried = false;
        }

        readonly AppConfig cfg;
        Thread thread;
        volatile bool stop = false;
        readonly object liveLock = new object();
        readonly object historyLock = new object();

        DayData current;
        string currentDate = "";
        readonly HashSet<string> prevActiveIps = new HashSet<string>();
        readonly Dictionary<string, ConnState> connStates = new Dictionary<string, ConnState>();
        long lastTotalIn = 0, lastTotalOut = 0;
        bool haveLastTotal = false;
        DateTime lastSampleTime = DateTime.MinValue;
        long lastPersistUnix = 0;
        int persistCount = 0;
        readonly Dictionary<string, DayData> historyCache = new Dictionary<string, DayData>();
        Snapshot snap = new Snapshot();
        string lastEStatsError = "";

        public Monitor(AppConfig cfg)
        {
            this.cfg = cfg;
            current = new DayData { date = DateTime.Now.ToString("yyyy-MM-dd") };
            currentDate = current.date;
        }

        public string LastEStatsError { get { lock (liveLock) return lastEStatsError; } }

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
            lock (liveLock)
            {
                try { Store.SaveDay(current); } catch { }
            }
        }

        public static long NowUnix()
        {
            return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        }

        void Run()
        {
            while (!stop)
            {
                try { Sample(); }
                catch (Exception ex)
                {
                    lock (liveLock) { snap.LastError = ex.Message; }
                    try
                    {
                        System.IO.File.AppendAllText(System.IO.Path.Combine(Store.DataDir, "monitor.log"),
                            DateTime.Now.ToString("HH:mm:ss") + " SAMPLE ERROR: " + ex + "\r\n");
                    }
                    catch { }
                }
                int slept = 0;
                int ms = Math.Max(1, cfg.ScanIntervalSeconds) * 1000;
                while (!stop && slept < ms)
                {
                    Thread.Sleep(200);
                    slept += 200;
                }
            }
        }

        // ---------- 采样主流程 ----------
        void Sample()
        {
            NativeMethods.ClearProcessCache();
            List<ConnEntry> conns = NativeMethods.EnumTcpConnections();

            DateTime now = DateTime.Now;
            long unix = NowUnix();
            string date = now.ToString("yyyy-MM-dd");
            if (date != currentDate) RotateDay(date);

            // 活动连接筛选：记录所有"有远端"的 TCP 连接状态（ESTABLISHED / SYN_SENT / FIN_WAIT /
            // TIME_WAIT / CLOSE_WAIT 等），只排除 LISTEN。这样与资源监视器的口径更接近，
            // 短命连接在采样瞬间也能被抓到；字节统计仍只对 ESTABLISHED 做差分。
            List<ConnEntry> active = new List<ConnEntry>();
            List<ConnEntry> established = new List<ConnEntry>();
            for (int i = 0; i < conns.Count; i++)
            {
                ConnEntry c = conns[i];
                if (c.State == "LISTEN" || c.State == "CLOSED") continue;
                string rip = GeoIp.NormalizeIp(c.RemoteIp);
                if (string.IsNullOrEmpty(rip) || rip == "0.0.0.0" || rip == "::") continue;
                if (rip == "127.0.0.1" || rip == "::1") continue;
                if (!cfg.ShowLocalIp && GeoIp.IsLocalIp(rip)) continue;
                c.RemoteIp = rip;
                active.Add(c);
                if (c.State == "ESTABLISHED") established.Add(c);
            }

            // 总流量与速率
            long tin, tout;
            NativeMethods.GetTotalBytes(out tin, out tout);
            double elapsed = cfg.ScanIntervalSeconds;
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

            bool isAdmin = NativeMethods.IsAdministrator();

            // 逐连接差分（精确模式）或均分估算
            Dictionary<string, long[]> connDelta = new Dictionary<string, long[]>(); // [in, out]
            int preciseCount = 0;

            // 每条活动连接都建状态（记录首见时间、累计字节），IPv6 连接也建
            HashSet<string> curKeys = new HashSet<string>();
            for (int i = 0; i < active.Count; i++)
            {
                string key = ConnKey(active[i]);
                curKeys.Add(key);
                if (!connStates.ContainsKey(key))
                {
                    ConnState nst = new ConnState();
                    nst.FirstSeenUnix = unix;
                    connStates[key] = nst;
                }
            }

            if (isAdmin)
            {
                for (int i = 0; i < established.Count; i++)
                {
                    ConnEntry c = established[i];
                    if (c.Proto != "TCP") continue;
                    string key = ConnKey(c);
                    ConnState st = connStates[key];
                    if (!st.EStatsOn)
                    {
                        uint erc; int eerr;
                        if (NativeMethods.EStatsEnable(c, out erc, out eerr))
                        {
                            st.EStatsOn = true;
                        }
                        else
                        {
                            lastEStatsError = "EStatsEnable 失败 rc=" + erc + " winerr=" + eerr
                                + " | " + (NativeMethods.EStatsDiag.Length > 300 ? NativeMethods.EStatsDiag.Substring(0, 300) : NativeMethods.EStatsDiag);
                        }
                    }
                    ulong o, ii; uint rc = 0; int werr = 0;
                    if (st.EStatsOn && NativeMethods.EStatsRead(c, out o, out ii, out rc, out werr))
                    {
                        long dIn = 0, dOut = 0;
                        if (st.LastIn > 0 || st.LastOut > 0)
                        {
                            if (ii >= st.LastIn) dIn = (long)(ii - st.LastIn);
                            if (o >= st.LastOut) dOut = (long)(o - st.LastOut);
                        }
                        st.LastIn = ii; st.LastOut = o;
                        st.CumIn += dIn; st.CumOut += dOut;
                        connDelta[key] = new long[] { dIn, dOut };
                        preciseCount++;
                    }
                    else if (st.EStatsOn)
                    {
                        lastEStatsError = "EStatsRead 失败 rc=" + rc + " winerr=" + werr;
                    }
                }
            }

            bool precise = preciseCount > 0;

            // 非精确时：按 ESTABLISHED 连接数均分总流量（明确标注"估算"；余数给最后一条，保证合计不丢字节）
            if (!precise && established.Count > 0)
            {
                long sIn = deltaIn / established.Count;
                long sOut = deltaOut / established.Count;
                long remIn = deltaIn, remOut = deltaOut;
                for (int i = 0; i < established.Count; i++)
                {
                    ConnEntry c = established[i];
                    long aIn = sIn, aOut = sOut;
                    if (i == established.Count - 1) { aIn = remIn; aOut = remOut; }
                    remIn -= aIn; remOut -= aOut;
                    string key = ConnKey(c);
                    connDelta[key] = new long[] { aIn, aOut };
                    ConnState st;
                    if (!connStates.TryGetValue(key, out st))
                    {
                        st = new ConnState();
                        st.FirstSeenUnix = unix;
                        connStates[key] = st;
                    }
                    st.CumIn += aIn; st.CumOut += aOut;
                }
            }

            // 清理已消失连接的累计状态（每个采样周期一次）
            List<string> goneKeys = new List<string>();
            foreach (string k in connStates.Keys) if (!curKeys.Contains(k)) goneKeys.Add(k);
            for (int i = 0; i < goneKeys.Count; i++) connStates.Remove(goneKeys[i]);

            // 按 IP / 进程汇总增量
            Dictionary<string, List<ConnEntry>> byIp = new Dictionary<string, List<ConnEntry>>();
            for (int i = 0; i < active.Count; i++)
            {
                ConnEntry c = active[i];
                List<ConnEntry> l;
                if (!byIp.TryGetValue(c.RemoteIp, out l)) { l = new List<ConnEntry>(); byIp[c.RemoteIp] = l; }
                l.Add(c);
            }
            Dictionary<string, long[]> perIpBytes = new Dictionary<string, long[]>();
            foreach (string ip in byIp.Keys) perIpBytes[ip] = new long[2];
            Dictionary<string, long[]> procIpBytes = new Dictionary<string, long[]>();
            Dictionary<string, long[]> procBytes = new Dictionary<string, long[]>();
            Dictionary<string, HashSet<string>> procConnKeys = new Dictionary<string, HashSet<string>>();

            for (int i = 0; i < active.Count; i++)
            {
                ConnEntry c = active[i];
                string key = ConnKey(c);
                long[] d = connDelta.ContainsKey(key) ? connDelta[key] : new long[2];
                perIpBytes[c.RemoteIp][0] += d[0];
                perIpBytes[c.RemoteIp][1] += d[1];
                string pk = ProcKey(c);
                if (!procBytes.ContainsKey(pk)) procBytes[pk] = new long[2];
                procBytes[pk][0] += d[0]; procBytes[pk][1] += d[1];
                string ipk = pk + "|" + c.RemoteIp;
                if (!procIpBytes.ContainsKey(ipk)) procIpBytes[ipk] = new long[2];
                procIpBytes[ipk][0] += d[0]; procIpBytes[ipk][1] += d[1];
                if (!procConnKeys.ContainsKey(pk)) procConnKeys[pk] = new HashSet<string>();
                procConnKeys[pk].Add(key);
            }

            // GeoIP（缓存命中即可，未命中入队后台解析）
            Dictionary<string, GeoInfo> geoMap = new Dictionary<string, GeoInfo>();
            foreach (string ip in byIp.Keys) geoMap[ip] = GeoIp.Lookup(ip);

            DayData toSave = null;
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

                // 分钟桶（最多 1440 条 = 24 小时）
                long minute = unix - (unix % 60);
                if (current.samples.Count == 0 || current.samples[current.samples.Count - 1][0] != minute)
                    current.samples.Add(new long[] { minute, deltaIn, deltaOut });
                else
                {
                    long[] lastb = current.samples[current.samples.Count - 1];
                    lastb[1] += deltaIn; lastb[2] += deltaOut;
                }
                while (current.samples.Count > 1440) current.samples.RemoveAt(0);

                // 逐 IP 聚合
                HashSet<string> newActive = new HashSet<string>();
                foreach (KeyValuePair<string, List<ConnEntry>> kv in byIp)
                {
                    string ip = kv.Key;
                    List<ConnEntry> list = kv.Value;
                    newActive.Add(ip);

                    IpAggregate a;
                    if (!current.ips.TryGetValue(ip, out a)) { a = new IpAggregate(); a.ip = ip; current.ips[ip] = a; }

                    a.sampleCount++;
                    a.connectedSeconds += (long)Math.Round(elapsed);
                    if (a.firstSeenUnix == 0)
                    {
                        a.firstSeenUnix = unix;
                        a.isNew = true;
                    }
                    a.lastSeenUnix = unix;
                    if (!prevActiveIps.Contains(ip))
                    {
                        a.sessionCount++;
                        a.isNew = true;
                    }

                    long[] b = perIpBytes[ip];
                    a.bytesIn += b[0];
                    a.bytesOut += b[1];
                    if (elapsed > 0)
                    {
                        long ipInBps = (long)(b[0] / elapsed);
                        long ipOutBps = (long)(b[1] / elapsed);
                        if (ipInBps > a.peakInBps) a.peakInBps = ipInBps;
                        if (ipOutBps > a.peakOutBps) a.peakOutBps = ipOutBps;
                    }
                    if (precise) a.bytesPrecise = true;

                    GeoInfo g;
                    if (geoMap.TryGetValue(ip, out g) && g != null && (g.Country.Length > 0 || g.City.Length > 0))
                    {
                        a.city = g.City; a.region = g.Region; a.country = NormalizeCn(g.Country); a.isp = g.Isp;
                        if (!string.IsNullOrEmpty(g.Host)) a.hostname = g.Host;
                    }

                    for (int j = 0; j < list.Count; j++)
                    {
                        ConnEntry c = list[j];
                        string pn = string.IsNullOrEmpty(c.ProcessName) ? "(未知)" : c.ProcessName;
                        if (!a.processes.ContainsKey(pn)) a.processes[pn] = 0;
                        a.processes[pn]++;
                        if (!a.states.ContainsKey(c.State)) a.states[c.State] = 0;
                        a.states[c.State]++;
                        if (!a.ports.Contains(c.RemotePort)) a.ports.Add(c.RemotePort);
                    }
                }
                prevActiveIps.Clear();
                foreach (string ip in newActive) prevActiveIps.Add(ip);

                // 逐进程聚合
                foreach (KeyValuePair<string, List<ConnEntry>> kv in byIp)
                {
                    for (int j = 0; j < kv.Value.Count; j++)
                    {
                        ConnEntry c = kv.Value[j];
                        string pk = ProcKey(c);
                        ProcAgg pa;
                        if (!current.procs.TryGetValue(pk, out pa))
                        {
                            pa = new ProcAgg();
                            pa.name = string.IsNullOrEmpty(c.ProcessName) ? "(未知)" : c.ProcessName;
                            pa.path = c.ProcessPath;
                            pa.pid = c.Pid;
                            pa.processStartUnix = c.ProcessStartUnix;
                            current.procs[pk] = pa;
                        }
                        if (pa.firstSeenUnix == 0) pa.firstSeenUnix = unix;
                        pa.lastSeenUnix = unix;

                        IpConnAgg ia;
                        if (!pa.ips.TryGetValue(c.RemoteIp, out ia))
                        {
                            ia = new IpConnAgg();
                            ia.ip = c.RemoteIp;
                            ia.proto = c.Proto;
                            ia.firstSeenUnix = unix;
                            pa.ips[c.RemoteIp] = ia;
                        }
                        GeoInfo g;
                        if (geoMap.TryGetValue(c.RemoteIp, out g) && g != null)
                        {
                            ia.city = g.City; ia.region = g.Region; ia.country = NormalizeCn(g.Country);
                            ia.isp = g.Isp; ia.hostname = g.Host;
                        }
                        if (!ia.ports.Contains(c.RemotePort)) ia.ports.Add(c.RemotePort);

                        // 连接次数：同一连接只计一次（用 connStates 的首见时间判断）
                        ConnState cs;
                        if (connStates.TryGetValue(ConnKey(c), out cs) && cs.FirstSeenUnix == unix)
                        {
                            ia.connCount++;
                            pa.connCount++;
                        }
                    }
                }
                foreach (KeyValuePair<string, long[]> kv in procBytes)
                {
                    ProcAgg pa;
                    if (current.procs.TryGetValue(kv.Key, out pa))
                    {
                        pa.bytesIn += kv.Value[0];
                        pa.bytesOut += kv.Value[1];
                    }
                }
                foreach (KeyValuePair<string, long[]> kv in procIpBytes)
                {
                    int bar = kv.Key.LastIndexOf('|');
                    if (bar <= 0) continue;
                    string pk = kv.Key.Substring(0, bar);
                    string ip = kv.Key.Substring(bar + 1);
                    ProcAgg pa;
                    if (!current.procs.TryGetValue(pk, out pa)) continue;
                    IpConnAgg ia;
                    if (!pa.ips.TryGetValue(ip, out ia)) continue;
                    ia.bytesIn += kv.Value[0];
                    ia.bytesOut += kv.Value[1];
                }

                // 快照
                Snapshot s = new Snapshot();
                s.IsAdmin = isAdmin;
                s.BytesPrecise = precise || current.bytesPrecise;
                s.TotalInBps = totalInBps;
                s.TotalOutBps = totalOutBps;
                s.TodayInBytes = current.bytesIn;
                s.TodayOutBytes = current.bytesOut;
                s.PeakInBps = current.peakInBps;
                s.PeakOutBps = current.peakOutBps;
                s.LastScan = now;
                s.EstablishedCount = established.Count;
                s.PreciseConnCount = preciseCount;
                s.LastError = lastEStatsError;

                for (int i = 0; i < active.Count; i++)
                {
                    ConnEntry c = active[i];
                    string key = ConnKey(c);
                    ConnState st;
                    connStates.TryGetValue(key, out st);
                    long[] d = connDelta.ContainsKey(key) ? connDelta[key] : new long[2];

                    LiveConn lc = new LiveConn();
                    lc.Ip = c.RemoteIp;
                    lc.RemotePort = c.RemotePort;
                    lc.LocalPort = c.LocalPort;
                    lc.Pid = c.Pid;
                    lc.ProcessName = c.ProcessName;
                    lc.ProcessPath = c.ProcessPath;
                    lc.State = c.State;
                    lc.Proto = c.Proto;
                    lc.BytesIn = st != null ? st.CumIn : 0;
                    lc.BytesOut = st != null ? st.CumOut : 0;
                    lc.FirstSeenUnix = st != null ? st.FirstSeenUnix : unix;
                    lc.DurationSeconds = unix - lc.FirstSeenUnix;
                    lc.SpeedInBps = (long)(d[0] / elapsed);
                    lc.SpeedOutBps = (long)(d[1] / elapsed);
                    lc.Precise = precise && (st != null && st.EStatsOn);
                    lc.IsLocal = GeoIp.IsLocalIp(c.RemoteIp);
                    GeoInfo g;
                    if (geoMap.TryGetValue(c.RemoteIp, out g) && g != null)
                    {
                        lc.City = g.City; lc.Region = g.Region; lc.Country = NormalizeCn(g.Country);
                        lc.Isp = g.Isp; lc.Hostname = g.Host;
                    }
                    IpAggregate ia2;
                    if (current.ips.TryGetValue(c.RemoteIp, out ia2)) lc.IsNew = ia2.isNew;
                    s.Conns.Add(lc);
                }
                s.Conns.Sort(delegate(LiveConn x, LiveConn y) { return (y.BytesIn + y.BytesOut).CompareTo(x.BytesIn + x.BytesOut); });

                foreach (KeyValuePair<string, List<ConnEntry>> kv in byIp)
                {
                    string ip = kv.Key;
                    LiveIp li = new LiveIp();
                    li.Ip = ip;
                    li.ConnCount = kv.Value.Count;
                    long[] b = perIpBytes[ip];
                    li.BytesIn = b[0]; li.BytesOut = b[1];
                    li.SpeedInBps = (long)(b[0] / elapsed);
                    li.SpeedOutBps = (long)(b[1] / elapsed);
                    li.IsLocal = GeoIp.IsLocalIp(ip);
                    li.Precise = precise;
                    GeoInfo g;
                    if (geoMap.TryGetValue(ip, out g) && g != null)
                    {
                        li.City = g.City; li.Region = g.Region; li.Country = NormalizeCn(g.Country);
                        li.Isp = g.Isp; li.Hostname = g.Host;
                    }
                    IpAggregate a2;
                    if (current.ips.TryGetValue(ip, out a2)) li.IsNew = a2.isNew;
                    // 进程名列表（按连接数取前 4）
                    Dictionary<string, int> pn = new Dictionary<string, int>();
                    for (int j = 0; j < kv.Value.Count; j++)
                    {
                        string nm = string.IsNullOrEmpty(kv.Value[j].ProcessName) ? "(未知)" : kv.Value[j].ProcessName;
                        if (!pn.ContainsKey(nm)) pn[nm] = 0;
                        pn[nm]++;
                    }
                    List<KeyValuePair<string, int>> pl = new List<KeyValuePair<string, int>>(pn);
                    pl.Sort(delegate(KeyValuePair<string, int> x, KeyValuePair<string, int> y) { return y.Value.CompareTo(x.Value); });
                    StringBuilder psb = new StringBuilder();
                    for (int j = 0; j < pl.Count && j < 4; j++)
                    {
                        if (psb.Length > 0) psb.Append(", ");
                        psb.Append(pl[j].Key);
                    }
                    if (pl.Count > 4) psb.Append(" ...");
                    li.Processes = psb.ToString();
                    s.LiveIps.Add(li);
                }
                s.LiveIps.Sort(delegate(LiveIp x, LiveIp y)
                {
                    return (y.SpeedInBps + y.SpeedOutBps).CompareTo(x.SpeedInBps + x.SpeedOutBps);
                });
                snap = s;

                // 落盘节流：至少 15 秒一次
                if (unix - lastPersistUnix >= 15)
                {
                    lastPersistUnix = unix;
                    persistCount++;
                    toSave = current.Clone();
                }
            }

            if (toSave != null)
            {
                Store.SaveDay(toSave);
                if (persistCount % 20 == 0) Store.EnforceRetention(cfg.RetentionDays);
            }
        }

        static readonly Dictionary<string, string> CnFix = new Dictionary<string, string>
        {
            { "中華人民共和國", "中国" },
            { "中國", "中国" },
            { "美國", "美国" },
            { "日本", "日本" },
            { "韓國", "韩国" },
            { "俄羅斯", "俄罗斯" },
            { "英國", "英国" },
            { "法國", "法国" },
            { "德國", "德国" },
            { "澳洲", "澳大利亚" },
            { "澳大利亞", "澳大利亚" },
        };

        static string NormalizeCn(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            string v;
            if (CnFix.TryGetValue(s, out v)) return v;
            return s;
        }

        static string ProcKey(ConnEntry c)
        {
            string n = string.IsNullOrEmpty(c.ProcessName) ? "(未知)" : c.ProcessName;
            return n + "|" + c.Pid + "|" + c.ProcessStartUnix;
        }

        static string ConnKey(ConnEntry c)
        {
            return c.Pid + "|" + c.RemoteIp + "|" + c.RemotePort + "|" + c.LocalPort + "|" + c.Proto;
        }

        void RotateDay(string date)
        {
            lock (liveLock)
            {
                try { Store.SaveDay(current); } catch { }
                current = Store.LoadDay(date);
                currentDate = date;
                prevActiveIps.Clear();
                connStates.Clear();
                haveLastTotal = false;
                lastSampleTime = DateTime.MinValue;
                lastPersistUnix = 0;
                lock (historyLock) historyCache.Clear();
            }
        }

        // ---------- 查询接口（线程安全，返回副本） ----------

        public Snapshot GetSnapshot()
        {
            lock (liveLock) return snap;
        }

        public DayData GetDay(string date)
        {
            lock (liveLock)
            {
                if (date == currentDate) return current.Clone();
                return Store.LoadDay(date);
            }
        }

        public DayData TodaySnapshot()
        {
            lock (liveLock) return current.Clone();
        }

        public List<IpAggregate> GetDayIps(string date)
        {
            DayData d;
            lock (liveLock)
            {
                if (date == currentDate) d = current.Clone();
                else d = null;
            }
            if (d == null) d = Store.LoadDay(date);
            List<IpAggregate> list = new List<IpAggregate>(d.ips.Values);
            list.Sort(delegate(IpAggregate x, IpAggregate y) { return (y.bytesIn + y.bytesOut).CompareTo(x.bytesIn + x.bytesOut); });
            return list;
        }

        public List<ProcAgg> GetDayProcs(string date)
        {
            DayData d;
            lock (liveLock)
            {
                if (date == currentDate) d = current.Clone();
                else d = null;
            }
            if (d == null) d = Store.LoadDay(date);
            List<ProcAgg> list = new List<ProcAgg>(d.procs.Values);
            list.Sort(delegate(ProcAgg x, ProcAgg y) { return (y.bytesIn + y.bytesOut).CompareTo(x.bytesIn + x.bytesOut); });
            return list;
        }

        public List<DayData> GetHistory()
        {
            List<DayData> result = new List<DayData>();
            string today;
            lock (liveLock) today = currentDate;
            List<string> dates = Store.ListDates();
            lock (historyLock)
            {
                List<string> keep = new List<string>();
                foreach (string dt in dates)
                {
                    keep.Add(dt);
                    DayData cached;
                    if (!historyCache.TryGetValue(dt, out cached))
                    {
                        DayData full = Store.LoadDay(dt);
                        cached = full.SummaryOnly();
                        historyCache[dt] = cached;
                    }
                    result.Add(cached);
                }
                List<string> stale = new List<string>();
                foreach (string k in historyCache.Keys) if (!keep.Contains(k)) stale.Add(k);
                for (int i = 0; i < stale.Count; i++) historyCache.Remove(stale[i]);
            }
            // 今天如果还没落盘，用内存汇总补上
            if (!dates.Contains(today))
            {
                lock (liveLock) result.Insert(0, current.SummaryOnly());
            }
            else
            {
                lock (liveLock) result[0] = current.SummaryOnly();
            }
            return result;
        }
    }
}
