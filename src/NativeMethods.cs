using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace NetWatcher
{
    public class ConnEntry
    {
        public string RemoteIp = "";
        public string ProcessName = "";
        public string ProcessPath = "";
        public string State = "";
        public string Proto = "TCP";
        public int RemotePort = 0;
        public int LocalPort = 0;
        public int Pid = 0;
        public long ProcessStartUnix = 0;
        public uint StateNum;
        public uint LocalAddrRaw;
        public uint RemoteAddrRaw;
        public uint LocalPortRaw;   // 网络字节序，用于 EStats 匹配
        public uint RemotePortRaw;
    }

    public class ProcInfo
    {
        public string Name = "";
        public string Path = "";
        public long StartUnix = 0;
    }

    public static class NativeMethods
    {
        const int AF_INET = 2;
        const int AF_INET6 = 23;
        const int TCP_TABLE_OWNER_PID_ALL = 5;
        const int TcpConnectionEstatsData = 1;
        const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        [StructLayout(LayoutKind.Sequential)]
        struct MIB_TCPROW_OWNER_PID
        {
            public uint dwState;
            public uint dwLocalAddr;
            public uint dwLocalPort;
            public uint dwRemoteAddr;
            public uint dwRemotePort;
            public uint dwOwningPid;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MIB_TCP6ROW_OWNER_PID
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public byte[] ucLocalAddr;
            public uint dwLocalScopeId;
            public uint dwLocalPort;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public byte[] ucRemoteAddr;
            public uint dwRemoteScopeId;
            public uint dwRemotePort;
            public uint dwState;
            public uint dwOwningPid;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MIB_TCPROW
        {
            public uint dwState;
            public uint dwLocalAddr;
            public uint dwLocalPort;
            public uint dwRemoteAddr;
            public uint dwRemotePort;
        }

        [DllImport("iphlpapi.dll", SetLastError = true)]
        static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int dwOutBufLen, bool bOrder, int ulAf, int tableClass, int reserved);

        [DllImport("iphlpapi.dll", SetLastError = true)]
        static extern uint SetPerTcpConnectionEStats(ref MIB_TCPROW row, int estatsType, IntPtr rw, uint rwVersion, uint rwSize);

        [DllImport("iphlpapi.dll", SetLastError = true)]
        static extern uint GetPerTcpConnectionEStats(ref MIB_TCPROW row, int estatsType,
            IntPtr rw, uint rwVersion, uint rwSize,
            IntPtr ros, uint rosVersion, uint rosSize,
            IntPtr rod, uint rodVersion, uint rodSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetProcessTimes(IntPtr hProcess, out long creation, out long exit, out long kernel, out long user);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool QueryFullProcessImageName(IntPtr hProcess, int dwFlags, StringBuilder lpExeName, ref int lpdwSize);

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr hObject);

        // ---------- EStats 参数自动探测 ----------
        // 参数组合会在第一次使用时实测确定（不同 Windows 版本/权限行为不同）
        static int EStatsRwSize = 1;
        static int EStatsRodSize = 48;
        static bool EStatsProbed = false;
        static bool EStatsWorks = false;
        public static string EStatsDiag = "";
        public static uint LastEStatsRc = 0;
        public static int LastEStatsWinErr = 0;

        static readonly int[] RwSizes = new int[] { 1, 4 };
        static readonly int[] RodSizes = new int[] { 48, 16, 1024 };

        // ---------- 进程信息缓存（每次采样清理） ----------
        static readonly Dictionary<int, ProcInfo> ProcCache = new Dictionary<int, ProcInfo>();
        static Dictionary<int, string> NameMap = null;

        public static void ClearProcessCache()
        {
            lock (ProcCache) { ProcCache.Clear(); NameMap = null; }
        }

        static void BuildNameMap()
        {
            if (NameMap != null) return;
            Dictionary<int, string> m = new Dictionary<int, string>();
            try
            {
                Process[] ps = Process.GetProcesses();
                for (int i = 0; i < ps.Length; i++)
                {
                    try { m[ps[i].Id] = ps[i].ProcessName; } catch { }
                }
            }
            catch { }
            NameMap = m;
        }

        public static ProcInfo GetProcessInfo(int pid)
        {
            if (pid <= 0) return new ProcInfo();
            lock (ProcCache)
            {
                ProcInfo pi;
                if (ProcCache.TryGetValue(pid, out pi)) return pi;
                pi = new ProcInfo();
                ProcCache[pid] = pi;

                BuildNameMap();
                if (NameMap != null && NameMap.ContainsKey(pid)) pi.Name = NameMap[pid];

                // 完整路径：QueryFullProcessImageName（多数进程普通权限即可）
                IntPtr h = IntPtr.Zero;
                try
                {
                    h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
                    if (h != IntPtr.Zero)
                    {
                        StringBuilder sb = new StringBuilder(1024);
                        int sz = sb.Capacity;
                        if (QueryFullProcessImageName(h, 0, sb, ref sz)) pi.Path = sb.ToString();

                        // 启动时间：GetProcessTimes（PROCESS_QUERY_LIMITED_INFORMATION 即可，用于识别 PID 复用）
                        try
                        {
                            long create, exit, kern, usr;
                            if (GetProcessTimes(h, out create, out exit, out kern, out usr))
                            {
                                long unix = create / 10000000L - 11644473600L;
                                if (unix > 0) pi.StartUnix = unix;
                            }
                        }
                        catch { }
                    }
                }
                catch { }
                finally { if (h != IntPtr.Zero) try { CloseHandle(h); } catch { } }

                // 进程名兜底：从完整路径取文件名（本机实测 Process.GetProcesses 有时取不到名字）
                if (string.IsNullOrEmpty(pi.Name) && !string.IsNullOrEmpty(pi.Path))
                {
                    try
                    {
                        string leaf = System.IO.Path.GetFileNameWithoutExtension(pi.Path);
                        if (!string.IsNullOrEmpty(leaf)) pi.Name = leaf;
                    }
                    catch { }
                }

                // 启动时间（PID 复用识别）
                try
                {
                    using (Process p = Process.GetProcessById(pid))
                    {
                        if (string.IsNullOrEmpty(pi.Name)) pi.Name = p.ProcessName;
                        DateTime st = p.StartTime.ToUniversalTime();
                        pi.StartUnix = (long)(st - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
                        if (string.IsNullOrEmpty(pi.Path))
                        {
                            try { pi.Path = p.MainModule.FileName; } catch { }
                        }
                    }
                }
                catch { }
                return pi;
            }
        }

        // ---------- 地址/端口转换 ----------
        static string AddrToString(uint addr)
        {
            return string.Format("{0}.{1}.{2}.{3}",
                addr & 0xFF, (addr >> 8) & 0xFF, (addr >> 16) & 0xFF, (addr >> 24) & 0xFF);
        }

        static int PortNtoh(uint x)
        {
            uint lo = x & 0xFFFF;
            return (int)(((lo & 0xFF) << 8) | ((lo >> 8) & 0xFF));
        }

        static string TcpStateName(uint s)
        {
            switch (s)
            {
                case 1: return "CLOSED";
                case 2: return "LISTEN";
                case 3: return "SYN_SENT";
                case 4: return "SYN_RCVD";
                case 5: return "ESTABLISHED";
                case 6: return "FIN_WAIT1";
                case 7: return "FIN_WAIT2";
                case 8: return "CLOSE_WAIT";
                case 9: return "CLOSING";
                case 10: return "LAST_ACK";
                case 11: return "TIME_WAIT";
                case 12: return "DELETE_TCB";
                default: return "UNKNOWN";
            }
        }

        // ---------- TCP 枚举 ----------
        static List<ConnEntry> EnumTcp4()
        {
            List<ConnEntry> list = new List<ConnEntry>();
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
            if (size <= 0) return list;
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                uint ret = GetExtendedTcpTable(buf, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
                if (ret != 0) return list;
                uint count = (uint)Marshal.ReadInt32(buf);
                int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
                for (uint i = 0; i < count; i++)
                {
                    IntPtr p = new IntPtr(buf.ToInt64() + 4 + i * (long)rowSize);
                    MIB_TCPROW_OWNER_PID row = (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(p, typeof(MIB_TCPROW_OWNER_PID));
                    ConnEntry e = new ConnEntry();
                    e.Proto = "TCP";
                    e.RemoteIp = AddrToString(row.dwRemoteAddr);
                    e.RemotePort = PortNtoh(row.dwRemotePort);
                    e.LocalPort = PortNtoh(row.dwLocalPort);
                    e.Pid = (int)row.dwOwningPid;
                    e.State = TcpStateName(row.dwState);
                    e.StateNum = row.dwState;
                    e.LocalAddrRaw = row.dwLocalAddr;
                    e.RemoteAddrRaw = row.dwRemoteAddr;
                    e.LocalPortRaw = row.dwLocalPort;
                    e.RemotePortRaw = row.dwRemotePort;
                    FillProc(e);
                    list.Add(e);
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return list;
        }

        static List<ConnEntry> EnumTcp6()
        {
            List<ConnEntry> list = new List<ConnEntry>();
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, AF_INET6, TCP_TABLE_OWNER_PID_ALL, 0);
            if (size <= 0) return list;
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                uint ret = GetExtendedTcpTable(buf, ref size, false, AF_INET6, TCP_TABLE_OWNER_PID_ALL, 0);
                if (ret != 0) return list;
                uint count = (uint)Marshal.ReadInt32(buf);
                int rowSize = Marshal.SizeOf(typeof(MIB_TCP6ROW_OWNER_PID));
                for (uint i = 0; i < count; i++)
                {
                    IntPtr p = new IntPtr(buf.ToInt64() + 4 + i * (long)rowSize);
                    MIB_TCP6ROW_OWNER_PID row = (MIB_TCP6ROW_OWNER_PID)Marshal.PtrToStructure(p, typeof(MIB_TCP6ROW_OWNER_PID));
                    ConnEntry e = new ConnEntry();
                    e.Proto = "TCP6";
                    try { e.RemoteIp = new IPAddress(row.ucRemoteAddr).ToString(); }
                    catch { e.RemoteIp = ""; }
                    e.RemotePort = PortNtoh(row.dwRemotePort);
                    e.LocalPort = PortNtoh(row.dwLocalPort);
                    e.Pid = (int)row.dwOwningPid;
                    e.State = TcpStateName(row.dwState);
                    e.StateNum = row.dwState;
                    FillProc(e);
                    list.Add(e);
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return list;
        }

        static void FillProc(ConnEntry e)
        {
            ProcInfo pi = GetProcessInfo(e.Pid);
            e.ProcessName = pi.Name;
            e.ProcessPath = pi.Path;
            e.ProcessStartUnix = pi.StartUnix;
        }

        public static List<ConnEntry> EnumTcpConnections()
        {
            List<ConnEntry> list = new List<ConnEntry>();
            try { list.AddRange(EnumTcp4()); } catch { }
            try { list.AddRange(EnumTcp6()); } catch { }
            return list;
        }

        // ---------- EStats（逐 TCP 连接精确字节，需要管理员） ----------
        static bool TrySet(ref MIB_TCPROW row, int rwSize, out uint rc, out int winerr)
        {
            IntPtr rw = Marshal.AllocHGlobal(8);
            try
            {
                for (int k = 0; k < 8; k++) Marshal.WriteByte(rw, k, 0);
                Marshal.WriteByte(rw, 0, 1); // EnableCollection = TRUE
                rc = SetPerTcpConnectionEStats(ref row, TcpConnectionEstatsData, rw, 0, (uint)rwSize);
                winerr = Marshal.GetLastWin32Error();
                return rc == 0;
            }
            finally { Marshal.FreeHGlobal(rw); }
        }

        static bool TryGet(ref MIB_TCPROW row, int rodSize, out ulong bytesOut, out ulong bytesIn, out uint rc, out int winerr)
        {
            bytesOut = 0; bytesIn = 0;
            IntPtr rod = Marshal.AllocHGlobal(rodSize < 16 ? 16 : rodSize);
            try
            {
                for (int k = 0; k < rodSize; k++) Marshal.WriteByte(rod, k, 0);
                rc = GetPerTcpConnectionEStats(ref row, TcpConnectionEstatsData,
                    IntPtr.Zero, 0, 0, IntPtr.Zero, 0, 0, rod, 0, (uint)rodSize);
                winerr = Marshal.GetLastWin32Error();
                if (rc != 0) return false;
                bytesOut = (ulong)Marshal.ReadInt64(rod, 0);   // DataBytesOut
                bytesIn = (ulong)Marshal.ReadInt64(rod, 8);    // DataBytesIn
                return true;
            }
            finally { Marshal.FreeHGlobal(rod); }
        }

        static MIB_TCPROW ToRow(ConnEntry e)
        {
            MIB_TCPROW row = new MIB_TCPROW();
            row.dwState = e.StateNum;
            row.dwLocalAddr = e.LocalAddrRaw;
            row.dwLocalPort = e.LocalPortRaw;
            row.dwRemoteAddr = e.RemoteAddrRaw;
            row.dwRemotePort = e.RemotePortRaw;
            return row;
        }

        // 对一个连接尝试所有参数组合；成功则记下可用组合（全局生效）
        public static bool ProbeEStats(ConnEntry e, out string detail)
        {
            detail = "";
            if (e == null || e.Proto != "TCP")
            {
                detail = "非 IPv4 TCP 连接，EStats 不支持";
                return false;
            }
            MIB_TCPROW row = ToRow(e);
            StringBuilder sb = new StringBuilder();
            for (int r = 0; r < RwSizes.Length; r++)
            {
                uint setRc; int setErr;
                bool setOk = TrySet(ref row, RwSizes[r], out setRc, out setErr);
                for (int d = 0; d < RodSizes.Length; d++)
                {
                    ulong o, i;
                    uint getRc; int getErr;
                    bool getOk = TryGet(ref row, RodSizes[d], out o, out i, out getRc, out getErr);
                    sb.Append("rw=" + RwSizes[r] + "(set=" + setRc + "/" + setErr + ") rod=" + RodSizes[d]
                        + "(get=" + getRc + "/" + getErr + ")");
                    if (getOk) sb.Append(" → bytesOut=" + o + " bytesIn=" + i);
                    sb.Append("; ");
                    if (setOk && getOk)
                    {
                        EStatsRwSize = RwSizes[r];
                        EStatsRodSize = RodSizes[d];
                        EStatsWorks = true;
                        EStatsProbed = true;
                        EStatsDiag = sb.ToString();
                        detail = EStatsDiag;
                        return true;
                    }
                }
            }
            EStatsWorks = false;
            EStatsProbed = true;
            EStatsDiag = sb.ToString();
            detail = EStatsDiag;
            return false;
        }

        public static bool EStatsEnable(ConnEntry e, out uint rc, out int winerr)
        {
            rc = 0; winerr = 0;
            if (e == null || e.Proto != "TCP") { rc = 50; return false; }
            MIB_TCPROW row = ToRow(e);
            bool ok = TrySet(ref row, EStatsRwSize, out rc, out winerr);
            LastEStatsRc = rc; LastEStatsWinErr = winerr;
            if (ok) EStatsWorks = true;
            return ok;
        }

        public static bool EStatsRead(ConnEntry e, out ulong bytesOut, out ulong bytesIn, out uint rc, out int winerr)
        {
            bytesOut = 0; bytesIn = 0; rc = 0; winerr = 0;
            if (e == null || e.Proto != "TCP") { rc = 50; return false; }
            if (!EStatsProbed)
            {
                string detail;
                ProbeEStats(e, out detail);
            }
            MIB_TCPROW row = ToRow(e);
            bool ok = TryGet(ref row, EStatsRodSize, out bytesOut, out bytesIn, out rc, out winerr);
            LastEStatsRc = rc; LastEStatsWinErr = winerr;
            return ok;
        }

        public static bool EStatsAvailable { get { return EStatsWorks; } }

        // ---------- 总流量（只统计物理/在线网卡，排除 Loopback 与 Tunnel 避免重复计数） ----------
        public static void GetTotalBytes(out long bytesIn, out long bytesOut)
        {
            bytesIn = 0; bytesOut = 0;
            try
            {
                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    try
                    {
                        if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                        if (nic.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                        if (nic.OperationalStatus != OperationalStatus.Up) continue;
                        IPInterfaceStatistics s = nic.GetIPStatistics();
                        bytesIn += s.BytesReceived;
                        bytesOut += s.BytesSent;
                    }
                    catch { }
                }
            }
            catch { }
        }

        public static bool IsAdministrator()
        {
            try
            {
                using (WindowsIdentity id = WindowsIdentity.GetCurrent())
                {
                    WindowsPrincipal p = new WindowsPrincipal(id);
                    return p.IsInRole(WindowsBuiltInRole.Administrator);
                }
            }
            catch { return false; }
        }
    }
}
