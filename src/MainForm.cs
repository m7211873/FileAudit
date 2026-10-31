using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace NetWatcher
{
    public class MainForm : Form
    {
        readonly AppConfig cfg;
        Monitor monitor;
        NotifyIcon tray;
        System.Windows.Forms.Timer timer;
        string selectedDate;
        bool reallyExiting = false;
        readonly bool background;

        Label lblMode, lblStatus, lblLiveIn, lblLiveOut, lblTodayIn, lblTodayOut, lblDateSummary, lblInterval, lblProcSummary;
        Button btnToday, btnYesterday, btnDayBefore, btnSettings, btnExport, btnOpenDir, btnAdmin;
        DateTimePicker datePicker;
        TabControl tabs;
        DataGridView dgvLiveIps, dgvLiveConns, dgvDate, dgvHistory;
        TreeView treeProcs;
        DateTime lastSampleRendered = DateTime.MinValue;

        public MainForm(AppConfig cfg, bool background)
        {
            this.cfg = cfg;
            this.background = background;
            selectedDate = DateTime.Now.ToString("yyyy-MM-dd");
            BuildUi();
            monitor = new Monitor(cfg);
            timer = new System.Windows.Forms.Timer();
            timer.Interval = 1000;
            timer.Tick += OnTimer;
            BuildTray();
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            RefreshDate();
            RefreshProcessView();
            RefreshLive(monitor.GetSnapshot());
            RefreshHistory();
            monitor.Start();
            timer.Start();
            if (background) { ShowInTaskbar = false; WindowState = FormWindowState.Minimized; Hide(); }
        }

        // ---------------- UI 构建 ----------------
        void BuildUi()
        {
            Text = "NetWatcher · 网络连接监控";
            ClientSize = new Size(1060, 720);
            MinimumSize = new Size(840, 600);
            Icon = LoadAppIcon();
            Font = new Font("Microsoft YaHei UI", 9F);
            StartPosition = FormStartPosition.CenterScreen;

            // 顶部
            Panel top = new Panel(); top.Dock = DockStyle.Top; top.Height = 112;
            Label title = new Label();
            title.Text = "NetWatcher · 网络连接监控";
            title.Font = new Font("Microsoft YaHei UI", 13F, FontStyle.Bold);
            title.AutoSize = true;
            title.Location = new Point(12, 6);
            top.Controls.Add(title);

            lblMode = new Label(); lblMode.AutoSize = true; lblMode.Location = new Point(12, 32);
            top.Controls.Add(lblMode);

            lblStatus = new Label(); lblStatus.AutoSize = true;
            lblStatus.Location = new Point(12, 54); lblStatus.ForeColor = Color.DimGray;
            top.Controls.Add(lblStatus);

            Label l1 = new Label(); l1.Text = "查看日期:"; l1.AutoSize = true; l1.Location = new Point(12, 82);
            top.Controls.Add(l1);

            btnToday = new Button(); btnToday.Text = "今天"; btnToday.Size = new Size(56, 24); btnToday.Location = new Point(80, 79);
            btnToday.Click += delegate { SetDate(DateTime.Now); };
            top.Controls.Add(btnToday);

            btnYesterday = new Button(); btnYesterday.Text = "昨天"; btnYesterday.Size = new Size(56, 24); btnYesterday.Location = new Point(140, 79);
            btnYesterday.Click += delegate { SetDate(DateTime.Now.AddDays(-1)); };
            top.Controls.Add(btnYesterday);

            btnDayBefore = new Button(); btnDayBefore.Text = "前天"; btnDayBefore.Size = new Size(56, 24); btnDayBefore.Location = new Point(200, 79);
            btnDayBefore.Click += delegate { SetDate(DateTime.Now.AddDays(-2)); };
            top.Controls.Add(btnDayBefore);

            datePicker = new DateTimePicker();
            datePicker.Format = DateTimePickerFormat.Custom;
            datePicker.CustomFormat = "yyyy-MM-dd";
            datePicker.Width = 120;
            datePicker.Location = new Point(264, 79);
            datePicker.Value = DateTime.Now;
            datePicker.ValueChanged += delegate { selectedDate = datePicker.Value.ToString("yyyy-MM-dd"); RefreshDate(); RefreshProcessView(); };
            top.Controls.Add(datePicker);

            lblInterval = new Label(); lblInterval.AutoSize = true; lblInterval.Location = new Point(400, 82); lblInterval.ForeColor = Color.DimGray;
            top.Controls.Add(lblInterval);
            Controls.Add(top);

            // 底部
            Panel bottom = new Panel(); bottom.Dock = DockStyle.Bottom; bottom.Height = 50;
            btnSettings = new Button(); btnSettings.Text = "设置"; btnSettings.Size = new Size(70, 28); btnSettings.Location = new Point(12, 11);
            btnSettings.Click += delegate { OpenSettings(); };
            bottom.Controls.Add(btnSettings);

            btnExport = new Button(); btnExport.Text = "导出CSV"; btnExport.Size = new Size(88, 28); btnExport.Location = new Point(90, 11);
            btnExport.Click += delegate { ExportCsv(); };
            bottom.Controls.Add(btnExport);

            btnOpenDir = new Button(); btnOpenDir.Text = "打开数据目录"; btnOpenDir.Size = new Size(110, 28); btnOpenDir.Location = new Point(186, 11);
            btnOpenDir.Click += delegate { try { Process.Start(cfg.EffectiveDataDir()); } catch { } };
            bottom.Controls.Add(btnOpenDir);

            btnAdmin = new Button(); btnAdmin.Text = "以管理员身份重启（逐IP精确流量）"; btnAdmin.Size = new Size(230, 28); btnAdmin.Location = new Point(304, 11);
            btnAdmin.Click += delegate { RestartAsAdmin(); };
            bottom.Controls.Add(btnAdmin);

            Label tip = new Label(); tip.Text = "关闭窗口 = 最小化到托盘"; tip.AutoSize = true;
            tip.Location = new Point(548, 16); tip.ForeColor = Color.Gray;
            bottom.Controls.Add(tip);
            Controls.Add(bottom);

            // 标签页
            tabs = new TabControl(); tabs.Dock = DockStyle.Fill;
            TabPage tpLive = new TabPage("实时连接");
            TabPage tpProc = new TabPage("进程视图");
            TabPage tpDate = new TabPage("按日统计");
            TabPage tpHist = new TabPage("历史概览");
            tabs.TabPages.Add(tpLive); tabs.TabPages.Add(tpProc); tabs.TabPages.Add(tpDate); tabs.TabPages.Add(tpHist);

            // --- 实时连接 ---
            Panel liveTop = new Panel(); liveTop.Dock = DockStyle.Top; liveTop.Height = 74;
            FlowLayoutPanel flp = new FlowLayoutPanel(); flp.Dock = DockStyle.Fill; flp.Padding = new Padding(6, 8, 6, 6); flp.WrapContents = true;
            lblLiveIn = MakeStatLabel(flp, "↓ 下载速度", Color.ForestGreen);
            lblLiveOut = MakeStatLabel(flp, "↑ 上传速度", Color.Firebrick);
            lblTodayIn = MakeStatLabel(flp, "今日累计下载", Color.ForestGreen);
            lblTodayOut = MakeStatLabel(flp, "今日累计上传", Color.Firebrick);
            liveTop.Controls.Add(flp);
            tpLive.Controls.Add(liveTop);

            SplitContainer split = new SplitContainer();
            split.Dock = DockStyle.Fill; split.Orientation = Orientation.Horizontal; split.SplitterDistance = 260;
            split.Panel1MinSize = 100; split.Panel2MinSize = 120;
            Label lIp = new Label(); lIp.Text = "各 IP 当前连接与速率（按速率排序）"; lIp.Dock = DockStyle.Top; lIp.Height = 20; lIp.Padding = new Padding(6, 3, 0, 0);
            dgvLiveIps = new DataGridView(); dgvLiveIps.Dock = DockStyle.Fill;
            split.Panel1.Controls.Add(dgvLiveIps); split.Panel1.Controls.Add(lIp);
            Label lConn = new Label(); lConn.Text = "当前连接明细（IP / 地址 / 应用程序 / 端口 / 协议 / 上传 / 下载 / 总流量 / 时长）"; lConn.Dock = DockStyle.Top; lConn.Height = 20; lConn.Padding = new Padding(6, 3, 0, 0);
            dgvLiveConns = new DataGridView(); dgvLiveConns.Dock = DockStyle.Fill;
            split.Panel2.Controls.Add(dgvLiveConns); split.Panel2.Controls.Add(lConn);
            tpLive.Controls.Add(split);

            // --- 进程视图（树形：应用程序 → PID → 远端IP） ---
            lblProcSummary = new Label(); lblProcSummary.Dock = DockStyle.Top; lblProcSummary.Height = 44;
            lblProcSummary.Padding = new Padding(8, 8, 0, 0); lblProcSummary.TextAlign = ContentAlignment.MiddleLeft;
            treeProcs = new TreeView(); treeProcs.Dock = DockStyle.Fill;
            treeProcs.Font = new Font("Microsoft YaHei UI", 9F);
            treeProcs.HideSelection = false;
            tpProc.Controls.Add(treeProcs); tpProc.Controls.Add(lblProcSummary);

            // --- 按日统计 ---
            lblDateSummary = new Label(); lblDateSummary.Dock = DockStyle.Top; lblDateSummary.Height = 44;
            lblDateSummary.Padding = new Padding(8, 8, 0, 0); lblDateSummary.TextAlign = ContentAlignment.MiddleLeft;
            dgvDate = new DataGridView(); dgvDate.Dock = DockStyle.Fill;
            tpDate.Controls.Add(dgvDate); tpDate.Controls.Add(lblDateSummary);

            // --- 历史概览 ---
            dgvHistory = new DataGridView(); dgvHistory.Dock = DockStyle.Fill;
            tpHist.Controls.Add(dgvHistory);

            Controls.Add(tabs);

            InitLiveIpsGrid(); InitLiveConnsGrid(); InitDateGrid(); InitHistoryGrid();
            UpdateModeLabels();
        }

        Label MakeStatLabel(Control host, string name, Color c)
        {
            Label l = new Label();
            l.Text = name + ": —";
            l.AutoSize = true;
            l.Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold);
            l.ForeColor = c;
            l.Margin = new Padding(0, 2, 24, 2);
            host.Controls.Add(l);
            return l;
        }

        void ApplyGridStyle(DataGridView g)
        {
            g.ReadOnly = true;
            g.AllowUserToAddRows = false;
            g.AllowUserToDeleteRows = false;
            g.RowHeadersVisible = false;
            g.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            g.MultiSelect = false;
            g.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
            g.BackgroundColor = Color.White;
            g.BorderStyle = BorderStyle.None;
            g.EnableHeadersVisualStyles = true;
        }

        void AddCol(DataGridView g, string name, string header, int w)
        {
            DataGridViewTextBoxColumn c = new DataGridViewTextBoxColumn();
            c.Name = name; c.HeaderText = header; c.Width = w;
            g.Columns.Add(c);
        }

        void InitLiveIpsGrid()
        {
            ApplyGridStyle(dgvLiveIps);
            AddCol(dgvLiveIps, "ip", "IP 地址", 140);
            AddCol(dgvLiveIps, "loc", "城市 / 地区", 200);
            AddCol(dgvLiveIps, "isp", "运营商", 140);
            AddCol(dgvLiveIps, "conns", "连接数", 60);
            AddCol(dgvLiveIps, "up", "上传速度", 100);
            AddCol(dgvLiveIps, "down", "下载速度", 100);
        }

        void InitLiveConnsGrid()
        {
            ApplyGridStyle(dgvLiveConns);
            AddCol(dgvLiveConns, "ip", "IP 地址", 130);
            AddCol(dgvLiveConns, "loc", "地址（城市/地区）", 150);
            AddCol(dgvLiveConns, "proc", "应用程序", 130);
            AddCol(dgvLiveConns, "pid", "PID", 60);
            AddCol(dgvLiveConns, "rport", "端口", 60);
            AddCol(dgvLiveConns, "proto", "协议", 60);
            AddCol(dgvLiveConns, "up", "上传", 90);
            AddCol(dgvLiveConns, "down", "下载", 90);
            AddCol(dgvLiveConns, "total", "总流量", 90);
            AddCol(dgvLiveConns, "dur", "连接时长", 90);
        }

        void InitDateGrid()
        {
            ApplyGridStyle(dgvDate);
            AddCol(dgvDate, "ip", "IP 地址", 140);
            AddCol(dgvDate, "city", "城市", 90);
            AddCol(dgvDate, "region", "地区/省", 90);
            AddCol(dgvDate, "isp", "运营商", 120);
            AddCol(dgvDate, "dur", "连接时长", 90);
            AddCol(dgvDate, "sess", "连接次数", 70);
            AddCol(dgvDate, "first", "首次连接", 80);
            AddCol(dgvDate, "last", "最近连接", 80);
            AddCol(dgvDate, "down", "下载", 90);
            AddCol(dgvDate, "up", "上传", 90);
            AddCol(dgvDate, "avgDown", "平均下载", 90);
            AddCol(dgvDate, "avgUp", "平均上传", 90);
            AddCol(dgvDate, "peakDown", "峰值下载", 100);
            AddCol(dgvDate, "peakUp", "峰值上传", 100);
        }

        void InitHistoryGrid()
        {
            ApplyGridStyle(dgvHistory);
            AddCol(dgvHistory, "date", "日期", 110);
            AddCol(dgvHistory, "down", "下载", 110);
            AddCol(dgvHistory, "up", "上传", 110);
            AddCol(dgvHistory, "peakDown", "峰值下载", 110);
            AddCol(dgvHistory, "peakUp", "峰值上传", 110);
            AddCol(dgvHistory, "ipCount", "IP 数", 80);
            AddCol(dgvHistory, "samples", "采样次数", 90);
        }

        // ---------------- 刷新 ----------------
        void OnTimer(object s, EventArgs e)
        {
            Snapshot snap = monitor.GetSnapshot();
            if (snap == null) return;
            lblStatus.Text = "最近扫描: " + snap.LastScan.ToString("HH:mm:ss")
                + "  ·  " + (snap.BytesPrecise ? "精确流量" : "估算流量");
            lblInterval.Text = "扫描间隔: " + cfg.ScanIntervalSeconds + " 秒";

            // 仅在产生新采样时才重建表格（避免滚动条被反复重置、拖不动）
            if (snap.LastScan != lastSampleRendered)
            {
                lastSampleRendered = snap.LastScan;
                RefreshLive(snap);
                string today = DateTime.Now.ToString("yyyy-MM-dd");
                if (selectedDate == today)
                {
                    RefreshDate();
                    RefreshProcessView();
                }
            }
        }

        void RefreshLive(Snapshot snap)
        {
            lblLiveIn.Text = "↓ 下载速度: " + FmtRate(snap.TotalInBps);
            lblLiveOut.Text = "↑ 上传速度: " + FmtRate(snap.TotalOutBps);
            lblTodayIn.Text = "今日累计下载: " + FmtBytes(snap.TodayInBytes);
            lblTodayOut.Text = "今日累计上传: " + FmtBytes(snap.TodayOutBytes);

            int scrollIps = dgvLiveIps.FirstDisplayedScrollingRowIndex;
            dgvLiveIps.Rows.Clear();
            foreach (LiveIp li in snap.LiveIps)
            {
                string loc = JoinNonEmpty(li.Country, li.Region, li.City);
                dgvLiveIps.Rows.Add(li.Ip, loc, li.Isp, li.ConnCount, FmtRate(li.SpeedOutBps), FmtRate(li.SpeedInBps));
            }
            if (scrollIps >= 0 && scrollIps < dgvLiveIps.Rows.Count) dgvLiveIps.FirstDisplayedScrollingRowIndex = scrollIps;

            int scrollConns = dgvLiveConns.FirstDisplayedScrollingRowIndex;
            dgvLiveConns.Rows.Clear();
            foreach (LiveConn c in snap.LiveConns)
            {
                string loc = JoinNonEmpty(c.Country, c.Region, c.City);
                string proc = string.IsNullOrEmpty(c.ProcessName) ? "(未知)" : c.ProcessName;
                dgvLiveConns.Rows.Add(c.Ip, loc, proc, c.Pid, c.RemotePort, c.Proto,
                    FmtBytes(c.BytesOut), FmtBytes(c.BytesIn), FmtBytes(c.BytesIn + c.BytesOut), FmtDuration(c.DurationSeconds));
            }
            if (scrollConns >= 0 && scrollConns < dgvLiveConns.Rows.Count) dgvLiveConns.FirstDisplayedScrollingRowIndex = scrollConns;
        }

        void SetDate(DateTime d)
        {
            selectedDate = d.ToString("yyyy-MM-dd");
            datePicker.Value = d.Date;
            RefreshDate();
            RefreshProcessView();
        }

        void RefreshDate()
        {
            string today = DateTime.Now.ToString("yyyy-MM-dd");
            DayData dd;
            List<IpAggregate> list;
            if (selectedDate == today)
            {
                dd = monitor.GetTodaySummary();
                list = monitor.GetTodayAggregates();
            }
            else
            {
                dd = Store.LoadDay(selectedDate);
                list = new List<IpAggregate>(dd.ips.Values);
                list.Sort(delegate(IpAggregate x, IpAggregate y) { return (y.bytesIn + y.bytesOut).CompareTo(x.bytesIn + x.bytesOut); });
            }

            long activeSec = dd.lastSampleUnix > dd.firstSampleUnix ? dd.lastSampleUnix - dd.firstSampleUnix : 0;
            long avgIn = activeSec > 0 ? dd.bytesIn / activeSec : 0;
            long avgOut = activeSec > 0 ? dd.bytesOut / activeSec : 0;
            string mode = dd.bytesPrecise ? "逐IP精确" : "逐IP估算";
            lblDateSummary.Text = dd.date + "   |   下载 " + FmtBytes(dd.bytesIn) + "   ·   上传 " + FmtBytes(dd.bytesOut)
                + "   ·   平均下载 " + FmtRate(avgIn) + "   ·   平均上传 " + FmtRate(avgOut)
                + "   ·   峰值下载 " + FmtRate(dd.peakInBps) + "   ·   峰值上传 " + FmtRate(dd.peakOutBps)
                + "   ·   采样 " + dd.sampleCount + " 次   ·   字节来源：" + mode;

            dgvDate.Rows.Clear();
            foreach (IpAggregate a in list)
            {
                long iavgIn = a.connectedSeconds > 0 ? a.bytesIn / a.connectedSeconds : 0;
                long iavgOut = a.connectedSeconds > 0 ? a.bytesOut / a.connectedSeconds : 0;
                dgvDate.Rows.Add(a.ip, a.city, a.region, a.isp, FmtDuration(a.connectedSeconds), a.sessionCount,
                    FmtTime(a.firstSeenUnix), FmtTime(a.lastSeenUnix),
                    FmtBytes(a.bytesIn), FmtBytes(a.bytesOut),
                    FmtRate(iavgIn), FmtRate(iavgOut),
                    FmtRate(a.peakInBps), FmtRate(a.peakOutBps));
            }
        }

        void RefreshProcessView()
        {
            string today = DateTime.Now.ToString("yyyy-MM-dd");
            DayData dd;
            List<ProcAgg> procs;
            if (selectedDate == today)
            {
                dd = monitor.GetTodaySummary();
                procs = monitor.GetTodayProcs();
            }
            else
            {
                dd = Store.LoadDay(selectedDate);
                procs = new List<ProcAgg>(dd.procs.Values);
                procs.Sort(delegate(ProcAgg x, ProcAgg y) { return (y.bytesIn + y.bytesOut).CompareTo(x.bytesIn + x.bytesOut); });
            }

            // 按进程名分组
            var byName = new Dictionary<string, List<ProcAgg>>();
            foreach (ProcAgg p in procs)
            {
                string nm = string.IsNullOrEmpty(p.name) ? "(未知)" : p.name;
                if (!byName.ContainsKey(nm)) byName[nm] = new List<ProcAgg>();
                byName[nm].Add(p);
            }
            var names = new List<string>(byName.Keys);
            names.Sort(delegate(string a, string b)
            {
                long ta = 0, tb = 0;
                foreach (ProcAgg p in byName[a]) ta += p.bytesIn + p.bytesOut;
                foreach (ProcAgg p in byName[b]) tb += p.bytesIn + p.bytesOut;
                return tb.CompareTo(ta);
            });

            long connTotal = 0;
            foreach (ProcAgg p in procs) connTotal += p.connCount;

            treeProcs.BeginUpdate();
            treeProcs.Nodes.Clear();
            foreach (string nm in names)
            {
                List<ProcAgg> plist = byName[nm];
                long nIn = 0, nOut = 0; int nConn = 0;
                foreach (ProcAgg p in plist) { nIn += p.bytesIn; nOut += p.bytesOut; nConn += p.connCount; }
                TreeNode nodeName = treeProcs.Nodes.Add(nm + "  (PID " + plist.Count + "个)   ↓" + FmtBytes(nIn) + "  ↑" + FmtBytes(nOut) + "  · " + nConn + "次");

                plist.Sort(delegate(ProcAgg x, ProcAgg y) { return (y.bytesIn + y.bytesOut).CompareTo(x.bytesIn + x.bytesOut); });
                foreach (ProcAgg p in plist)
                {
                    TreeNode nodePid = nodeName.Nodes.Add("PID " + p.pid + "   ↓" + FmtBytes(p.bytesIn) + "  ↑" + FmtBytes(p.bytesOut) + "  · " + p.connCount + "次");
                    var iplist = new List<IpConnAgg>(p.ips.Values);
                    iplist.Sort(delegate(IpConnAgg x, IpConnAgg y) { return (y.bytesIn + y.bytesOut).CompareTo(x.bytesIn + x.bytesOut); });
                    foreach (IpConnAgg ia in iplist)
                    {
                        string loc = JoinNonEmpty(ia.country, ia.region, ia.city);
                        var portStrs = new List<string>();
                        foreach (int port in ia.ports) portStrs.Add(port.ToString());
                        string ports = string.Join(",", portStrs.ToArray());
                        string proto = string.IsNullOrEmpty(ia.proto) ? "TCP" : ia.proto;
                        nodePid.Nodes.Add(ia.ip + ":" + ports + "  [" + proto + "]  " + loc
                            + "   ↓" + FmtBytes(ia.bytesIn) + "  ↑" + FmtBytes(ia.bytesOut) + "  · " + ia.connCount + "次");
                    }
                }
            }
            treeProcs.EndUpdate();
            treeProcs.ExpandAll();

            string mode = dd.bytesPrecise ? "逐IP精确" : "逐IP估算";
            lblProcSummary.Text = dd.date + "   |   进程 " + names.Count + " 个   ·   远端IP " + dd.ips.Count + " 个"
                + "   ·   累计连接 " + connTotal + " 次   ·   下载 " + FmtBytes(dd.bytesIn)
                + "   ·   上传 " + FmtBytes(dd.bytesOut)
                + "   ·   峰值↓ " + FmtRate(dd.peakInBps) + "  ↑ " + FmtRate(dd.peakOutBps)
                + "   ·   字节来源：" + mode;
        }

        void RefreshHistory()
        {
            dgvHistory.Rows.Clear();
            foreach (string d in Store.ListDates())
            {
                DayData dd = Store.LoadDay(d);
                dgvHistory.Rows.Add(d, FmtBytes(dd.bytesIn), FmtBytes(dd.bytesOut),
                    FmtRate(dd.peakInBps), FmtRate(dd.peakOutBps), dd.ips.Count, dd.sampleCount);
            }
        }

        void UpdateModeLabels()
        {
            if (NativeMethods.IsAdministrator())
            {
                lblMode.Text = "运行模式：管理员（逐IP精确流量）";
                lblMode.ForeColor = Color.ForestGreen;
                btnAdmin.Visible = false;
            }
            else
            {
                lblMode.Text = "运行模式：普通用户（逐IP流量为估算）";
                lblMode.ForeColor = Color.DarkOrange;
                btnAdmin.Visible = true;
            }
        }
        // ---------------- 动作 ----------------
        void OpenSettings()
        {
            SettingsForm f = new SettingsForm(cfg);
            if (f.ShowDialog(this) == DialogResult.OK)
            {
                cfg.Save();
                Startup.SetEnabled(cfg.AutoStart);
                UpdateModeLabels();
                lblInterval.Text = "扫描间隔: " + cfg.ScanIntervalSeconds + " 秒";
            }
        }

        void ExportCsv()
        {
            string today = DateTime.Now.ToString("yyyy-MM-dd");
            List<IpAggregate> list;
            if (selectedDate == today) list = monitor.GetTodayAggregates();
            else
            {
                DayData dd = Store.LoadDay(selectedDate);
                list = new List<IpAggregate>(dd.ips.Values);
                list.Sort(delegate(IpAggregate x, IpAggregate y) { return (y.bytesIn + y.bytesOut).CompareTo(x.bytesIn + x.bytesOut); });
            }
            using (SaveFileDialog dlg = new SaveFileDialog())
            {
                dlg.FileName = "NetWatcher_" + selectedDate + ".csv";
                dlg.Filter = "CSV 文件 (*.csv)|*.csv";
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                try
                {
                    var sb = new StringBuilder();
                    sb.AppendLine("IP地址,城市,地区,运营商,连接时长,连接次数,首次连接,最近连接,下载(字节),上传(字节),平均下载(B/s),平均上传(B/s),峰值下载(B/s),峰值上传(B/s)");
                    foreach (IpAggregate a in list)
                    {
                        long iavgIn = a.connectedSeconds > 0 ? a.bytesIn / a.connectedSeconds : 0;
                        long iavgOut = a.connectedSeconds > 0 ? a.bytesOut / a.connectedSeconds : 0;
                        sb.AppendLine(Csv(a.ip) + "," + Csv(a.city) + "," + Csv(a.region) + "," + Csv(a.isp) + ","
                            + Csv(FmtDuration(a.connectedSeconds)) + "," + a.sessionCount + ","
                            + Csv(FmtTime(a.firstSeenUnix)) + "," + Csv(FmtTime(a.lastSeenUnix)) + ","
                            + a.bytesIn + "," + a.bytesOut + "," + iavgIn + "," + iavgOut + "," + a.peakInBps + "," + a.peakOutBps);
                    }
                    File.WriteAllText(dlg.FileName, sb.ToString(), new UTF8Encoding(true));
                    MessageBox.Show("已导出到:\n" + dlg.FileName, "NetWatcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch (Exception ex) { MessageBox.Show("导出失败: " + ex.Message, "NetWatcher", MessageBoxButtons.OK, MessageBoxIcon.Error); }
            }
        }

        void RestartAsAdmin()
        {
            try
            {
                var psi = new ProcessStartInfo();
                psi.FileName = Startup.ExePath();
                if (background) psi.Arguments = "--background";
                psi.Verb = "runas";
                psi.UseShellExecute = true;
                Process.Start(psi);
                ExitApp();
            }
            catch { /* 用户取消 UAC */ }
        }

        // ---------------- 托盘 ----------------
        void BuildTray()
        {
            tray = new NotifyIcon();
            tray.Icon = LoadAppIcon();
            tray.Text = "NetWatcher 网络连接监控";
            tray.Visible = true;
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("显示主窗口", null, delegate { ShowMain(); });
            menu.Items.Add("刷新", null, delegate { RefreshLive(monitor.GetSnapshot()); RefreshDate(); RefreshHistory(); RefreshProcessView(); });
            menu.Items.Add("创建桌面快捷方式", null, delegate { CreateDesktopShortcut(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出", null, delegate { ExitApp(); });
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += delegate { ShowMain(); };
        }

        void CreateDesktopShortcut()
        {
            try
            {
                string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                string lnkPath = Path.Combine(desktop, "NetWatcher.lnk");
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                object shell = Activator.CreateInstance(shellType);
                object shortcut = shellType.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
                Type scType = shortcut.GetType();
                scType.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { Startup.ExePath() });
                scType.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { Path.GetDirectoryName(Startup.ExePath()) });
                scType.InvokeMember("IconLocation", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { Startup.ExePath() + ",0" });
                scType.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, shortcut, null);
                MessageBox.Show("已在桌面创建快捷方式:\n" + lnkPath, "NetWatcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("创建失败: " + ex.Message, "NetWatcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        void ShowMain()
        {
            ShowInTaskbar = true;
            Show();
            WindowState = FormWindowState.Normal;
            Activate();
        }

        void ExitApp()
        {
            reallyExiting = true;
            try { monitor.Stop(); } catch { }
            try { tray.Visible = false; tray.Dispose(); } catch { }
            Close();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!reallyExiting && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();
                return;
            }
            base.OnFormClosing(e);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (WindowState == FormWindowState.Minimized) { Hide(); }
        }

        // ---------------- 工具 ----------------
        static string FmtBytes(long b) { return Program.FmtBytes(b); }
        static string FmtRate(long bps) { return FmtBytes(bps) + "/s"; }

        static Icon LoadAppIcon()
        {
            try
            {
                Icon i = Icon.ExtractAssociatedIcon(Startup.ExePath());
                if (i != null) return i;
            }
            catch { }
            return SystemIcons.Application;
        }

        static string FmtDuration(long sec)
        {
            if (sec <= 0) return "-";
            long h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60;
            if (h > 0) return h + "小时" + m + "分";
            if (m > 0) return m + "分" + s + "秒";
            return s + "秒";
        }

        static string FmtTime(long unix)
        {
            if (unix <= 0) return "-";
            try { return DateTimeOffset.FromUnixTimeSeconds(unix).ToLocalTime().ToString("HH:mm:ss"); }
            catch { return "-"; }
        }

        static string JoinNonEmpty(params string[] parts)
        {
            var sb = new StringBuilder();
            foreach (string p in parts)
            {
                if (string.IsNullOrEmpty(p)) continue;
                if (sb.Length > 0) sb.Append(" ");
                sb.Append(p);
            }
            return sb.Length == 0 ? "未知" : sb.ToString();
        }

        static string Csv(string s)
        {
            if (s == null) return "";
            if (s.IndexOfAny(new char[] { ',', '"', '\n', '\r' }) >= 0)
                return "\"" + s.Replace("\"", "\"\"") + "\"";
            return s;
        }
    }
}
