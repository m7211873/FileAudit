using System;
using System.Collections.Generic;
using System.IO;

namespace NetWatcher
{
    public class AppConfig
    {
        public int ScanIntervalSeconds = 60;     // 60 或 300
        public bool AutoStart = false;
        public int RetentionDays = 0;            // 0 = 永久保留
        public bool StartMinimized = false;
        public bool GeoEnabled = true;
        public string GeoApi = "http://ip-api.com/json/{0}?fields=status,message,country,regionName,city,isp,lat,lon&lang=zh-CN";
        public string DataDir = "";              // 空 = 默认 %APPDATA%\NetWatcher（仅内存，不落盘）

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

        public static AppConfig Load(string dataDir)
        {
            AppConfig c = new AppConfig();
            if (!string.IsNullOrEmpty(dataDir)) c.DataDir = dataDir;
            try
            {
                string p = c.ConfigPath();
                if (File.Exists(p))
                {
                    var ser = new System.Web.Script.Serialization.JavaScriptSerializer();
                    var raw = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(p));
                    if (raw != null)
                    {
                        if (raw.ContainsKey("ScanIntervalSeconds")) c.ScanIntervalSeconds = Convert.ToInt32(raw["ScanIntervalSeconds"]);
                        if (raw.ContainsKey("AutoStart")) c.AutoStart = Convert.ToBoolean(raw["AutoStart"]);
                        if (raw.ContainsKey("RetentionDays")) c.RetentionDays = Convert.ToInt32(raw["RetentionDays"]);
                        if (raw.ContainsKey("StartMinimized")) c.StartMinimized = Convert.ToBoolean(raw["StartMinimized"]);
                        if (raw.ContainsKey("GeoEnabled")) c.GeoEnabled = Convert.ToBoolean(raw["GeoEnabled"]);
                        if (raw.ContainsKey("GeoApi")) c.GeoApi = Convert.ToString(raw["GeoApi"]);
                    }
                }
            }
            catch { }
            if (c.ScanIntervalSeconds < 10) c.ScanIntervalSeconds = 60;
            if (c.ScanIntervalSeconds > 3600) c.ScanIntervalSeconds = 3600;
            return c;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(EffectiveDataDir());
                var ser = new System.Web.Script.Serialization.JavaScriptSerializer();
                var d = new Dictionary<string, object>();
                d["ScanIntervalSeconds"] = ScanIntervalSeconds;
                d["AutoStart"] = AutoStart;
                d["RetentionDays"] = RetentionDays;
                d["StartMinimized"] = StartMinimized;
                d["GeoEnabled"] = GeoEnabled;
                d["GeoApi"] = GeoApi;
                File.WriteAllText(ConfigPath(), ser.Serialize(d));
            }
            catch { }
        }
    }
}
