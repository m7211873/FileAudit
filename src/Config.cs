using System;
using System.Collections.Generic;
using System.IO;

namespace NetWatcher
{
    public class AppConfig
    {
        // 采样间隔：1 / 2 / 5 / 10 / 30 / 60 秒（默认 2 秒；越短越不容易漏掉短命连接）
        public int ScanIntervalSeconds = 2;
        public bool AutoStart = false;
        public int RetentionDays = 0;            // 0 = 永久保留
        public bool StartMinimized = false;
        public bool GeoEnabled = true;
        public bool NewIpAlert = true;           // 新公网 IP 首次出现时托盘气泡
        public bool ShowLocalIp = true;          // 是否把内网/本机地址也列出来
        public string GeoApi = "http://ip-api.com/json/{0}?fields=status,message,country,regionName,city,isp,lat,lon&lang=zh-CN";
        public string DataDir = "";              // 空 = 默认 %APPDATA%\NetWatcher（仅内存，不落盘）

        public static readonly int[] AllowedIntervals = new int[] { 1, 2, 5, 10, 30, 60 };

        public static string DefaultDataDir()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "NetWatcher");
        }

        public string EffectiveDataDir()
        {
            if (!string.IsNullOrEmpty(DataDir)) return DataDir;
            return DefaultDataDir();
        }

        public string ConfigPath()
        {
            return Path.Combine(EffectiveDataDir(), "config.json");
        }

        public static int NormalizeInterval(int v)
        {
            for (int i = 0; i < AllowedIntervals.Length; i++)
            {
                if (AllowedIntervals[i] == v) return v;
            }
            // 兼容 1.0 的 60/300 等旧值：落到最近的合法值
            if (v <= 1) return 1;
            if (v < 4) return 2;
            if (v < 8) return 5;
            if (v < 20) return 10;
            if (v < 45) return 30;
            return 60;
        }

        public static AppConfig Load(string dataDir)
        {
            AppConfig c = new AppConfig();
            if (!string.IsNullOrEmpty(dataDir)) c.DataDir = dataDir;
            try
            {
                string p = c.ConfigPath();
                if (File.Exists(p))
                {
                    Dictionary<string, object> raw = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(p));
                    if (raw != null)
                    {
                        if (raw.ContainsKey("ScanIntervalSeconds")) c.ScanIntervalSeconds = Convert.ToInt32(raw["ScanIntervalSeconds"]);
                        if (raw.ContainsKey("AutoStart")) c.AutoStart = Convert.ToBoolean(raw["AutoStart"]);
                        if (raw.ContainsKey("RetentionDays")) c.RetentionDays = Convert.ToInt32(raw["RetentionDays"]);
                        if (raw.ContainsKey("StartMinimized")) c.StartMinimized = Convert.ToBoolean(raw["StartMinimized"]);
                        if (raw.ContainsKey("GeoEnabled")) c.GeoEnabled = Convert.ToBoolean(raw["GeoEnabled"]);
                        if (raw.ContainsKey("GeoApi")) c.GeoApi = Convert.ToString(raw["GeoApi"]);
                        if (raw.ContainsKey("NewIpAlert")) c.NewIpAlert = Convert.ToBoolean(raw["NewIpAlert"]);
                        if (raw.ContainsKey("ShowLocalIp")) c.ShowLocalIp = Convert.ToBoolean(raw["ShowLocalIp"]);
                    }
                }
            }
            catch { }
            c.ScanIntervalSeconds = NormalizeInterval(c.ScanIntervalSeconds);
            if (c.RetentionDays < 0) c.RetentionDays = 0;
            if (c.RetentionDays > 3650) c.RetentionDays = 3650;
            return c;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(EffectiveDataDir());
                Dictionary<string, object> d = new Dictionary<string, object>();
                d["ScanIntervalSeconds"] = ScanIntervalSeconds;
                d["AutoStart"] = AutoStart;
                d["RetentionDays"] = RetentionDays;
                d["StartMinimized"] = StartMinimized;
                d["GeoEnabled"] = GeoEnabled;
                d["GeoApi"] = GeoApi;
                d["NewIpAlert"] = NewIpAlert;
                d["ShowLocalIp"] = ShowLocalIp;
                string text = Json.Serialize(d);
                string tmp = ConfigPath() + ".tmp";
                File.WriteAllText(tmp, text);
                if (File.Exists(ConfigPath())) File.Delete(ConfigPath());
                File.Move(tmp, ConfigPath());
            }
            catch { }
        }
    }
}
