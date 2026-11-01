using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace NetWatcher
{
    // ---------- 聚合模型（DayData 同构；2.3.0 起序列化进加密小时文件 .nwipdb） ----------

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
        // 2.3.0：小时文件（.nwipdb）元数据。旧 JSON 日文件没有这两个字段（默认 0）。
        public long hourStartUnix = 0;           // 本文件所属小时的本地整点（unix 秒；0 = legacy 日块）
        public long sessionStartUnix = 0;        // 本文件对应程序启动时间（unix 秒；0 = legacy 日块）
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
            d.date = date; d.hourStartUnix = hourStartUnix; d.sessionStartUnix = sessionStartUnix;
            d.bytesIn = bytesIn; d.bytesOut = bytesOut;
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
            d.date = date; d.hourStartUnix = hourStartUnix; d.sessionStartUnix = sessionStartUnix;
            d.bytesIn = bytesIn; d.bytesOut = bytesOut;
            d.peakInBps = peakInBps; d.peakOutBps = peakOutBps;
            d.firstSampleUnix = firstSampleUnix; d.lastSampleUnix = lastSampleUnix;
            d.sampleCount = sampleCount; d.bytesPrecise = bytesPrecise;
            d.ipCount = ips.Count; d.procCount = procs.Count;
            return d;
        }
    }

    // ---------- 存储（2.3.0：加密小时文件 .nwipdb；旧 JSON 兼容/迁移） ----------

    /// <summary>
    /// 存储层（2.3.0）。
    /// 层1：明文头（76B，仅元数据，不含 IP/进程明细，供历史概览免解密快速读取）；
    /// 层2：AES-256-CBC(PKCS7) 加密的 GZip(JSON(DayData))，IP/进程明细全在密文里；
    /// 层3：HMAC-SHA256(明文头 || IV || 密文长度 || 密文)，encrypt-then-MAC 防篡改/截断。
    /// 密钥：首次写入时生成 32 字节随机主密钥，用 DPAPI(CurrentUser + 固定 entropy) 保护后写到 data\.storekey。
    /// </summary>
    public static class Store
    {
        // ---- 文件/密钥命名 ----
        public const string HourFilePrefix = "监控_";
        public const string HourFileSuffix = ".nwipdb";
        const string KeyFileName = ".storekey";
        const string LegacySessionTag = "legacy000000";

        // ---- 文件格式常量 ----
        const string FileMagic = "NWIPDB01";     // 8 字节 ASCII
        const byte FileVersion = 1;
        const byte FlagGZip = 1;                 // bit0：payload 已 GZip
        const byte FlagPrecise = 2;              // bit1：该小时有精确字节（bytesPrecise）
        const int HeaderSize = 76;               // 见下方字节布局
        const int IvSize = 16;
        const int CipherLenSize = 4;
        const int MacSize = 32;
        const int AesKeySize = 32;
        const string KeyMagic = "NWKEY001";      // 8 字节 ASCII

        /*
         * 明文头字节布局（little-endian；总计 HeaderSize=76）：
         *   0   8  magic "NWIPDB01"
         *   8   1  version (=1)
         *   9   1  flags（bit0=GZip, bit1=bytesPrecise）
         *  10   2  reserved (0)
         *  12   8  hourStartUnix
         *  20   8  sessionStartUnix
         *  28   4  uncompressedLength（JSON 字节数）
         *  32   8  bytesIn
         *  40   8  bytesOut
         *  48   8  peakInBps
         *  56   8  peakOutBps
         *  64   4  sampleCount
         *  68   4  ipCount
         *  72   4  procCount
         *  76  16  IV
         *  92   4  ciphertextLength
         *  96   N  ciphertext = AES-256-CBC(PKCS7)(GZip(JSON(DayData)))
         *  96+N 32 MAC = HMAC-SHA256(macKey, 头部[0..96+N))
         */

        static readonly byte[] KeyEntropy = Encoding.UTF8.GetBytes("NetWatcher2.3.HourStore.DPAPI.Entropy.v1");
        static readonly byte[] MacKeyLabel = Encoding.UTF8.GetBytes("NetWatcher2.3.HourStore.HmacKey.v1");

        static readonly object Lock = new object();
        static string _dataDir = "";
        static Mutex dataLock;              // 2.1：同一数据目录只允许一个写入实例
        static string dataLockName = "";

        // 密钥（按数据目录缓存；Store.Init 切到别的目录时按需重载）
        static string keyDir = "";
        static byte[] masterKey;
        static byte[] macKey;

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

        // 2.1：同一数据目录只允许一个写入实例（GUI 与 --daemon 都抢；--selftest 只读不抢）。
        // Mutex 名由数据目录绝对路径派生，避免不同 --mutex-tag 的实例同时写同一天文件。
        public static string DataLockName { get { return dataLockName; } }

        public static bool AcquireDataLock()
        {
            if (dataLock != null) return true;
            try
            {
                string key = Path.GetFullPath(_dataDir).TrimEnd('\\').ToLowerInvariant();
                using (MD5 md5 = MD5.Create())
                {
                    byte[] hash = md5.ComputeHash(Encoding.UTF8.GetBytes(key));
                    dataLockName = "NetWatcher2.1_DataLock_" + BitConverter.ToString(hash).Replace("-", "");
                }
                Mutex m = new Mutex(false, dataLockName);
                bool ok;
                try { ok = m.WaitOne(0); }
                catch (AbandonedMutexException) { ok = true; }   // 上一个实例崩溃：接管
                if (!ok) { try { m.Dispose(); } catch { } return false; }
                dataLock = m;
                return true;
            }
            catch
            {
                // 环境不支持命名 Mutex 时不要阻断程序（仅本机进程内保护仍有效）
                return true;
            }
        }

        public static void ReleaseDataLock()
        {
            try
            {
                if (dataLock != null) { dataLock.ReleaseMutex(); dataLock.Dispose(); }
            }
            catch { }
            dataLock = null;
        }

        // ---------- 路径/文件名 ----------

        public static string DataPath(string date)
        {
            return Path.Combine(_dataDir, "data", date + ".json");
        }

        public static string KeyPath()
        {
            return Path.Combine(_dataDir, "data", KeyFileName);
        }

        // 2.3.0：小时文件名 = 监控_<日期>_<小时起点 HH-00-00>_s<本次启动 HHmmss>.nwipdb
        // legacy 日块 = 监控_<日期>_00-00-00_legacy000000.nwipdb
        internal static string HourFileName(DayData hour)
        {
            if (hour == null) return "";
            string date = hour.date == null ? "" : hour.date;
            if (hour.hourStartUnix <= 0)
                return HourFilePrefix + date + "_00-00-00_" + LegacySessionTag + HourFileSuffix;
            DateTime h = UnixToLocal(hour.hourStartUnix);
            DateTime s = UnixToLocal(hour.sessionStartUnix);
            return HourFilePrefix + date + "_" + h.ToString("HH'-00-00'") + "_s" + s.ToString("HHmmss") + HourFileSuffix;
        }

        internal static string HourFilePath(DayData hour)
        {
            return Path.Combine(_dataDir, "data", HourFileName(hour));
        }

        static string LegacyFilePath(string date)
        {
            return Path.Combine(_dataDir, "data",
                HourFilePrefix + date + "_00-00-00_" + LegacySessionTag + HourFileSuffix);
        }

        static DateTime UnixToLocal(long unix)
        {
            try { return DateTimeOffset.FromUnixTimeSeconds(unix).ToLocalTime().DateTime; }
            catch { return DateTime.Now; }
        }

        // 从文件名解析日期（监控_2026-11-01_17-00-00_s175422.nwipdb → 2026-11-01）
        public static string HourFileDate(string fileName)
        {
            if (string.IsNullOrEmpty(fileName)) return "";
            if (!fileName.StartsWith(HourFilePrefix, StringComparison.Ordinal)) return "";
            string rest = fileName.Substring(HourFilePrefix.Length);
            if (rest.Length < 10) return "";
            string date = rest.Substring(0, 10);
            DateTime dt;
            if (!DateTime.TryParseExact(date, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out dt)) return "";
            return date;
        }

        // ---------- 加密基础（DPAPI 密钥 + AES + HMAC + GZip） ----------

        // 2.3.0：密钥按需加载/生成——Init 本身不写 .storekey，
        // 这样 --selftest 只做只读自检时不会在真实 data\ 里新增文件（regression-p0 R2 要求）。
        static void EnsureKeyLocked()
        {
            if (masterKey != null && keyDir == _dataDir) return;
            keyDir = _dataDir;
            masterKey = null;
            macKey = null;
            string dir = Path.Combine(_dataDir, "data");
            Directory.CreateDirectory(dir);
            string p = KeyPath();
            if (File.Exists(p))
            {
                byte[] raw = File.ReadAllBytes(p);
                byte[] prot;
                if (raw.Length > 8 && Encoding.ASCII.GetString(raw, 0, 8) == KeyMagic)
                {
                    prot = new byte[raw.Length - 8];
                    Buffer.BlockCopy(raw, 8, prot, 0, prot.Length);
                }
                else
                {
                    prot = raw;
                }
                masterKey = ProtectedData.Unprotect(prot, KeyEntropy, DataProtectionScope.CurrentUser);
                if (masterKey == null || masterKey.Length != AesKeySize)
                    throw new CryptographicException("密钥长度异常（应为 32 字节）");
            }
            else
            {
                byte[] k = new byte[AesKeySize];
                using (RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider()) rng.GetBytes(k);
                byte[] prot = ProtectedData.Protect(k, KeyEntropy, DataProtectionScope.CurrentUser);
                byte[] outp = new byte[8 + prot.Length];
                Buffer.BlockCopy(Encoding.ASCII.GetBytes(KeyMagic), 0, outp, 0, 8);
                Buffer.BlockCopy(prot, 0, outp, 8, prot.Length);
                if (!AtomicWrite(p, outp))
                    throw new IOException("无法写入密钥文件 " + p);
                masterKey = k;
            }
            using (HMACSHA256 h = new HMACSHA256(masterKey))
            {
                macKey = h.ComputeHash(MacKeyLabel);
            }
        }

        static byte[] GZipCompress(byte[] data)
        {
            using (MemoryStream ms = new MemoryStream())
            {
                using (GZipStream gz = new GZipStream(ms, CompressionMode.Compress, true)) gz.Write(data, 0, data.Length);
                return ms.ToArray();
            }
        }

        static byte[] GZipDecompress(byte[] data, int expectedLength)
        {
            using (MemoryStream input = new MemoryStream(data))
            using (GZipStream gz = new GZipStream(input, CompressionMode.Decompress))
            using (MemoryStream output = new MemoryStream(expectedLength > 0 ? expectedLength : 4096))
            {
                byte[] buf = new byte[8192];
                int n;
                while ((n = gz.Read(buf, 0, buf.Length)) > 0) output.Write(buf, 0, n);
                return output.ToArray();
            }
        }

        static byte[] ComputeMac(byte[] buffer, int length)
        {
            byte[] slice = new byte[length];
            Buffer.BlockCopy(buffer, 0, slice, 0, length);
            using (HMACSHA256 h = new HMACSHA256(macKey))
                return h.ComputeHash(slice);
        }

        static bool FixedTimeEquals(byte[] a, int aOff, byte[] b, int bOff)
        {
            int diff = 0;
            for (int i = 0; i < MacSize; i++) diff |= a[aOff + i] ^ b[bOff + i];
            return diff == 0;
        }

        // ---------- 小端读写 ----------

        static void PutU16(byte[] b, int off, int v) { b[off] = (byte)v; b[off + 1] = (byte)(v >> 8); }
        static void PutI32(byte[] b, int off, int v) { for (int i = 0; i < 4; i++) b[off + i] = (byte)(v >> (8 * i)); }
        static void PutI64(byte[] b, int off, long v) { for (int i = 0; i < 8; i++) b[off + i] = (byte)(v >> (8 * i)); }
        static int GetI32(byte[] b, int off)
        {
            return (int)((uint)b[off] | ((uint)b[off + 1] << 8) | ((uint)b[off + 2] << 16) | ((uint)b[off + 3] << 24));
        }
        static long GetI64(byte[] b, int off)
        {
            long v = 0;
            for (int i = 7; i >= 0; i--)
            {
                long bv = b[off + i];
                v = (v << 8) | (bv & 0xFFL);
            }
            return v;
        }

        // ---------- 加密小时文件读写 ----------

        sealed class HourHeader
        {
            public byte Version;
            public byte Flags;
            public long HourStartUnix;
            public long SessionStartUnix;
            public int UncompressedLength;
            public long BytesIn, BytesOut, PeakInBps, PeakOutBps;
            public int SampleCount, IpCount, ProcCount;
        }

        static bool TryReadHeader(byte[] raw, out HourHeader h)
        {
            h = null;
            if (raw == null || raw.Length < HeaderSize) return false;
            if (Encoding.ASCII.GetString(raw, 0, 8) != FileMagic) return false;
            HourHeader x = new HourHeader();
            x.Version = raw[8];
            x.Flags = raw[9];
            x.HourStartUnix = GetI64(raw, 12);
            x.SessionStartUnix = GetI64(raw, 20);
            x.UncompressedLength = GetI32(raw, 28);
            x.BytesIn = GetI64(raw, 32);
            x.BytesOut = GetI64(raw, 40);
            x.PeakInBps = GetI64(raw, 48);
            x.PeakOutBps = GetI64(raw, 56);
            x.SampleCount = GetI32(raw, 64);
            x.IpCount = GetI32(raw, 68);
            x.ProcCount = GetI32(raw, 72);
            if (x.Version != FileVersion) return false;
            if (x.UncompressedLength < 0) return false;
            h = x;
            return true;
        }

        static bool WriteHourLocked(DayData hour, string targetPath)
        {
            try
            {
                if (hour == null) return false;
                EnsureKeyLocked();
                byte[] json = Encoding.UTF8.GetBytes(Json.Serialize(hour));
                byte[] compressed = GZipCompress(json);
                byte[] iv = new byte[IvSize];
                using (RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider()) rng.GetBytes(iv);
                byte[] cipher;
                using (Aes aes = Aes.Create())
                {
                    aes.KeySize = 256;
                    aes.Mode = CipherMode.CBC;
                    aes.Padding = PaddingMode.PKCS7;
                    aes.Key = masterKey;
                    aes.IV = iv;
                    using (ICryptoTransform enc = aes.CreateEncryptor())
                        cipher = enc.TransformFinalBlock(compressed, 0, compressed.Length);
                }
                int clearLen = HeaderSize + IvSize + CipherLenSize;
                byte[] outp = new byte[clearLen + cipher.Length + MacSize];
                Buffer.BlockCopy(Encoding.ASCII.GetBytes(FileMagic), 0, outp, 0, 8);
                outp[8] = FileVersion;
                byte flags = FlagGZip;
                if (hour.bytesPrecise) flags |= FlagPrecise;
                outp[9] = flags;
                PutU16(outp, 10, 0);
                PutI64(outp, 12, hour.hourStartUnix);
                PutI64(outp, 20, hour.sessionStartUnix);
                PutI32(outp, 28, json.Length);
                PutI64(outp, 32, hour.bytesIn);
                PutI64(outp, 40, hour.bytesOut);
                PutI64(outp, 48, hour.peakInBps);
                PutI64(outp, 56, hour.peakOutBps);
                PutI32(outp, 64, hour.sampleCount);
                PutI32(outp, 68, hour.ips == null ? 0 : hour.ips.Count);
                PutI32(outp, 72, hour.procs == null ? 0 : hour.procs.Count);
                Buffer.BlockCopy(iv, 0, outp, HeaderSize, IvSize);
                PutI32(outp, HeaderSize + IvSize, cipher.Length);
                Buffer.BlockCopy(cipher, 0, outp, clearLen, cipher.Length);
                byte[] mac = ComputeMac(outp, clearLen + cipher.Length);
                Buffer.BlockCopy(mac, 0, outp, clearLen + cipher.Length, MacSize);
                return AtomicWrite(targetPath, outp);
            }
            catch (Exception ex)
            {
                Log("加密写入小时文件失败 " + (targetPath == null ? "" : targetPath) + ": " + ex.Message);
                return false;
            }
        }

        static DayData ReadHourFile(string path, out HourHeader header)
        {
            header = null;
            try
            {
                byte[] raw = File.ReadAllBytes(path);
                if (raw.Length < HeaderSize + IvSize + CipherLenSize + MacSize) return null;
                HourHeader h;
                if (!TryReadHeader(raw, out h)) return null;
                header = h;
                EnsureKeyLocked();
                int cipherLenOff = HeaderSize + IvSize;
                int cipherLen = GetI32(raw, cipherLenOff);
                int cipherOff = cipherLenOff + CipherLenSize;
                if (cipherLen < 0 || cipherOff + (long)cipherLen + MacSize > raw.Length) return null;
                byte[] macCalc = ComputeMac(raw, cipherOff + cipherLen);
                if (!FixedTimeEquals(macCalc, 0, raw, cipherOff + cipherLen))
                {
                    Log("小时文件 MAC 校验失败（可能被篡改/截断）: " + Path.GetFileName(path));
                    return null;
                }
                byte[] iv = new byte[IvSize];
                Buffer.BlockCopy(raw, HeaderSize, iv, 0, IvSize);
                byte[] cipher = new byte[cipherLen];
                Buffer.BlockCopy(raw, cipherOff, cipher, 0, cipherLen);
                byte[] compressed;
                using (Aes aes = Aes.Create())
                {
                    aes.KeySize = 256;
                    aes.Mode = CipherMode.CBC;
                    aes.Padding = PaddingMode.PKCS7;
                    aes.Key = masterKey;
                    aes.IV = iv;
                    using (ICryptoTransform dec = aes.CreateDecryptor())
                        compressed = dec.TransformFinalBlock(cipher, 0, cipher.Length);
                }
                byte[] json = GZipDecompress(compressed, h.UncompressedLength);
                DayData d = Json.Deserialize<DayData>(Encoding.UTF8.GetString(json));
                if (d != null)
                {
                    if (d.ips == null) d.ips = new Dictionary<string, IpAggregate>();
                    if (d.procs == null) d.procs = new Dictionary<string, ProcAgg>();
                    if (d.samples == null) d.samples = new List<long[]>();
                }
                return d;
            }
            catch (CryptographicException)
            {
                Log("小时文件解密失败（密钥不匹配/文件损坏）: " + Path.GetFileName(path));
                return null;
            }
            catch (Exception ex)
            {
                Log("读取小时文件失败 " + Path.GetFileName(path) + ": " + ex.Message);
                return null;
            }
        }

        static bool AtomicWrite(string target, byte[] data)
        {
            try
            {
                string dir = Path.GetDirectoryName(target);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                // 临时文件名带 PID，避免多进程/上一次崩溃残留互相踩
                string tmp = target + "." + Process.GetCurrentProcess().Id + ".tmp";
                File.WriteAllBytes(tmp, data);
                for (int attempt = 0; attempt < 3; attempt++)
                {
                    try
                    {
                        if (File.Exists(target)) File.Replace(tmp, target, null);
                        else File.Move(tmp, target);
                        return true;
                    }
                    catch
                    {
                        if (attempt < 2) Thread.Sleep(60);
                    }
                }
                try { if (File.Exists(target)) File.Delete(target); } catch { }
                File.Move(tmp, target);
                return true;
            }
            catch (Exception ex)
            {
                Log("原子写入失败 " + (target == null ? "" : target) + ": " + ex.Message);
                return false;
            }
        }

        static void Log(string msg)
        {
            try
            {
                if (string.IsNullOrEmpty(_dataDir)) return;
                Directory.CreateDirectory(_dataDir);
                File.AppendAllText(Path.Combine(_dataDir, "monitor.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " STORE: " + msg + "\r\n");
            }
            catch { }
        }

        // ---------- 2.3.0 对外 API：会话/小时文件 ----------

        // 每次程序启动：BeginSession 创建一个空的当前小时文件并立刻写盘。
        public static bool BeginSession(DayData hour)
        {
            return SaveHour(hour);
        }

        // 每个采样周期调用：加密全量重写当前小时文件（原子写，断电最多丢 <1 采样）。
        public static bool SaveHour(DayData hour)
        {
            if (hour == null) return false;
            try
            {
                lock (Lock)
                {
                    if (string.IsNullOrEmpty(_dataDir)) return false;
                    EnsureKeyLocked();
                    return WriteHourLocked(hour, HourFilePath(hour));
                }
            }
            catch (Exception ex)
            {
                Log("SaveHour 失败: " + ex.Message);
                return false;
            }
        }

        static List<string> ListHourFiles(string date)
        {
            List<string> list = new List<string>();
            try
            {
                string dir = Path.Combine(_dataDir, "data");
                if (!Directory.Exists(dir)) return list;
                string[] files = Directory.GetFiles(dir, HourFilePrefix + date + "_*" + HourFileSuffix);
                for (int i = 0; i < files.Length; i++)
                {
                    if (HourFileDate(Path.GetFileName(files[i])) == date) list.Add(files[i]);
                }
            }
            catch { }
            list.Sort(StringComparer.Ordinal);
            return list;
        }

        // 合并当天所有小时文件（+ legacy 日块，+ 未迁移的旧 JSON 兜底）为 DayData。
        public static DayData LoadDay(string date)
        {
            lock (Lock)
            {
                DayData result = new DayData { date = date };
                try
                {
                    List<string> files = ListHourFiles(date);
                    bool hasLegacy = false;
                    for (int i = 0; i < files.Count; i++)
                    {
                        HourHeader hdr;
                        DayData d = ReadHourFile(files[i], out hdr);
                        if (d == null) continue;
                        d.date = date;
                        if (hdr != null && hdr.HourStartUnix <= 0) hasLegacy = true;
                        MergeDay(result, d);
                    }
                    // 旧 JSON 兜底：只有该日没有迁移后的 legacy 加密块时才读，避免同一份数据双计。
                    if (!hasLegacy)
                    {
                        DayData jd = LoadDayJson(date);
                        if (jd != null) MergeDay(result, jd);
                    }
                }
                catch (Exception ex)
                {
                    Log("LoadDay(" + date + ") 失败: " + ex.Message);
                }
                NormalizeSamples(result);
                result.date = date;
                return result;
            }
        }

        // 只读明文头（2.3.0：历史概览只读前 HeaderSize 字节，不解密、也不整文件读入）
        static bool TryReadHeaderFromFile(string path, out HourHeader h)
        {
            h = null;
            try
            {
                byte[] head = new byte[HeaderSize];
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    if (fs.Length < HeaderSize) return false;
                    int read = 0;
                    while (read < HeaderSize)
                    {
                        int n = fs.Read(head, read, HeaderSize - read);
                        if (n <= 0) return false;
                        read += n;
                    }
                }
                return TryReadHeader(head, out h);
            }
            catch
            {
                return false;
            }
        }

        // 历史概览用：只读明文头，不 AES 解密（按日最多 24 个文件，几十微秒级）。
        public static DayData LoadDaySummary(string date)
        {
            DayData s = new DayData { date = date };
            lock (Lock)
            {
                try
                {
                    List<string> files = ListHourFiles(date);
                    bool hasLegacy = false;
                    for (int i = 0; i < files.Count; i++)
                    {
                        HourHeader h;
                        if (!TryReadHeaderFromFile(files[i], out h)) continue;
                        s.bytesIn += h.BytesIn;
                        s.bytesOut += h.BytesOut;
                        if (h.PeakInBps > s.peakInBps) s.peakInBps = h.PeakInBps;
                        if (h.PeakOutBps > s.peakOutBps) s.peakOutBps = h.PeakOutBps;
                        s.sampleCount += h.SampleCount;
                        s.ipCount += h.IpCount;
                        s.procCount += h.ProcCount;
                        if ((h.Flags & FlagPrecise) != 0) s.bytesPrecise = true;
                        if (h.HourStartUnix <= 0) hasLegacy = true;
                    }
                    if (!hasLegacy)
                    {
                        DayData jd = LoadDayJson(date);
                        if (jd != null)
                        {
                            DayData jsum = jd.SummaryOnly();
                            s.bytesIn += jsum.bytesIn;
                            s.bytesOut += jsum.bytesOut;
                            if (jsum.peakInBps > s.peakInBps) s.peakInBps = jsum.peakInBps;
                            if (jsum.peakOutBps > s.peakOutBps) s.peakOutBps = jsum.peakOutBps;
                            s.sampleCount += jsum.sampleCount;
                            s.ipCount += jsum.ipCount;
                            s.procCount += jsum.procCount;
                            s.bytesPrecise |= jsum.bytesPrecise;
                        }
                    }
                }
                catch (Exception ex)
                {
                    Log("LoadDaySummary(" + date + ") 失败: " + ex.Message);
                }
            }
            return s;
        }

        // ---------- 合并 ----------

        static void MergeDay(DayData dst, DayData src)
        {
            if (dst == null || src == null) return;
            dst.bytesIn += src.bytesIn;
            dst.bytesOut += src.bytesOut;
            if (src.peakInBps > dst.peakInBps) dst.peakInBps = src.peakInBps;
            if (src.peakOutBps > dst.peakOutBps) dst.peakOutBps = src.peakOutBps;
            if (src.firstSampleUnix > 0 && (dst.firstSampleUnix == 0 || src.firstSampleUnix < dst.firstSampleUnix))
                dst.firstSampleUnix = src.firstSampleUnix;
            if (src.lastSampleUnix > dst.lastSampleUnix) dst.lastSampleUnix = src.lastSampleUnix;
            dst.sampleCount += src.sampleCount;
            dst.bytesPrecise |= src.bytesPrecise;
            if (src.samples != null)
            {
                for (int i = 0; i < src.samples.Count; i++)
                {
                    long[] x = src.samples[i];
                    if (x == null || x.Length < 3) continue;
                    dst.samples.Add(new long[] { x[0], x[1], x[2] });
                }
            }
            if (src.ips != null)
            {
                foreach (KeyValuePair<string, IpAggregate> kv in src.ips)
                {
                    if (kv.Value == null) continue;
                    IpAggregate d;
                    if (!dst.ips.TryGetValue(kv.Key, out d)) { dst.ips[kv.Key] = kv.Value.Clone(); continue; }
                    MergeIp(d, kv.Value);
                }
            }
            if (src.procs != null)
            {
                foreach (KeyValuePair<string, ProcAgg> kv in src.procs)
                {
                    if (kv.Value == null) continue;
                    ProcAgg d;
                    if (!dst.procs.TryGetValue(kv.Key, out d)) { dst.procs[kv.Key] = kv.Value.Clone(); continue; }
                    MergeProc(d, kv.Value);
                }
            }
            dst.ipCount = dst.ips.Count;
            dst.procCount = dst.procs.Count;
        }

        static void MergeIp(IpAggregate d, IpAggregate s)
        {
            d.bytesIn += s.bytesIn;
            d.bytesOut += s.bytesOut;
            if (s.peakInBps > d.peakInBps) d.peakInBps = s.peakInBps;
            if (s.peakOutBps > d.peakOutBps) d.peakOutBps = s.peakOutBps;
            d.connectedSeconds += s.connectedSeconds;
            d.sampleCount += s.sampleCount;
            d.sessionCount += s.sessionCount;
            if (s.firstSeenUnix > 0 && (d.firstSeenUnix == 0 || s.firstSeenUnix < d.firstSeenUnix)) d.firstSeenUnix = s.firstSeenUnix;
            if (s.lastSeenUnix > d.lastSeenUnix) d.lastSeenUnix = s.lastSeenUnix;
            d.bytesPrecise |= s.bytesPrecise;
            d.isNew |= s.isNew;
            AddCounts(d.processes, s.processes);
            AddCounts(d.states, s.states);
            for (int i = 0; i < s.ports.Count; i++) if (!d.ports.Contains(s.ports[i])) d.ports.Add(s.ports[i]);
            if (string.IsNullOrEmpty(d.city) && !string.IsNullOrEmpty(s.city)) { d.city = s.city; d.region = s.region; d.country = s.country; }
            if (string.IsNullOrEmpty(d.isp) && !string.IsNullOrEmpty(s.isp)) d.isp = s.isp;
            if (string.IsNullOrEmpty(d.hostname) && !string.IsNullOrEmpty(s.hostname)) d.hostname = s.hostname;
        }

        static void MergeProc(ProcAgg d, ProcAgg s)
        {
            d.bytesIn += s.bytesIn;
            d.bytesOut += s.bytesOut;
            d.connCount += s.connCount;
            if (s.firstSeenUnix > 0 && (d.firstSeenUnix == 0 || s.firstSeenUnix < d.firstSeenUnix)) d.firstSeenUnix = s.firstSeenUnix;
            if (s.lastSeenUnix > d.lastSeenUnix) d.lastSeenUnix = s.lastSeenUnix;
            if (string.IsNullOrEmpty(d.path) && !string.IsNullOrEmpty(s.path)) d.path = s.path;
            if (s.ips == null) return;
            foreach (KeyValuePair<string, IpConnAgg> kv in s.ips)
            {
                if (kv.Value == null) continue;
                IpConnAgg di;
                if (!d.ips.TryGetValue(kv.Key, out di)) { d.ips[kv.Key] = kv.Value.Clone(); continue; }
                di.bytesIn += kv.Value.bytesIn;
                di.bytesOut += kv.Value.bytesOut;
                di.connCount += kv.Value.connCount;
                if (kv.Value.firstSeenUnix > 0 && (di.firstSeenUnix == 0 || kv.Value.firstSeenUnix < di.firstSeenUnix))
                    di.firstSeenUnix = kv.Value.firstSeenUnix;
                for (int i = 0; i < kv.Value.ports.Count; i++) if (!di.ports.Contains(kv.Value.ports[i])) di.ports.Add(kv.Value.ports[i]);
                if (string.IsNullOrEmpty(di.city) && !string.IsNullOrEmpty(kv.Value.city)) { di.city = kv.Value.city; di.region = kv.Value.region; di.country = kv.Value.country; }
                if (string.IsNullOrEmpty(di.isp) && !string.IsNullOrEmpty(kv.Value.isp)) di.isp = kv.Value.isp;
                if (string.IsNullOrEmpty(di.hostname) && !string.IsNullOrEmpty(kv.Value.hostname)) di.hostname = kv.Value.hostname;
            }
        }

        static void AddCounts(Dictionary<string, int> dst, Dictionary<string, int> src)
        {
            if (src == null) return;
            foreach (KeyValuePair<string, int> kv in src)
            {
                int old;
                if (dst.TryGetValue(kv.Key, out old)) dst[kv.Key] = old + kv.Value;
                else dst[kv.Key] = kv.Value;
            }
        }

        // 合并多来源 samples：去畸形、按分钟升序、同一分钟求和（不丢字节）
        static void NormalizeSamples(DayData d)
        {
            if (d == null) return;
            List<long[]> valid = new List<long[]>();
            if (d.samples != null)
            {
                for (int i = 0; i < d.samples.Count; i++)
                {
                    long[] s = d.samples[i];
                    if (s == null || s.Length < 3) continue;
                    valid.Add(s);
                }
            }
            valid.Sort(delegate(long[] a, long[] b) { return a[0].CompareTo(b[0]); });
            List<long[]> merged = new List<long[]>(valid.Count);
            for (int i = 0; i < valid.Count; i++)
            {
                long[] s = valid[i];
                if (merged.Count > 0 && merged[merged.Count - 1][0] == s[0])
                {
                    long[] last = merged[merged.Count - 1];
                    last[1] += s[1];
                    last[2] += s[2];
                }
                else
                {
                    merged.Add(new long[] { s[0], s[1], s[2] });
                }
            }
            while (merged.Count > 1440) merged.RemoveAt(0);
            d.samples = merged;
        }

        // ---------- 旧明文 JSON（兼容/迁移） ----------

        // 2.3.0：SaveDay 仅用于 legacy 兼容/selftest（写明文 JSON）；Monitor 不再调用。
        public static bool SaveDay(DayData d)
        {
            lock (Lock)
            {
                try
                {
                    if (d == null) return false;
                    Directory.CreateDirectory(_dataDir);
                    Directory.CreateDirectory(Path.Combine(_dataDir, "data"));
                    string target = DataPath(d.date);
                    string tmp = target + "." + Process.GetCurrentProcess().Id + ".tmp";
                    File.WriteAllText(tmp, Json.Serialize(d));
                    bool moved = false;
                    for (int attempt = 0; attempt < 3 && !moved; attempt++)
                    {
                        try
                        {
                            if (File.Exists(target)) File.Replace(tmp, target, null);
                            else File.Move(tmp, target);
                            moved = true;
                        }
                        catch
                        {
                            if (attempt < 2) Thread.Sleep(80);
                        }
                    }
                    if (!moved)
                    {
                        try { if (File.Exists(target)) File.Delete(target); } catch { }
                        File.Move(tmp, target);
                    }
                    return true;
                }
                catch (Exception ex)
                {
                    Log("SaveDay(明文) 失败: " + ex.Message);
                    return false;
                }
            }
        }

        static DayData LoadDayJson(string date)
        {
            try
            {
                string p = DataPath(date);
                if (!File.Exists(p)) return null;
                DayData d = Json.Deserialize<DayData>(File.ReadAllText(p));
                if (d == null) return null;
                d.date = date;
                if (d.ips == null) d.ips = new Dictionary<string, IpAggregate>();
                if (d.procs == null) d.procs = new Dictionary<string, ProcAgg>();
                if (d.samples == null) d.samples = new List<long[]>();
                // 2.1 修复（P1-9）：兼容 1.0 旧数据"假精确"——逐 IP 字节全 0 时诚实降级为估算。
                if (d.bytesPrecise && (d.bytesIn > 0 || d.bytesOut > 0))
                {
                    long ipSum = 0;
                    foreach (IpAggregate agg in d.ips.Values) if (agg != null) ipSum += agg.bytesIn + agg.bytesOut;
                    if (ipSum == 0)
                    {
                        d.bytesPrecise = false;
                        foreach (IpAggregate agg in d.ips.Values) if (agg != null) agg.bytesPrecise = false;
                    }
                }
                d.ipCount = d.ips.Count;
                d.procCount = d.procs.Count;
                return d;
            }
            catch
            {
                return null;
            }
        }

        // ---------- 2.3.0 旧数据迁移（幂等；回读校验通过才删明文） ----------

        public static int MigrateLegacyOnce()
        {
            lock (Lock)
            {
                int migrated = 0;
                try
                {
                    EnsureKeyLocked();
                }
                catch (Exception ex)
                {
                    Log("迁移跳过（密钥不可用）: " + ex.Message);
                    return 0;
                }
                string dir = Path.Combine(_dataDir, "data");
                if (!Directory.Exists(dir)) return 0;
                string[] jsons;
                try { jsons = Directory.GetFiles(dir, "*.json"); }
                catch { return 0; }
                for (int i = 0; i < jsons.Length; i++)
                {
                    string jp = jsons[i];
                    string name = Path.GetFileNameWithoutExtension(jp);
                    if (name == null || name.Length != 10) continue;
                    DateTime dt;
                    if (!DateTime.TryParseExact(name, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                            DateTimeStyles.None, out dt)) continue;
                    try
                    {
                        DayData d = LoadDayJson(name);
                        if (d == null) continue;
                        d.date = name;
                        d.hourStartUnix = 0;
                        d.sessionStartUnix = 0;
                        string legacyPath = LegacyFilePath(name);
                        if (!WriteHourLocked(d, legacyPath))
                        {
                            Log("迁移写盘失败（保留原明文 JSON）: " + name);
                            continue;
                        }
                        HourHeader hdr;
                        DayData back = ReadHourFile(legacyPath, out hdr);
                        if (back == null || !VerifyMigration(d, back))
                        {
                            // 校验失败：删掉不可信的 legacy 块，保留原明文 JSON 作为兜底（避免 LoadDay 误读坏块）
                            try { File.Delete(legacyPath); } catch { }
                            Log("迁移回读校验失败（保留原明文 JSON）: " + name);
                            continue;
                        }
                        try
                        {
                            File.Delete(jp);
                            migrated++;
                            Log("已迁移旧明文日数据 → " + Path.GetFileName(legacyPath));
                        }
                        catch (Exception ex)
                        {
                            Log("迁移校验通过但删除明文失败（保留原明文 JSON）: " + name + " - " + ex.Message);
                        }
                    }
                    catch (Exception ex)
                    {
                        Log("迁移失败（保留原明文 JSON） " + name + ": " + ex.Message);
                    }
                }
                return migrated;
            }
        }

        static bool VerifyMigration(DayData original, DayData back)
        {
            if (original == null || back == null) return false;
            if (back.bytesIn != original.bytesIn) return false;
            if (back.bytesOut != original.bytesOut) return false;
            if (back.peakInBps != original.peakInBps) return false;
            if (back.peakOutBps != original.peakOutBps) return false;
            if (back.sampleCount != original.sampleCount) return false;
            int i1 = original.ips == null ? 0 : original.ips.Count;
            int i2 = back.ips == null ? 0 : back.ips.Count;
            if (i1 != i2) return false;
            int p1 = original.procs == null ? 0 : original.procs.Count;
            int p2 = back.procs == null ? 0 : back.procs.Count;
            if (p1 != p2) return false;
            return true;
        }

        // ---------- 日期列表 / 保留期 ----------

        public static List<string> ListDates()
        {
            HashSet<string> set = new HashSet<string>();
            lock (Lock)
            {
                try
                {
                    string dir = Path.Combine(_dataDir, "data");
                    if (Directory.Exists(dir))
                    {
                        string[] nw = Directory.GetFiles(dir, "*" + HourFileSuffix);
                        for (int i = 0; i < nw.Length; i++)
                        {
                            string d = HourFileDate(Path.GetFileName(nw[i]));
                            if (d.Length == 10) set.Add(d);
                        }
                        string[] js = Directory.GetFiles(dir, "*.json");
                        for (int i = 0; i < js.Length; i++)
                        {
                            string n = Path.GetFileNameWithoutExtension(js[i]);
                            if (n == null || n.Length != 10) continue;
                            DateTime dt;
                            if (DateTime.TryParseExact(n, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                    DateTimeStyles.None, out dt)) set.Add(n);
                        }
                    }
                }
                catch { }
            }
            List<string> r = new List<string>(set);
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
                    string[] files = Directory.GetFiles(dir);
                    for (int i = 0; i < files.Length; i++)
                    {
                        string name = Path.GetFileName(files[i]);
                        string date = "";
                        if (name.EndsWith(HourFileSuffix, StringComparison.OrdinalIgnoreCase))
                            date = HourFileDate(name);
                        else if (name.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
                        {
                            string n = Path.GetFileNameWithoutExtension(name);
                            if (n != null && n.Length == 10) date = n;
                        }
                        if (date.Length != 10) continue;
                        DateTime dt;
                        if (!DateTime.TryParseExact(date, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                DateTimeStyles.None, out dt)) continue;
                        if (dt < cutoff)
                        {
                            try { File.Delete(files[i]); } catch { }
                        }
                    }
                }
                catch { }
            }
        }
    }
}
