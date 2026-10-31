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
        public int RemotePort = 0;
        public int LocalPort = 0;
        public int Pid = 0;
        public string ProcessName = "";
        public string State = "";
        public string Proto = "TCP";
        public uint StateNum;
        public uint LocalAddrRaw;
        public uint RemoteAddrRaw;
        public uint LocalPortRaw;   // 网络字节序，用于 EStats 匹配
        public uint RemotePortRaw;
    }

    public static class NativeMethods
    {
        const int AF_INET = 2;
        const int AF_INET6 = 23;
        const int TCP_TABLE_OWNER_PID_ALL = 5;
        const int TCP_TABLE_OWNER_MODULE_ALL = 8;
        const int TcpConnectionEstatsData = 1;

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
        struct MIB_TCPROW_OWNER_MODULE
        {
            public uint dwState;
            public uint dwLocalAddr;
            public uint dwLocalPort;
            public uint dwRemoteAddr;
            public uint dwRemotePort;
            public uint dwOwningPid;
            public long liCreateTimestamp;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public ulong[] OwningModuleInfo;
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
        struct MIB_TCP6ROW_OWNER_MODULE
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public byte[] ucLocalAddr;
            public uint dwLocalScopeId;
            public uint dwLocalPort;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public byte[] ucRemoteAddr;
            public uint dwRemoteScopeId;
            public uint dwRemotePort;
            public uint dwState;
            public uint dwOwningPid;
            public long liCreateTimestamp;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public ulong[] OwningModuleInfo;
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

        // ---------- 进程名缓存 ----------
        static readonly Dictionary<int, string> ProcNameCache = new Dictionary<int, string>();

        public static void ClearProcessCache()
        {
            lock (ProcNameCache) ProcNameCache.Clear();
        }

        static void BuildProcessMap()
        {
            lock (ProcNameCache)
            {
                if (ProcNameCache.Count > 0) return;
                try
                {
                    foreach (Process p in Process.GetProcesses())
                    {
                        try { ProcNameCache[p.Id] = p.ProcessName; }
                        catch { }
                    }
                }
                catch { }
            }
        }

        static string GetProcessName(int pid)
        {
            if (pid <= 0) return "";
            BuildProcessMap();
            lock (ProcNameCache)
            {
                if (ProcNameCache.ContainsKey(pid)) return ProcNameCache[pid];
            }
            return "";
        }

        // ---------- IP / 端口转换 ----------
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
            var list = new List<ConnEntry>();
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
                    var e = new ConnEntry();
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
                    e.ProcessName = GetProcessName(e.Pid);
                    list.Add(e);
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return list;
        }

        static List<ConnEntry> EnumTcp6()
        {
            var list = new List<ConnEntry>();
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
                    var e = new ConnEntry();
                    e.Proto = "TCP6";
                    try { e.RemoteIp = new IPAddress(row.ucRemoteAddr).ToString(); }
                    catch { e.RemoteIp = ""; }
                    e.RemotePort = PortNtoh(row.dwRemotePort);
                    e.LocalPort = PortNtoh(row.dwLocalPort);
                    e.Pid = (int)row.dwOwningPid;
                    e.State = TcpStateName(row.dwState);
                    e.StateNum = row.dwState;
                    e.ProcessName = GetProcessName(e.Pid);
                    list.Add(e);
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return list;
        }

        public static List<ConnEntry> EnumTcpConnections()
        {
            var list = new List<ConnEntry>();
            try { list.AddRange(EnumTcp4()); } catch { }
            try { list.AddRange(EnumTcp6()); } catch { }
            return list;
        }

        // ---------- 逐连接字节（仅管理员，TCPv4 精确） ----------
        public static bool ReadTcpDataBytes(ConnEntry e, out ulong bytesOut, out ulong bytesIn)
        {
            bytesOut = 0; bytesIn = 0;
            if (e == null || e.Proto != "TCP") return false;
            MIB_TCPROW row = new MIB_TCPROW();
            row.dwState = e.StateNum;
            row.dwLocalAddr = e.LocalAddrRaw;
            row.dwLocalPort = e.LocalPortRaw;
            row.dwRemoteAddr = e.RemoteAddrRaw;
            row.dwRemotePort = e.RemotePortRaw;

            IntPtr rw = IntPtr.Zero, rod = IntPtr.Zero;
            try
            {
                rw = Marshal.AllocHGlobal(4);
                Marshal.WriteByte(rw, 0, 1); // EnableCollection = TRUE
                uint s = SetPerTcpConnectionEStats(ref row, TcpConnectionEstatsData, rw, 0, 4);
                if (s != 0) return false;

                rod = Marshal.AllocHGlobal(1024);
                uint g = GetPerTcpConnectionEStats(ref row, TcpConnectionEstatsData,
                    IntPtr.Zero, 0, 0,
                    IntPtr.Zero, 0, 0,
                    rod, 0, 1024);
                if (g != 0) return false;
                bytesOut = (ulong)Marshal.ReadInt64(rod, 0);   // DataBytesOut
                bytesIn = (ulong)Marshal.ReadInt64(rod, 8);    // DataBytesIn
                return true;
            }
            finally
            {
                if (rw != IntPtr.Zero) Marshal.FreeHGlobal(rw);
                if (rod != IntPtr.Zero) Marshal.FreeHGlobal(rod);
            }
        }

        // ---------- 总流量（无需管理员，按网卡汇总 IPv4+IPv6 字节） ----------
        public static void GetTotalBytes(out long bytesIn, out long bytesOut)
        {
            bytesIn = 0; bytesOut = 0;
            try
            {
                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    try
                    {
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
