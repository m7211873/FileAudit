using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace NetWatcher
{
    public class GeoInfo
    {
        public string Country = "", Region = "", City = "", Isp = "", Lat = "", Lon = "";
        public string Host = "";     // 预留：反向解析/域名（当前版本为空）
        public string Source = ""; // local / cache / pending / disabled / error

        public string Display()
        {
            if (Source == "local") return "本地/内网地址";
            string loc = Join(Country, Region, City);
            string isp = string.IsNullOrEmpty(Isp) ? "" : (" · " + Isp);
            if (string.IsNullOrEmpty(loc) && string.IsNullOrEmpty(isp)) return "未知";
            return loc + isp;
        }

        static string Join(params string[] parts)
        {
            var sb = new StringBuilder();
            foreach (string p in parts)
            {
                if (string.IsNullOrEmpty(p)) continue;
                if (sb.Length > 0) sb.Append(" ");
                sb.Append(p);
            }
            return sb.ToString();
        }
    }

    public static class GeoIp
    {
        static Dictionary<string, Dictionary<string, object>> Cache = new Dictionary<string, Dictionary<string, object>>();
        static readonly object Lock = new object();
        static readonly object QueueLock = new object();
        static readonly Queue<string> Pending = new Queue<string>();
        static readonly HashSet<string> PendingSet = new HashSet<string>();
        static string CachePath = "";
        static string ApiFormat = "";
        public static bool Enabled = true;
        static Thread resolver;
        static volatile bool stop = false;

        public static void Init(string dataDir, string apiFormat, bool enabled)
        {
            CachePath = Path.Combine(dataDir, "geocache.json");
            ApiFormat = apiFormat;
            Enabled = enabled;
            lock (Lock)
            {
                Cache.Clear();
                try
                {
                    if (File.Exists(CachePath))
                    {
                        var ser = new JavaScriptSerializer();
                        var d = ser.Deserialize<Dictionary<string, Dictionary<string, object>>>(File.ReadAllText(CachePath));
                        if (d != null) Cache = d;
                    }
                }
                catch { }
            }
            StartResolver();
        }

        static void StartResolver()
        {
            if (resolver != null || !Enabled) return;
            resolver = new Thread(ResolverLoop);
            resolver.IsBackground = true;
            resolver.Name = "GeoIpResolver";
            resolver.Start();
        }

        static void Enqueue(string ip)
        {
            lock (QueueLock)
            {
                if (!PendingSet.Contains(ip))
                {
                    PendingSet.Add(ip);
                    Pending.Enqueue(ip);
                }
            }
        }

        static void ResolverLoop()
        {
            while (!stop)
            {
                string ip = null;
                lock (QueueLock)
                {
                    if (Pending.Count > 0) ip = Pending.Dequeue();
                }
                if (ip == null) { Thread.Sleep(400); continue; }
                ResolveOne(ip);
                lock (QueueLock) { PendingSet.Remove(ip); }
                Thread.Sleep(200);
            }
        }

        // 非阻塞：缓存命中立即返回；未命中则入队后台解析，返回 pending
        public static GeoInfo Lookup(string ip)
        {
            GeoInfo g = new GeoInfo();
            if (string.IsNullOrEmpty(ip)) { g.Source = "local"; return g; }
            if (IsLocalIp(ip)) { g.Country = "本地"; g.City = "内网/本机"; g.Source = "local"; return g; }
            lock (Lock)
            {
                if (Cache.ContainsKey(ip)) { Fill(g, Cache[ip]); g.Source = "cache"; return g; }
            }
            if (!Enabled) { g.Source = "disabled"; return g; }
            Enqueue(ip);
            g.Source = "pending";
            return g;
        }

        // 阻塞：立即联网解析（自检用）
        public static GeoInfo LookupSync(string ip)
        {
            GeoInfo g = new GeoInfo();
            if (string.IsNullOrEmpty(ip)) { g.Source = "local"; return g; }
            if (IsLocalIp(ip)) { g.Country = "本地"; g.City = "内网/本机"; g.Source = "local"; return g; }
            lock (Lock)
            {
                if (Cache.ContainsKey(ip)) { Fill(g, Cache[ip]); g.Source = "cache"; return g; }
            }
            if (!Enabled) { g.Source = "disabled"; return g; }
            if (ResolveOne(ip))
            {
                lock (Lock)
                {
                    if (Cache.ContainsKey(ip)) { Fill(g, Cache[ip]); g.Source = "cache"; return g; }
                }
            }
            g.Source = "error";
            return g;
        }

        // 联网解析单个 IP；成功写入缓存并返回 true
        static bool ResolveOne(string ip)
        {
            try
            {
                lock (Lock) { if (Cache.ContainsKey(ip)) return true; }
                string url = string.Format(ApiFormat, Uri.EscapeDataString(ip));
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                // 关键：本机系统代理可能指向不可用地址，必须显式绕过，否则必然超时
                req.Proxy = null;
                req.Timeout = 8000;
                req.ReadWriteTimeout = 8000;
                req.UserAgent = "NetWatcher/2.1";
                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                {
                    string s = sr.ReadToEnd();
                    var ser = new JavaScriptSerializer();
                    var d = ser.Deserialize<Dictionary<string, object>>(s);
                    if (d != null && GetStr(d, "status") == "success")
                    {
                        lock (Lock) { Cache[ip] = d; SaveCache(); }
                        return true;
                    }
                    LastError = "status!=success: " + (s.Length > 120 ? s.Substring(0, 120) : s);
                }
            }
            catch (Exception ex)
            {
                LastError = ex.GetType().Name + ": " + ex.Message;
            }
            return false;
        }

        public static string LastError = "";

        static void SaveCache()
        {
            try { File.WriteAllText(CachePath, Json.Serialize(Cache)); }
            catch { }
        }

        static void Fill(GeoInfo g, Dictionary<string, object> d)
        {
            g.Country = GetStr(d, "country");
            g.Region = GetStr(d, "regionName");
            g.City = GetStr(d, "city");
            g.Isp = GetStr(d, "isp");
            g.Lat = GetStr(d, "lat");
            g.Lon = GetStr(d, "lon");
        }

        static string GetStr(Dictionary<string, object> d, string k)
        {
            if (d != null && d.ContainsKey(k) && d[k] != null) return Convert.ToString(d[k]);
            return "";
        }

        // 2.1 修复（P1-8）：运行时开关归属地识别（设置保存后立即生效，不必重启）
        public static void SetEnabled(bool enabled)
        {
            Enabled = enabled;
            if (enabled) StartResolver();
        }

        public static bool IsLocalIp(string ip)
        {
            if (string.IsNullOrEmpty(ip)) return true;
            if (ip == "0.0.0.0" || ip == "::" || ip == "::1") return true;
            if (ip.StartsWith("127.")) return true;
            if (ip.StartsWith("169.254.")) return true;              // 链路本地
            if (ip.StartsWith("10.")) return true;
            if (ip.StartsWith("192.168.")) return true;
            if (ip.StartsWith("fe80:") || ip.StartsWith("fc") || ip.StartsWith("fd")) return true; // IPv6 link-local/ULA
            // 172.16.0.0 - 172.31.255.255
            string[] p = ip.Split('.');
            if (p.Length == 4)
            {
                int b1, b2;
                if (int.TryParse(p[0], out b1) && b1 == 172 && int.TryParse(p[1], out b2) && b2 >= 16 && b2 <= 31) return true;
            }
            return false;
        }

        // 将 IPv4-mapped IPv6 (::ffff:1.2.3.4) 还原为 IPv4，便于归类与显示
        public static string NormalizeIp(string ip)
        {
            if (string.IsNullOrEmpty(ip)) return ip;
            if (ip.StartsWith("::ffff:")) return ip.Substring(7);
            return ip;
        }
    }
}
