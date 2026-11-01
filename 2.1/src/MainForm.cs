using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace NetWatcher
{
    /// <summary>
    /// IP监控2.1 主窗口。
    /// 布局：根 TableLayoutPanel 三行（header AutoSize / tabs 100% / footer AutoSize），
    /// 页面内部同样使用 TableLayoutPanel 显式分行，避免 1.0 的 Dock 混用导致标签栏/列头被遮挡。
    /// </summary>
    public class MainForm : Form
    {
        const string DateFmt = "yyyy-MM-dd";
        // 2.2.0 收口：趋势页相邻分钟桶间隔 > 5 分钟视为程序未运行 → 曲线断开不连线
        const int TrendGapMinutes = 5;

        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
        static extern int RegisterWindowMessage(string message);

        static readonly int WM_TASKBARCREATED = RegisterWindowMessage("TaskbarCreated");

        // ---------------- 基础 ----------------
        readonly AppConfig cfg;
        readonly bool background;
        readonly string dataDir;
        readonly System.Threading.EventWaitHandle activateEvent;
        readonly System.Threading.EventWaitHandle quitEvent;
        Monitor monitor;
        NotifyIcon tray;
        ContextMenuStrip trayMenu;
        ToolTip toolTip;
        System.Windows.Forms.Timer timer;
        System.Windows.Forms.Timer trayRetryTimer;
        int trayRetryCount = 0;
        bool reallyExiting = false;
        bool adminMode = false;
        bool trayHintShown = false;
        bool inSetDate = false;

        string selectedDate;
        string pinnedIp = "";                 // 双击连接行/树节点产生的 IP 筛选（只作用于上表）
        Snapshot curSnap;
        DateTime lastScanRendered = DateTime.MinValue;
        // 2.1（P1-11）：非实时页按页节流，避免每次采样都整表重建
        DateTime lastProcRebind = DateTime.MinValue;
        DateTime lastDateRebind = DateTime.MinValue;
        DateTime lastHistRebind = DateTime.MinValue;
        readonly HashSet<string> alertedIps = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly Font newBadgeFont = new Font("Microsoft YaHei", 9F, FontStyle.Bold);

        // ---------------- 顶部 ----------------
        Label lblTitle, lblMode, lblInterval, lblStatus;
        Button btnToday, btnYesterday, btnDayBefore, btnRefresh;
        DateTimePicker datePicker;
        TextBox txtSearch;

        // ---------------- 底部 ----------------
        Button btnSettings, btnExportFooter, btnOpenDir, btnAdmin;

        // ---------------- 标签页 ----------------
        TabControl tabs;
        TabPage tpLive, tpProc, tpDate, tpHist;

        // ---------------- 实时连接 ----------------
        Label lblLiveIn, lblLiveOut, lblTodayIn, lblTodayOut;
        SplitContainer splitLive;
        DataGridView dgvIps, dgvConns;
        Label lblIpsTitle, lblConnsTitle;

        // ---------------- 进程视图 ----------------
        Label lblProcSummary;
        TreeView treeProcs;
        bool procTreeBuilt = false;
        bool procTreeExpandAllPending = false;
        HashSet<string> procTreeExpandedPending = new HashSet<string>();

        // ---------------- 按日统计 ----------------
        Label lblDateSummary;
        DataGridView dgvDate;
        Button btnExportDate;

        // ---------------- 历史概览 ----------------
        Label lblHistSummary;
        DataGridView dgvHist;

        // ---------------- 趋势（2.2.0 新增） ----------------
        TabPage tpTrend;
        Label lblTrendSummary;
        Panel trendPanel;
        DateTime lastTrendRebind = DateTime.MinValue;
        // 2.2.0 收口：趋势页归一化数据 / 悬停状态 / 缓存的 GDI 资源
        // trendPoints 每项 = [分钟序号 0..1439, 该分钟下载字节, 该分钟上传字节]，已按分钟升序且唯一
        List<long[]> trendPoints;
        long trendDayStartUnix;                 // 当日本地 0 点 unix（悬停读数换算 HH:mm 用）
        int trendHoverIndex = -1;               // 悬停命中的 trendPoints 下标；-1 = 不画十字线
        int trendDupMerged;                     // 归一化时合并掉的重复分钟数（写进标题便于排查脏数据）
        int trendDroppedOutOfDay;               // 归一化时丢弃的跨日/异常分钟数
        TrendGdiCache trendGdi;

        // ---------------- 日期行 / 活动筛选（2.2.0） ----------------
        Control dateRow;
        Label lblDateLabel;
        Label sepDate;
        ComboBox cboActivity;
        int filtMode;
        HashSet<string> filtEst, filtLong, filtTop;
        DateTime dateRowToday = DateTime.MinValue;   // 2.2.0 收口：上次刷新日期行时的“今天”，用于跨日自动刷新

        // ---------------- 排序状态 ----------------
        sealed class SortSpec
        {
            public string Col;
            public bool Desc;
        }

        sealed class DateRow
        {
            public IpAggregate A;
            public int ConnCount;
        }

        readonly SortSpec sortIps = new SortSpec { Col = "down", Desc = true };
        readonly SortSpec sortConns = new SortSpec { Col = "total", Desc = true };
        readonly SortSpec sortDate = new SortSpec { Col = "down", Desc = true };
        readonly SortSpec sortHist = new SortSpec { Col = "date", Desc = true };

        // =============================================================
        // 构造 / 生命周期
        // =============================================================
        public MainForm(AppConfig cfg, bool background, Monitor monitor, System.Threading.EventWaitHandle activateEvent, System.Threading.EventWaitHandle quitEvent, string dataDir)
        {
            this.cfg = cfg;
            this.background = background;
            this.monitor = monitor;
            this.activateEvent = activateEvent;
            this.quitEvent = quitEvent;
            this.dataDir = dataDir;
            selectedDate = DateTime.Now.ToString(DateFmt);
            adminMode = SafeIsAdmin();

            BuildUi();
            BuildTray();

            timer = new System.Windows.Forms.Timer();
            timer.Interval = 1000;
            timer.Tick += OnTimerTick;
        }

        void Trace(string msg)
        {
            Program.AppendStartup(dataDir, "MainForm: " + msg);
        }

        // 第二个实例启动时通知本实例：把窗口显示出来（修复"提示已在运行但托盘找不到"）
        void StartActivationListener()
        {
            if (activateEvent == null && quitEvent == null) return;
            System.Threading.Thread th = new System.Threading.Thread(delegate()
            {
                System.Threading.EventWaitHandle[] waits;
                if (activateEvent != null && quitEvent != null) waits = new System.Threading.EventWaitHandle[] { activateEvent, quitEvent };
                else if (activateEvent != null) waits = new System.Threading.EventWaitHandle[] { activateEvent };
                else waits = new System.Threading.EventWaitHandle[] { quitEvent };
                while (!reallyExiting)
                {
                    try
                    {
                        int idx = System.Threading.WaitHandle.WaitAny(waits, 2000);
                        if (idx == System.Threading.WaitHandle.WaitTimeout) continue;
                        if (reallyExiting) return;
                        if (waits[idx] == quitEvent)
                        {
                            // --quit：另一个进程请求本实例优雅退出（保存数据、移除托盘图标）
                            try { BeginInvoke((MethodInvoker)delegate { ExitApp(); }); } catch { }
                            return;
                        }
                        try
                        {
                            BeginInvoke((MethodInvoker)delegate
                            {
                                if (reallyExiting) return;
                                if (tray == null) BuildTray();
                                ShowMain();
                            });
                        }
                        catch { }
                    }
                    catch { return; }
                }
            });
            th.IsBackground = true;
            th.Name = "NetWatcherActivate";
            th.Start();
        }

        // 托盘图标兜底：开机自启时资源管理器可能还没准备好通知区域，重试可避免"进程在、托盘没有"
        // 2.1.1：只保证托盘图标存在，不再每次 Visible=false→true 反复重加。
        // 反复重加正是 Windows 通知区域出现"重复/幽灵图标"（鼠标划过才消失）的诱因之一。
        void EnsureTray()
        {
            try
            {
                if (reallyExiting) return;
                if (tray == null) { BuildTray(); return; }
                if (!tray.Visible) tray.Visible = true;
            }
            catch { }
        }

        // 仅在两种情况下使用：资源管理器重启（TaskbarCreated）或开机自启后通知区域尚未就绪。
        // 先干净移除旧图标（Dispose 会发 NIM_DELETE），再新建一个，避免同一图标被重复 NIM_ADD。
        void ReAddTrayIcon()
        {
            if (reallyExiting) return;
            try
            {
                if (tray != null) { tray.Visible = false; tray.Dispose(); tray = null; }
                if (trayMenu != null) { trayMenu.Dispose(); trayMenu = null; }
                BuildTray();
                Trace("托盘图标已重建");
            }
            catch { }
        }

        protected override void WndProc(ref Message m)
        {
            // 资源管理器重启后（TaskbarCreated 广播）重新添加托盘图标
            if (m.Msg == WM_TASKBARCREATED)
            {
                ReAddTrayIcon();
            }
            base.WndProc(ref m);
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            SetupSplitter();

            UpdateAdminButton();
            UpdateHeader(curSnap);
            ForceRefresh();
            timer.Start();

            StartActivationListener();

            if (background)
            {
                ShowInTaskbar = false;
                WindowState = FormWindowState.Minimized;
                Hide();
                // 2.1.1：启动后只补一次托盘图标（3 秒时重建一次），随后立即停止定时器。
                // 不再每 3 秒 × 10 次做 Visible=false→true（那是"分身/幽灵图标"的主要来源）。
                trayRetryTimer = new System.Windows.Forms.Timer();
                trayRetryTimer.Interval = 3000;
                trayRetryTimer.Tick += delegate
                {
                    trayRetryCount++;
                    if (!reallyExiting && trayRetryCount == 1) ReAddTrayIcon();
                    try { trayRetryTimer.Stop(); trayRetryTimer.Dispose(); trayRetryTimer = null; } catch { }
                };
                trayRetryTimer.Start();
            }
            Trace("OnLoad 完成 (background=" + background + ")");
        }

        void SetupSplitter()
        {
            if (splitLive == null) return;
            try
            {
                int h = splitLive.Height;
                int min = splitLive.Panel1MinSize;
                int max = h - splitLive.Panel2MinSize - splitLive.SplitterWidth;
                if (max < min) return;
                int want = (int)(h * 0.48);
                if (want < min) want = min;
                if (want > max) want = max;
                splitLive.SplitterDistance = want;
            }
            catch { }
        }

        // =============================================================
        // UI 构建
        // =============================================================
        void BuildUi()
        {
            SuspendLayout();
            Text = "IP监控2.1 · 网络连接监控 (NetWatcher)";
            ClientSize = new Size(1180, 780);
            MinimumSize = new Size(900, 620);
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Microsoft YaHei", 9F);
            BackColor = Color.FromArgb(244, 247, 251);
            Icon = LoadAppIcon();
            DoubleBuffered = true;

            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.ColumnCount = 1;
            root.RowCount = 3;
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // header auto
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));  // tabs fill
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // footer auto
            Controls.Add(root);

            root.Controls.Add(BuildHeader(), 0, 0);
            tabs = BuildTabs();
            root.Controls.Add(tabs, 0, 1);
            root.Controls.Add(BuildFooter(), 0, 2);

            toolTip = new ToolTip();
            toolTip.AutoPopDelay = 15000;
            toolTip.ShowAlways = true;
            // 2.2.0 收口：把筛选语义写进悬停提示（尤其「当前速度 Top20」不是历史累计、「仅公网」与 ShowLocalIp 的关系）
            if (cboActivity != null)
            {
                toolTip.SetToolTip(cboActivity,
                    "活动筛选（与搜索/双击 IP 筛选叠加）：\n" +
                    "· 今天新出现（NEW）：当前日期（本地日界）里首次出现的 IP，重启后按当天数据重建\n" +
                    "· 仅活跃：至少有一条 ESTABLISHED 连接\n" +
                    "· 当前速度 Top20：按本次采样速率（↓B/s + ↑B/s）取前 20 个 IP，不是历史累计\n" +
                    "· 仅公网 IP：排除内网/本机地址；设置里关闭「显示内网地址」时该项与「全部」等效\n" +
                    "· 长连接 >60 秒：该 IP 至少有一条已持续超过 60 秒的连接");
            }

            InitGridColumns();
            ResumeLayout(true);
            UpdateAdminButton();
            UpdateDateBar();
        }

        Control BuildHeader()
        {
            TableLayoutPanel header = new TableLayoutPanel();
            header.Dock = DockStyle.Fill;
            header.AutoSize = true;
            header.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            header.ColumnCount = 1;
            header.RowCount = 3;
            header.Padding = new Padding(10, 6, 10, 2);
            header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            header.RowStyles.Add(new RowStyle(SizeType.Absolute, 34F));
            header.RowStyles.Add(new RowStyle(SizeType.Absolute, 22F));
            header.RowStyles.Add(new RowStyle(SizeType.Absolute, 36F));

            // 第一行：标题 / 运行模式 / 扫描间隔
            TableLayoutPanel row0 = new TableLayoutPanel();
            row0.Dock = DockStyle.Fill;
            row0.ColumnCount = 3;
            row0.RowCount = 1;
            row0.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 46F));
            row0.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 32F));
            row0.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 22F));
            row0.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            lblTitle = new Label();
            lblTitle.Text = "IP监控2.1 · 网络连接监控";
            lblTitle.Font = new Font("Microsoft YaHei", 13F, FontStyle.Bold);
            lblTitle.ForeColor = Color.FromArgb(24, 58, 110);
            lblTitle.Dock = DockStyle.Fill;
            lblTitle.TextAlign = ContentAlignment.MiddleLeft;
            row0.Controls.Add(lblTitle, 0, 0);

            lblMode = new Label();
            lblMode.Text = "运行模式：等待首次采样…";
            lblMode.ForeColor = Color.Gray;
            lblMode.Dock = DockStyle.Fill;
            lblMode.TextAlign = ContentAlignment.MiddleLeft;
            lblMode.AutoEllipsis = true;
            row0.Controls.Add(lblMode, 1, 0);

            lblInterval = new Label();
            lblInterval.Text = "扫描间隔: " + cfg.ScanIntervalSeconds + " 秒";
            lblInterval.ForeColor = Color.DimGray;
            lblInterval.Dock = DockStyle.Fill;
            lblInterval.TextAlign = ContentAlignment.MiddleRight;
            row0.Controls.Add(lblInterval, 2, 0);

            header.Controls.Add(row0, 0, 0);

            // 第二行：最近扫描 / 连接统计（含错误提示）
            lblStatus = new Label();
            lblStatus.Text = "正在等待首次扫描…";
            lblStatus.ForeColor = Color.DimGray;
            lblStatus.Dock = DockStyle.Fill;
            lblStatus.TextAlign = ContentAlignment.MiddleLeft;
            lblStatus.Padding = new Padding(2, 0, 0, 0);
            lblStatus.AutoEllipsis = true;
            header.Controls.Add(lblStatus, 0, 1);

            // 第三行：日期行 + 搜索框 + 刷新
            header.Controls.Add(BuildDateRow(), 0, 2);
            return header;
        }

        Control BuildDateRow()
        {
            FlowLayoutPanel row = new FlowLayoutPanel();
            dateRow = row;
            row.Dock = DockStyle.Fill;
            row.AutoSize = true;
            row.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            row.WrapContents = false;
            row.FlowDirection = FlowDirection.LeftToRight;
            row.Padding = new Padding(0, 2, 0, 0);

            // 2.2.0：实时连接页用「活动筛选」替代日期行（日期在实时页本来就没有意义）
            cboActivity = new ComboBox();
            cboActivity.DropDownStyle = ComboBoxStyle.DropDownList;
            cboActivity.Width = 214;
            cboActivity.Margin = new Padding(0, 4, 8, 0);
            // 2.2.0 收口：第 4 项由「大流量 Top20」改为「当前速度 Top20」——按本采样速率排序，避免被理解为历史累计；
            // 第 2 项「今天新出现」语义见 Monitor.cs isNew 注释（按本地日界的当天数据判定）。
            cboActivity.Items.AddRange(new object[] {
                "活动筛选：全部", "活动筛选：今天新出现（NEW）", "活动筛选：仅活跃（ESTABLISHED）",
                "活动筛选：当前速度 Top20", "活动筛选：仅公网 IP", "活动筛选：长连接（>60 秒）" });
            cboActivity.SelectedIndex = 0;
            cboActivity.Visible = false;
            cboActivity.SelectedIndexChanged += delegate { RebindActiveTab(true); };
            row.Controls.Add(cboActivity);

            Label l = new Label();
            lblDateLabel = l;
            l.Text = "查看日期:";
            l.AutoSize = true;
            l.Margin = new Padding(0, 8, 4, 0);
            row.Controls.Add(l);

            btnToday = MakeSmallButton("今天", 62);
            btnToday.Click += delegate { SetDate(DateTime.Now); };
            row.Controls.Add(btnToday);

            btnYesterday = MakeSmallButton("昨天", 62);
            btnYesterday.Click += delegate { SetDate(DateTime.Now.AddDays(-1)); };
            row.Controls.Add(btnYesterday);

            btnDayBefore = MakeSmallButton("前天", 62);
            btnDayBefore.Click += delegate { SetDate(DateTime.Now.AddDays(-2)); };
            row.Controls.Add(btnDayBefore);

            datePicker = new DateTimePicker();
            datePicker.Format = DateTimePickerFormat.Custom;
            datePicker.CustomFormat = "yyyy-MM-dd";
            datePicker.Width = 120;
            datePicker.Margin = new Padding(6, 4, 0, 0);
            // 2.2.0 收口：初值用「今天 0 点」，与 UpdateDateBar 里的 MaxDate=今天 保持一致，避免首次钳位触发 ValueChanged
            datePicker.Value = DateTime.Now.Date;
            datePicker.ValueChanged += delegate
            {
                if (!inSetDate) SetDate(datePicker.Value);
            };
            row.Controls.Add(datePicker);

            Label sep = new Label();
            sepDate = sep;
            sep.Text = "|";
            sep.AutoSize = true;
            sep.ForeColor = Color.Silver;
            sep.Margin = new Padding(16, 8, 16, 0);
            row.Controls.Add(sep);

            Label lSearch = new Label();
            lSearch.Text = "搜索:";
            lSearch.AutoSize = true;
            lSearch.Margin = new Padding(0, 8, 4, 0);
            row.Controls.Add(lSearch);

            txtSearch = new TextBox();
            txtSearch.Width = 240;
            txtSearch.Margin = new Padding(0, 4, 0, 0);
            txtSearch.Font = new Font("Microsoft YaHei", 9F);
            txtSearch.TextChanged += delegate
            {
                pinnedIp = "";
                RebindActiveTab(true);
            };
            txtSearch.KeyDown += delegate(object s, KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Escape)
                {
                    pinnedIp = "";
                    txtSearch.Text = "";
                    e.SuppressKeyPress = true;
                }
            };
            row.Controls.Add(txtSearch);

            btnRefresh = MakeSmallButton("刷新", 64);
            btnRefresh.Margin = new Padding(10, 4, 0, 0);
            btnRefresh.Click += delegate { ForceRefresh(); };
            row.Controls.Add(btnRefresh);

            return row;
        }

        Control BuildFooter()
        {
            FlowLayoutPanel foot = new FlowLayoutPanel();
            foot.Dock = DockStyle.Fill;
            foot.AutoSize = true;
            foot.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            foot.WrapContents = false;
            foot.Padding = new Padding(10, 4, 10, 8);

            btnSettings = MakeFooterButton("设置", 70);
            btnSettings.Click += delegate { OpenSettings(); };
            foot.Controls.Add(btnSettings);

            btnExportFooter = MakeFooterButton("导出CSV", 92);
            btnExportFooter.Click += delegate { ExportCsv(); };
            foot.Controls.Add(btnExportFooter);

            btnOpenDir = MakeFooterButton("打开数据目录", 114);
            btnOpenDir.Click += delegate { OpenDataDir(); };
            foot.Controls.Add(btnOpenDir);

            btnAdmin = MakeFooterButton("以管理员身份重启（精确流量）", 214);
            btnAdmin.ForeColor = Color.FromArgb(176, 88, 0);
            btnAdmin.Click += delegate { RestartAsAdmin(); };
            foot.Controls.Add(btnAdmin);

            Label tip = new Label();
            tip.Text = "关闭窗口 = 最小化到托盘";
            tip.AutoSize = true;
            tip.ForeColor = Color.Gray;
            tip.Margin = new Padding(22, 10, 0, 0);
            foot.Controls.Add(tip);

            return foot;
        }

        Button MakeSmallButton(string text, int width)
        {
            Button b = new Button();
            b.Text = text;
            b.Size = new Size(width, 26);
            b.Margin = new Padding(0, 4, 4, 0);
            b.UseVisualStyleBackColor = true;
            return b;
        }

        Button MakeFooterButton(string text, int width)
        {
            Button b = new Button();
            b.Text = text;
            b.Size = new Size(width, 30);
            b.Margin = new Padding(0, 2, 8, 0);
            b.UseVisualStyleBackColor = true;
            return b;
        }

        TabControl BuildTabs()
        {
            TabControl t = new TabControl();
            t.Dock = DockStyle.Fill;
            t.Padding = new Point(14, 6);
            t.Font = new Font("Microsoft YaHei", 9F);

            tpLive = MakeTabPage("实时连接");
            tpProc = MakeTabPage("进程视图");
            tpDate = MakeTabPage("按日统计");
            tpTrend = MakeTabPage("趋势");
            tpHist = MakeTabPage("历史概览");

            t.TabPages.Add(tpLive);
            t.TabPages.Add(tpProc);
            t.TabPages.Add(tpDate);
            t.TabPages.Add(tpTrend);
            t.TabPages.Add(tpHist);

            BuildLivePage();
            BuildProcPage();
            BuildDatePage();
            BuildTrendPage();
            BuildHistPage();

            t.SelectedIndexChanged += delegate
            {
                if (!inSetDate) { UpdateDateBar(); RebindActiveTab(true); }
            };
            return t;
        }

        static TabPage MakeTabPage(string text)
        {
            TabPage p = new TabPage(text);
            p.BackColor = Color.White;
            p.Padding = new Padding(6);
            p.UseVisualStyleBackColor = false;
            return p;
        }

        static TableLayoutPanel NewFillTable(int cols, int rows)
        {
            TableLayoutPanel t = new TableLayoutPanel();
            t.Dock = DockStyle.Fill;
            t.ColumnCount = cols;
            t.RowCount = rows;
            for (int i = 0; i < cols; i++)
            {
                t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F / cols));
            }
            return t;
        }

        void BuildLivePage()
        {
            TableLayoutPanel tl = NewFillTable(1, 2);
            tl.RowStyles.Add(new RowStyle(SizeType.Absolute, 38F));
            tl.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            FlowLayoutPanel stats = new FlowLayoutPanel();
            stats.Dock = DockStyle.Fill;
            stats.AutoSize = false;
            stats.WrapContents = false;
            stats.Padding = new Padding(6, 6, 6, 2);
            lblLiveIn = MakeStatLabel(stats, "↓ 下载速度", Color.ForestGreen);
            lblLiveOut = MakeStatLabel(stats, "↑ 上传速度", Color.Firebrick);
            lblTodayIn = MakeStatLabel(stats, "今日下载", Color.ForestGreen);
            lblTodayOut = MakeStatLabel(stats, "今日上传", Color.Firebrick);
            tl.Controls.Add(stats, 0, 0);

            splitLive = new SplitContainer();
            splitLive.Dock = DockStyle.Fill;
            splitLive.Orientation = Orientation.Horizontal;
            splitLive.SplitterWidth = 6;
            splitLive.Panel1MinSize = 120;
            splitLive.Panel2MinSize = 150;
            tl.Controls.Add(splitLive, 0, 1);

            TableLayoutPanel p1 = NewFillTable(1, 2);
            p1.RowStyles.Add(new RowStyle(SizeType.Absolute, 24F));
            p1.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            lblIpsTitle = new Label();
            lblIpsTitle.Text = "各 IP 连接摘要（点击列头排序）";
            lblIpsTitle.Dock = DockStyle.Fill;
            lblIpsTitle.TextAlign = ContentAlignment.MiddleLeft;
            lblIpsTitle.Padding = new Padding(6, 0, 0, 0);
            lblIpsTitle.ForeColor = Color.DimGray;
            lblIpsTitle.AutoEllipsis = true;
            p1.Controls.Add(lblIpsTitle, 0, 0);

            dgvIps = CreateGrid();
            p1.Controls.Add(dgvIps, 0, 1);
            splitLive.Panel1.Controls.Add(p1);

            TableLayoutPanel p2 = NewFillTable(1, 2);
            p2.RowStyles.Add(new RowStyle(SizeType.Absolute, 24F));
            p2.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            lblConnsTitle = new Label();
            lblConnsTitle.Text = "当前连接明细（双击行可按该 IP 筛选上表）";
            lblConnsTitle.Dock = DockStyle.Fill;
            lblConnsTitle.TextAlign = ContentAlignment.MiddleLeft;
            lblConnsTitle.Padding = new Padding(6, 0, 0, 0);
            lblConnsTitle.ForeColor = Color.DimGray;
            lblConnsTitle.AutoEllipsis = true;
            p2.Controls.Add(lblConnsTitle, 0, 0);

            dgvConns = CreateGrid();
            dgvConns.CellDoubleClick += delegate(object s, DataGridViewCellEventArgs e)
            {
                if (e.RowIndex < 0 || e.RowIndex >= dgvConns.Rows.Count) return;
                object v = dgvConns.Rows[e.RowIndex].Cells["ip"].Value;
                string ip = v == null ? "" : Convert.ToString(v);
                if (ip.Length == 0) return;
                pinnedIp = ip;
                RebindLive(curSnap);
            };
            p2.Controls.Add(dgvConns, 0, 1);
            splitLive.Panel2.Controls.Add(p2);

            tpLive.Controls.Add(tl);
        }

        Label MakeStatLabel(Control host, string name, Color c)
        {
            Label l = new Label();
            l.Text = name + ": —";
            l.AutoSize = true;
            l.Font = new Font("Microsoft YaHei", 10F, FontStyle.Bold);
            l.ForeColor = c;
            l.Margin = new Padding(0, 3, 30, 0);
            host.Controls.Add(l);
            return l;
        }

        void BuildProcPage()
        {
            TableLayoutPanel tl = NewFillTable(1, 2);
            tl.RowStyles.Add(new RowStyle(SizeType.Absolute, 46F));
            tl.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            lblProcSummary = new Label();
            lblProcSummary.Text = "进程视图（加载中…）";
            lblProcSummary.Dock = DockStyle.Fill;
            lblProcSummary.TextAlign = ContentAlignment.MiddleLeft;
            lblProcSummary.Padding = new Padding(8, 4, 8, 0);
            lblProcSummary.ForeColor = Color.FromArgb(50, 60, 80);
            lblProcSummary.AutoEllipsis = true;
            tl.Controls.Add(lblProcSummary, 0, 0);

            treeProcs = new TreeView();
            treeProcs.Dock = DockStyle.Fill;
            treeProcs.BorderStyle = BorderStyle.FixedSingle;
            treeProcs.Font = new Font("Microsoft YaHei", 9F);
            treeProcs.HideSelection = false;
            treeProcs.ShowLines = true;
            treeProcs.ShowPlusMinus = true;
            treeProcs.ShowRootLines = true;
            treeProcs.FullRowSelect = true;
            treeProcs.ItemHeight = 22;
            treeProcs.BackColor = Color.White;
            EnableDoubleBuffer(treeProcs);
            treeProcs.NodeMouseDoubleClick += delegate(object s, TreeNodeMouseClickEventArgs e)
            {
                if (e.Node == null) return;
                string ip = e.Node.Tag as string;
                if (string.IsNullOrEmpty(ip)) return;
                pinnedIp = ip;
                if (tabs != null) tabs.SelectedTab = tpLive;
                RebindActiveTab(true);
            };
            // TreeView 隐藏时句柄可能尚未创建，Expand() 会被忽略：可见/句柄创建后再补展开
            treeProcs.HandleCreated += delegate { ApplyTreeExpansion(); };
            treeProcs.VisibleChanged += delegate { if (treeProcs.Visible) ApplyTreeExpansion(); };
            tl.Controls.Add(treeProcs, 0, 1);

            tpProc.Controls.Add(tl);
        }

        void BuildDatePage()
        {
            TableLayoutPanel tl = NewFillTable(1, 3);
            tl.RowStyles.Add(new RowStyle(SizeType.Absolute, 46F));
            tl.RowStyles.Add(new RowStyle(SizeType.Absolute, 36F));
            tl.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            lblDateSummary = new Label();
            lblDateSummary.Text = "按日统计（加载中…）";
            lblDateSummary.Dock = DockStyle.Fill;
            lblDateSummary.TextAlign = ContentAlignment.MiddleLeft;
            lblDateSummary.Padding = new Padding(8, 4, 8, 0);
            lblDateSummary.ForeColor = Color.FromArgb(50, 60, 80);
            lblDateSummary.AutoEllipsis = true;
            tl.Controls.Add(lblDateSummary, 0, 0);

            FlowLayoutPanel bar = new FlowLayoutPanel();
            bar.Dock = DockStyle.Fill;
            bar.AutoSize = false;
            bar.WrapContents = false;
            bar.Padding = new Padding(6, 3, 6, 2);
            btnExportDate = new Button();
            btnExportDate.Text = "导出CSV";
            btnExportDate.Size = new Size(96, 27);
            btnExportDate.Margin = new Padding(0, 0, 10, 0);
            btnExportDate.UseVisualStyleBackColor = true;
            btnExportDate.Click += delegate { ExportCsv(); };
            bar.Controls.Add(btnExportDate);
            Label hint = new Label();
            hint.Text = "UTF-8 BOM 编码，Excel 可直接打开；点击列头可排序";
            hint.AutoSize = true;
            hint.ForeColor = Color.Gray;
            hint.Margin = new Padding(0, 7, 0, 0);
            bar.Controls.Add(hint);
            tl.Controls.Add(bar, 0, 1);

            dgvDate = CreateGrid();
            tl.Controls.Add(dgvDate, 0, 2);

            tpDate.Controls.Add(tl);
        }

        void BuildHistPage()
        {
            TableLayoutPanel tl = NewFillTable(1, 2);
            tl.RowStyles.Add(new RowStyle(SizeType.Absolute, 30F));
            tl.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            lblHistSummary = new Label();
            lblHistSummary.Text = "历史概览（加载中…）";
            lblHistSummary.Dock = DockStyle.Fill;
            lblHistSummary.TextAlign = ContentAlignment.MiddleLeft;
            lblHistSummary.Padding = new Padding(8, 0, 8, 0);
            lblHistSummary.ForeColor = Color.FromArgb(50, 60, 80);
            lblHistSummary.AutoEllipsis = true;
            tl.Controls.Add(lblHistSummary, 0, 0);

            dgvHist = CreateGrid();
            dgvHist.CellDoubleClick += delegate(object s, DataGridViewCellEventArgs e)
            {
                if (e.RowIndex < 0 || e.RowIndex >= dgvHist.Rows.Count) return;
                string d = Convert.ToString(dgvHist.Rows[e.RowIndex].Cells["date"].Value);
                DateTime dt;
                if (DateTime.TryParse(d, out dt)) JumpToDate(dt);
            };
            tl.Controls.Add(dgvHist, 0, 1);

            tpHist.Controls.Add(tl);
        }

        // =============================================================
        // 日期行 / 活动筛选（2.2.0）
        // =============================================================
        void UpdateDateBar()
        {
            try
            {
                if (dateRow == null) return;
                bool live = (tabs != null && tabs.SelectedTab == tpLive);
                bool showDate = !live;
                Control[] dateCtrls = new Control[] { lblDateLabel, btnToday, btnYesterday, btnDayBefore, datePicker, sepDate };
                // 2.2.0 收口：显隐切换必须在 Suspend/ResumeLayout 里做并强制重排，
                // 否则 FlowLayoutPanel 隐藏→显示后可能保留旧位置（控件错位/重叠/被截断）。
                dateRow.SuspendLayout();
                try
                {
                    for (int i = 0; i < dateCtrls.Length; i++) if (dateCtrls[i] != null) dateCtrls[i].Visible = showDate;
                    if (cboActivity != null) cboActivity.Visible = live;
                    if (showDate) ApplyDateBarState();
                }
                finally
                {
                    dateRow.ResumeLayout(true);
                }
                dateRow.PerformLayout();
                Control parent = dateRow.Parent;
                if (parent != null) parent.PerformLayout();
            }
            catch { }
        }

        // 2.2.0 收口：日期行状态（今天恒可选 / 无数据置灰 / 选中高亮 / 日历禁未来 / 跨日刷新）
        void ApplyDateBarState()
        {
            DateTime today = DateTime.Now.Date;
            dateRowToday = today;
            List<string> dates = new List<string>();
            try { dates = Store.ListDates(); } catch { }
            Button[] bs = new Button[] { btnToday, btnYesterday, btnDayBefore };
            DateTime[] ds = new DateTime[] { today, today.AddDays(-1), today.AddDays(-2) };
            string sel = selectedDate;
            for (int i = 0; i < bs.Length; i++)
            {
                if (bs[i] == null) continue;
                string dsStr = ds[i].ToString(DateFmt);
                bool has = dates.Contains(dsStr);
                // 2.2.0 收口：「今天」恒可选——当天数据可能只在内存里、还没落盘（刚启动/跨日），置灰会让人以为今天没数据。
                bs[i].Enabled = (i == 0) || has || sel == dsStr;
                bs[i].BackColor = (sel == dsStr) ? Color.FromArgb(208, 226, 248) : SystemColors.Control;
            }
            if (datePicker != null)
            {
                bool old = inSetDate;
                inSetDate = true;   // MaxDate 变小时可能连带钳位 Value，必须屏蔽 ValueChanged 重入
                try
                {
                    if (datePicker.MaxDate.Date != today) datePicker.MaxDate = today;
                }
                catch { }
                finally
                {
                    inSetDate = old;
                }
            }
        }

        string DateLabel(string date)
        {
            if (string.IsNullOrEmpty(date)) return date == null ? "" : date;
            DateTime dt;
            if (!DateTime.TryParse(date, out dt)) return date;
            DateTime today = DateTime.Now.Date;
            string tag = "";
            if (dt.Date == today) tag = "今天";
            else if (dt.Date == today.AddDays(-1)) tag = "昨天";
            else if (dt.Date == today.AddDays(-2)) tag = "前天";
            return date + (tag.Length > 0 ? "（" + tag + "）" : "");
        }

        int ActivityFilter
        {
            get
            {
                try { return cboActivity == null ? 0 : (cboActivity.SelectedIndex < 0 ? 0 : cboActivity.SelectedIndex); }
                catch { return 0; }
            }
        }

        string ActivityFilterName()
        {
            int i = ActivityFilter;
            if (i == 1) return "今天新出现";
            if (i == 2) return "仅活跃连接";
            if (i == 3) return "当前速度 Top20";
            if (i == 4) return "仅公网 IP";
            if (i == 5) return "长连接 >60s";
            return "";
        }

        bool ActivityMatchIp(LiveIp li)
        {
            if (filtMode == 0) return true;
            if (li == null) return false;
            if (filtMode == 1) return li.IsNew;
            if (filtMode == 2) return filtEst != null && filtEst.Contains(li.Ip);
            if (filtMode == 3) return filtTop != null && filtTop.Contains(li.Ip);
            if (filtMode == 4) return !li.IsLocal;
            if (filtMode == 5) return filtLong != null && filtLong.Contains(li.Ip);
            return true;
        }

        bool ActivityMatchConn(LiveConn c)
        {
            if (filtMode == 0) return true;
            if (c == null) return false;
            if (filtMode == 1) return c.IsNew;
            if (filtMode == 2) return c.State == "ESTABLISHED";
            if (filtMode == 3) return filtTop != null && filtTop.Contains(c.Ip);
            if (filtMode == 4) return !c.IsLocal;
            if (filtMode == 5) return c.DurationSeconds >= 60;
            return true;
        }

        // 2.2.0 收口：空结果可读反馈——复用标题栏既有文案机制（不新造 UI/空态控件），
        // 讲清"为什么没数据 + 怎么恢复"，避免用户以为程序坏了。
        string BuildLiveEmptyHint(string q, bool hasSnapshot)
        {
            if (!hasSnapshot) return "    ·    正在等待首次采样…";
            StringBuilder sb = new StringBuilder("    ·    无匹配结果");
            List<string> why = new List<string>();
            string fname = ActivityFilterName();
            if (fname.Length > 0) why.Add("活动筛选「" + fname + "」");
            if (q.Length > 0) why.Add("搜索「" + q + "」");
            if (pinnedIp.Length > 0) why.Add("IP 筛选「" + pinnedIp + "」");
            if (cfg != null && !cfg.ShowLocalIp) why.Add("设置已隐藏内网/本机地址");
            if (why.Count > 0) sb.Append("（当前条件：").Append(string.Join("、", why.ToArray())).Append("）");
            if (filtMode == 4 && cfg != null && !cfg.ShowLocalIp)
                sb.Append("；「仅公网」与「全部」等效（内网地址已被设置隐藏），无副作用");
            sb.Append("；切回「全部」/清空搜索/点「刷新」即可恢复");
            return sb.ToString();
        }

        // =============================================================
        // 趋势页（2.2.0）：用 samples 分钟桶画 24 小时上下行曲线
        // =============================================================
        void BuildTrendPage()
        {
            TableLayoutPanel tl = NewFillTable(1, 2);
            tl.RowStyles.Add(new RowStyle(SizeType.Absolute, 30F));
            tl.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            lblTrendSummary = new Label();
            lblTrendSummary.Text = "趋势（加载中…）";
            lblTrendSummary.Dock = DockStyle.Fill;
            lblTrendSummary.TextAlign = ContentAlignment.MiddleLeft;
            lblTrendSummary.Padding = new Padding(8, 0, 8, 0);
            lblTrendSummary.ForeColor = Color.FromArgb(50, 60, 80);
            lblTrendSummary.AutoEllipsis = true;
            tl.Controls.Add(lblTrendSummary, 0, 0);

            trendPanel = new Panel();
            trendPanel.Dock = DockStyle.Fill;
            trendPanel.BackColor = Color.White;
            trendPanel.BorderStyle = BorderStyle.FixedSingle;
            trendPanel.Cursor = Cursors.Cross;
            EnableDoubleBuffer(trendPanel);
            trendPanel.Paint += delegate(object s, PaintEventArgs e) { DrawTrend(e.Graphics, trendPanel.ClientSize); };
            trendPanel.Resize += delegate { try { trendPanel.Invalidate(); } catch { } };
            // 2.2.0 收口：鼠标悬停 → 十字线 + 最近分钟读数
            trendPanel.MouseMove += TrendMouseMove;
            trendPanel.MouseLeave += delegate { ClearTrendHover(); };
            tl.Controls.Add(trendPanel, 0, 1);

            tpTrend.Controls.Add(tl);
        }

        // 2.2.0 收口：samples 语义（见 Storage.cs 的 DayData.samples 与 Monitor.Sample 分钟桶）
        //   每项 = [该分钟起点 unix, 该分钟内累计下载字节, 该分钟内累计上传播字节]；
        //   Monitor 正常写入时就地累加同一分钟、按采样时间顺序追加，最多 1440 条。
        // 绘制前统一归一化（防御历史数据 / 系统时钟回拨 / 手工造的数据）：
        //   1) 按本地日界换算成分钟序号 0..1439，跨日（负值或 >1439）项丢弃；
        //   2) 同一分钟出现多条时求和合并（每条都代表该分钟的字节，求和不会丢字节）；
        //   3) 按分钟序号升序排序（Monitor 正常写入即升序唯一，这里只是兜底）。
        static List<long[]> BuildTrendSeries(DayData d, long dayStartUnix, out int rawValid, out int dupMerged, out int droppedOutOfDay)
        {
            rawValid = 0; dupMerged = 0; droppedOutOfDay = 0;
            List<long[]> result = new List<long[]>();
            if (d == null || d.samples == null || d.samples.Count == 0) return result;

            Dictionary<int, long[]> byMinute = new Dictionary<int, long[]>();
            List<int> order = new List<int>();
            for (int i = 0; i < d.samples.Count; i++)
            {
                long[] s = d.samples[i];
                if (s == null || s.Length < 3) continue;
                rawValid++;
                if (s[0] < dayStartUnix)
                {
                    droppedOutOfDay++;
                    continue;
                }
                int minute = (int)((s[0] - dayStartUnix) / 60);
                if (minute < 0 || minute > 1439)
                {
                    droppedOutOfDay++;
                    continue;
                }
                long vIn = s[1] > 0 ? s[1] : 0;
                long vOut = s[2] > 0 ? s[2] : 0;
                long[] cur;
                if (byMinute.TryGetValue(minute, out cur))
                {
                    cur[1] += vIn;
                    cur[2] += vOut;
                    dupMerged++;
                }
                else
                {
                    byMinute[minute] = new long[] { minute, vIn, vOut };
                    order.Add(minute);
                }
            }
            order.Sort();
            for (int i = 0; i < order.Count; i++) result.Add(byMinute[order[i]]);
            return result;
        }

        // 2.2.0 收口：相邻分钟桶间隔 > TrendGapMinutes 认为程序没在运行，曲线断开不连线
        static List<List<long[]>> BuildTrendSegments(List<long[]> pts)
        {
            List<List<long[]>> segs = new List<List<long[]>>();
            if (pts == null || pts.Count == 0) return segs;
            List<long[]> cur = null;
            long prevMinute = 0;
            for (int i = 0; i < pts.Count; i++)
            {
                long[] p = pts[i];
                if (cur == null || p[0] - prevMinute > TrendGapMinutes)
                {
                    cur = new List<long[]>();
                    segs.Add(cur);
                }
                cur.Add(p);
                prevMinute = p[0];
            }
            return segs;
        }

        static int CountTrendSegments(List<long[]> pts)
        {
            if (pts == null || pts.Count == 0) return 0;
            int n = 1;
            for (int i = 1; i < pts.Count; i++)
            {
                if (pts[i][0] - pts[i - 1][0] > TrendGapMinutes) n++;
            }
            return n;
        }

        void RebindTrend()
        {
            if (lblTrendSummary == null || trendPanel == null) return;
            string date = selectedDate;
            DayData d = SafeGetDay(date);
            trendDayStartUnix = DayStartUnix(date);
            int raw = 0;
            trendPoints = BuildTrendSeries(d, trendDayStartUnix, out raw, out trendDupMerged, out trendDroppedOutOfDay);
            trendHoverIndex = -1;
            if (trendPoints.Count == 0)
            {
                lblTrendSummary.Text = "趋势 · " + DateLabel(date)
                    + "（无数据：该日期没有可绘制的分钟采样，程序需在该日运行满 1 分钟并已落盘）";
                trendPanel.Invalidate();
                return;
            }

            long sumIn = 0, sumOut = 0, peakIn = 0, peakOut = 0;
            for (int i = 0; i < trendPoints.Count; i++)
            {
                long[] p = trendPoints[i];
                sumIn += p[1]; sumOut += p[2];
                if (p[1] > peakIn) peakIn = p[1];
                if (p[2] > peakOut) peakOut = p[2];
            }
            int segCount = CountTrendSegments(trendPoints);
            StringBuilder sb = new StringBuilder();
            sb.Append("趋势 · ").Append(DateLabel(date));
            sb.Append("    ·    当日总量 ↓").Append(FmtBytes(d.bytesIn)).Append(" ↑").Append(FmtBytes(d.bytesOut));
            sb.Append("    ·    分钟桶 ").Append(trendPoints.Count).Append(" 条");
            if (raw != trendPoints.Count) sb.Append("（原始 ").Append(raw).Append(" 条，已归并/过滤）");
            if (trendDupMerged > 0) sb.Append("（合并重复 ").Append(trendDupMerged).Append(" 条）");
            if (trendDroppedOutOfDay > 0) sb.Append("（忽略跨日/异常 ").Append(trendDroppedOutOfDay).Append(" 条）");
            // 真实峰值保留在标题里（Y 轴只做“好看的取整上限”，不篡改峰值语义）
            sb.Append("    ·    峰值/分钟 ↓").Append(FmtBytes(peakIn)).Append(" ↑").Append(FmtBytes(peakOut));
            sb.Append("    ·    平均/分钟 ↓").Append(FmtBytes(sumIn / trendPoints.Count)).Append(" ↑").Append(FmtBytes(sumOut / trendPoints.Count));
            sb.Append("    ·    曲线 ").Append(segCount).Append(" 段（空档 >").Append(TrendGapMinutes).Append(" 分钟断开）");
            sb.Append("    ·    鼠标悬停查看该分钟读数");
            lblTrendSummary.Text = sb.ToString();
            trendPanel.Invalidate();
        }

        static long DayStartUnix(string date)
        {
            DateTime dt;
            if (!DateTime.TryParseExact(date, DateFmt, CultureInfo.InvariantCulture, DateTimeStyles.None, out dt))
                dt = DateTime.Today;
            return Monitor.LocalDayStartUnix(dt);
        }

        // 2.2.0 收口：GDI 资源缓存到字段（每次 Paint new Font/Pen 会产生大量临时对象）
        sealed class TrendGdiCache : IDisposable
        {
            public readonly Font AxisFont = new Font("Microsoft YaHei", 8F);
            public readonly Font LegendFont = new Font("Microsoft YaHei", 8.5F);
            public readonly Font MsgFont = new Font("Microsoft YaHei", 10F);
            public readonly Font HintFont = new Font("Microsoft YaHei", 8F);
            public readonly Font TipFont = new Font("Microsoft YaHei", 9F);
            public readonly Pen GridPen = new Pen(Color.FromArgb(226, 232, 240), 1);
            public readonly Pen InPen = new Pen(Color.FromArgb(46, 110, 200), 2);
            public readonly Pen OutPen = new Pen(Color.FromArgb(220, 120, 32), 2);
            public readonly Pen CrossPen = new Pen(Color.FromArgb(120, 130, 145), 1);
            public readonly Pen TipBorderPen = new Pen(Color.FromArgb(150, 160, 175), 1);
            public readonly Pen HoverRingPen = new Pen(Color.White, 1.5F);
            public readonly SolidBrush TextBrush = new SolidBrush(Color.Gray);
            public readonly SolidBrush HintBrush = new SolidBrush(Color.DimGray);
            public readonly SolidBrush InBrush = new SolidBrush(Color.FromArgb(46, 110, 200));
            public readonly SolidBrush OutBrush = new SolidBrush(Color.FromArgb(220, 120, 32));
            public readonly SolidBrush TipBgBrush = new SolidBrush(Color.FromArgb(255, 255, 255));
            public readonly SolidBrush TipShadowBrush = new SolidBrush(Color.FromArgb(224, 229, 236));
            public readonly SolidBrush TipTextBrush = new SolidBrush(Color.FromArgb(40, 45, 55));

            public TrendGdiCache()
            {
                CrossPen.DashStyle = System.Drawing.Drawing2D.DashStyle.Dash;
            }

            public void Dispose()
            {
                try { AxisFont.Dispose(); } catch { }
                try { LegendFont.Dispose(); } catch { }
                try { MsgFont.Dispose(); } catch { }
                try { HintFont.Dispose(); } catch { }
                try { TipFont.Dispose(); } catch { }
                try { GridPen.Dispose(); } catch { }
                try { InPen.Dispose(); } catch { }
                try { OutPen.Dispose(); } catch { }
                try { CrossPen.Dispose(); } catch { }
                try { TipBorderPen.Dispose(); } catch { }
                try { HoverRingPen.Dispose(); } catch { }
                try { TextBrush.Dispose(); } catch { }
                try { HintBrush.Dispose(); } catch { }
                try { InBrush.Dispose(); } catch { }
                try { OutBrush.Dispose(); } catch { }
                try { TipBgBrush.Dispose(); } catch { }
                try { TipShadowBrush.Dispose(); } catch { }
                try { TipTextBrush.Dispose(); } catch { }
            }
        }

        void DisposeTrendResources()
        {
            try
            {
                if (trendGdi != null) { trendGdi.Dispose(); trendGdi = null; }
            }
            catch { }
        }

        // 2.2.0 收口：趋势绘图区（上留图例、左留 Y 轴标签、下留时间轴标签）
        static bool TrendPlotRect(Size size, out int left, out int top, out int w, out int h)
        {
            left = 72; top = 26;
            w = size.Width - left - 20;
            h = size.Height - top - 36;
            return w >= 60 && h >= 40;
        }

        // 2.2.0 收口：Y 轴上界取整（1/2/2.5/5 × 10^n，按 KB/MB/GB 二进制单位取整）。
        // 保证返回上限 >= peak（曲线不会被截断），真实峰值仍显示在标题里。
        static double NiceTrendAxis(long peakBytes, int ticks, out double step)
        {
            step = 1;
            if (ticks < 1) ticks = 1;
            if (peakBytes <= 0) return ticks;   // 全 0：0..ticks 字节的平凡轴
            double[] scales = new double[] { 1, 1024, 1024.0 * 1024, 1024.0 * 1024 * 1024, 1024.0 * 1024 * 1024 * 1024 };
            int si = 0;
            while (si < scales.Length - 1 && peakBytes / scales[si] >= 1024) si++;
            double unit = scales[si];
            double target = peakBytes / unit / ticks;
            if (target < 1e-9) target = 1e-9;
            double exp = Math.Pow(10, Math.Floor(Math.Log10(target)));
            double mant = target / exp;
            double nice;
            if (mant <= 1) nice = 1;
            else if (mant <= 2) nice = 2;
            else if (mant <= 2.5) nice = 2.5;
            else if (mant <= 5) nice = 5;
            else nice = 10;
            step = nice * exp * unit;
            if (step < 1) step = 1;
            return step * ticks;
        }

        void DrawTrend(Graphics g, Size size)
        {
            try
            {
                if (trendGdi == null) trendGdi = new TrendGdiCache();
                DrawTrendCore(g, size, trendPoints, trendDayStartUnix, trendHoverIndex, trendGdi);
            }
            catch { }
        }

        static void DrawTrendCore(Graphics g, Size size, List<long[]> pts, long dayStartUnix, int hoverIndex, TrendGdiCache gdi)
        {
            g.Clear(Color.White);
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            try { g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit; } catch { }

            int left, top, w, h;
            if (!TrendPlotRect(size, out left, out top, out w, out h)) return;

            long peak = 0;
            if (pts != null)
            {
                for (int i = 0; i < pts.Count; i++)
                {
                    if (pts[i][1] > peak) peak = pts[i][1];
                    if (pts[i][2] > peak) peak = pts[i][2];
                }
            }
            double yStep;
            double yMax = NiceTrendAxis(peak, 4, out yStep);

            // 水平网格 + Y 轴标签（每秒/月字节，单位/分；上限是取整值，不是原始峰值）
            for (int i = 0; i <= 4; i++)
            {
                int y = top + h - (int)Math.Round((double)h * i / 4.0);
                g.DrawLine(gdi.GridPen, left, y, left + w, y);
                string lab = FmtBytes((long)Math.Round(yStep * i)) + "/分";
                SizeF ls = g.MeasureString(lab, gdi.AxisFont);
                float lx = left - 6 - ls.Width;
                if (lx < 2) lx = 2;
                g.DrawString(lab, gdi.AxisFont, gdi.TextBrush, new PointF(lx, y - ls.Height / 2f));
            }
            // 垂直网格 + X 轴标签（0..24 点，与分钟序号 0..1440 对齐）
            for (int hour = 0; hour <= 24; hour += 3)
            {
                int x = left + (int)Math.Round((double)w * hour / 24.0);
                g.DrawLine(gdi.GridPen, x, top, x, top + h);
                string lab = (hour == 24 ? "24:00" : hour + ":00");
                SizeF ls = g.MeasureString(lab, gdi.AxisFont);
                float lx = x - ls.Width / 2f;
                if (lx < 2) lx = 2;
                if (lx + ls.Width > size.Width - 2) lx = size.Width - 2 - ls.Width;
                g.DrawString(lab, gdi.AxisFont, gdi.TextBrush, new PointF(lx, top + h + 8));
            }

            if (pts == null || pts.Count == 0)
            {
                string msg1 = "该日期暂无可绘制的分钟采样数据";
                string msg2 = "程序需在该日运行满 1 分钟并已落盘；或该日没有采集数据";
                SizeF s1 = g.MeasureString(msg1, gdi.MsgFont);
                SizeF s2 = g.MeasureString(msg2, gdi.HintFont);
                float cx = left + (w - Math.Max(s1.Width, s2.Width)) / 2f;
                if (cx < left + 4) cx = left + 4;
                float cy = top + (h - s1.Height - s2.Height - 6) / 2f;
                if (cy < top + 4) cy = top + 4;
                g.DrawString(msg1, gdi.MsgFont, gdi.TextBrush, new PointF(cx, cy));
                g.DrawString(msg2, gdi.HintFont, gdi.HintBrush, new PointF(cx, cy + s1.Height + 6));
                return;
            }

            // 曲线：同一条连续分钟段内连线；空档 >5 分钟断开（程序未运行不连线）
            List<List<long[]>> segs = BuildTrendSegments(pts);
            for (int si = 0; si < segs.Count; si++)
            {
                List<long[]> seg = segs[si];
                if (seg.Count == 1)
                {
                    DrawTrendDot(g, seg[0], left, top, w, h, yMax, gdi.InPen, gdi.OutPen);
                    continue;
                }
                PointF[] pin = new PointF[seg.Count];
                PointF[] pout = new PointF[seg.Count];
                for (int i = 0; i < seg.Count; i++)
                {
                    long[] p = seg[i];
                    float x = left + (float)((double)w * p[0] / 1440.0);
                    pin[i] = new PointF(x, top + h - (float)((double)h * p[1] / yMax));
                    pout[i] = new PointF(x, top + h - (float)((double)h * p[2] / yMax));
                }
                g.DrawLines(gdi.InPen, pin);
                g.DrawLines(gdi.OutPen, pout);
            }

            // 图例（2.2.0 收口：画在绘图区上方留白里，避免挡住 00:00 附近的高值点）
            g.FillRectangle(gdi.InBrush, left + 8, 6, 10, 10);
            g.DrawString("下载/分钟", gdi.LegendFont, gdi.InBrush, left + 22, 2);
            g.FillRectangle(gdi.OutBrush, left + 118, 6, 10, 10);
            g.DrawString("上传/分钟", gdi.LegendFont, gdi.OutBrush, left + 132, 2);

            // 悬停读数：十字线 + 最近分钟的时间/下载/上传
            if (hoverIndex >= 0 && hoverIndex < pts.Count)
                DrawTrendHover(g, gdi, size, left, top, w, h, pts[hoverIndex], dayStartUnix, yMax);
        }

        static void DrawTrendDot(Graphics g, long[] p, int left, int top, int w, int h, double yMax, Pen inPen, Pen outPen)
        {
            float x = left + (float)((double)w * p[0] / 1440.0);
            float yIn = top + h - (float)((double)h * p[1] / yMax);
            float yOut = top + h - (float)((double)h * p[2] / yMax);
            g.DrawEllipse(inPen, x - 2, yIn - 2, 4, 4);
            g.DrawEllipse(outPen, x - 2, yOut - 2, 4, 4);
        }

        static string TrendMinuteLabel(long dayStartUnix, long minute)
        {
            try
            {
                DateTime local = DateTimeOffset.FromUnixTimeSeconds(dayStartUnix + minute * 60).ToLocalTime().DateTime;
                return local.ToString("HH:mm");
            }
            catch
            {
                return minute + " 分";
            }
        }

        static void DrawTrendHover(Graphics g, TrendGdiCache gdi, Size size, int left, int top, int w, int h, long[] p, long dayStartUnix, double yMax)
        {
            float x = left + (float)((double)w * p[0] / 1440.0);
            g.DrawLine(gdi.CrossPen, x, top, x, top + h);

            float yIn = top + h - (float)((double)h * p[1] / yMax);
            float yOut = top + h - (float)((double)h * p[2] / yMax);
            g.FillEllipse(gdi.InBrush, x - 3.5f, yIn - 3.5f, 7, 7);
            g.FillEllipse(gdi.OutBrush, x - 3.5f, yOut - 3.5f, 7, 7);
            g.DrawEllipse(gdi.HoverRingPen, x - 3.5f, yIn - 3.5f, 7, 7);
            g.DrawEllipse(gdi.HoverRingPen, x - 3.5f, yOut - 3.5f, 7, 7);

            string line1 = TrendMinuteLabel(dayStartUnix, p[0]) + " 这一分钟";
            string line2 = "↓ " + FmtBytes(p[1]) + "    ↑ " + FmtBytes(p[2]);
            SizeF s1 = g.MeasureString(line1, gdi.TipFont);
            SizeF s2 = g.MeasureString(line2, gdi.TipFont);
            float bw = Math.Max(s1.Width, s2.Width) + 14;
            float bh = s1.Height + s2.Height + 12;
            float bx = x + 12;
            if (bx + bw > size.Width - 4) bx = x - 12 - bw;
            if (bx < 4) bx = 4;
            float by = top + 8;
            if (by + bh > top + h - 4) by = top + h - 4 - bh;
            if (by < top + 4) by = top + 4;
            g.FillRectangle(gdi.TipShadowBrush, bx + 2, by + 2, bw, bh);
            g.FillRectangle(gdi.TipBgBrush, bx, by, bw, bh);
            g.DrawRectangle(gdi.TipBorderPen, bx, by, bw, bh);
            g.DrawString(line1, gdi.TipFont, gdi.TipTextBrush, new PointF(bx + 7, by + 4));
            g.DrawString(line2, gdi.TipFont, gdi.TipTextBrush, new PointF(bx + 7, by + 6 + s1.Height));
        }

        void TrendMouseMove(object sender, MouseEventArgs e)
        {
            try
            {
                if (trendPoints == null || trendPoints.Count == 0 || trendPanel == null)
                {
                    ClearTrendHover();
                    return;
                }
                int left, top, w, h;
                if (!TrendPlotRect(trendPanel.ClientSize, out left, out top, out w, out h))
                {
                    ClearTrendHover();
                    return;
                }
                if (e.X < left - 4 || e.X > left + w + 4 || e.Y < top - 4 || e.Y > top + h + 4)
                {
                    ClearTrendHover();
                    return;
                }
                double minuteF = (e.X - left) * 1440.0 / w;
                int best = 0;
                double bestDist = Math.Abs(trendPoints[0][0] - minuteF);
                for (int i = 1; i < trendPoints.Count; i++)
                {
                    double dist = Math.Abs(trendPoints[i][0] - minuteF);
                    if (dist < bestDist) { bestDist = dist; best = i; }
                }
                if (best != trendHoverIndex)
                {
                    trendHoverIndex = best;
                    trendPanel.Invalidate();
                }
            }
            catch { }
        }

        void ClearTrendHover()
        {
            if (trendHoverIndex < 0) return;
            trendHoverIndex = -1;
            try { if (trendPanel != null) trendPanel.Invalidate(); }
            catch { }
        }

        // 2.2.0 收口：1440 点绘制性能自测（--selftest 调用；只画到内存位图，不写数据目录、不弹窗）
        internal static string TrendPerfSelfTest()
        {
            try
            {
                const int pointCount = 1440;
                const int rounds = 20;
                List<long[]> pts = new List<long[]>(pointCount);
                for (int i = 0; i < pointCount; i++)
                {
                    double vIn = 1500000 + 1200000 * Math.Sin(i / 300.0);
                    double vOut = 400000 + 300000 * Math.Cos(i / 400.0);
                    pts.Add(new long[] { i, (long)Math.Max(0, vIn), (long)Math.Max(0, vOut) });
                }
                using (TrendGdiCache gdi = new TrendGdiCache())
                using (Bitmap bmp = new Bitmap(1000, 520))
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    DrawTrendCore(g, bmp.Size, pts, 1700000000L - (1700000000L % 60), -1, gdi);   // 预热
                    Stopwatch sw = Stopwatch.StartNew();
                    for (int i = 0; i < rounds; i++)
                        DrawTrendCore(g, bmp.Size, pts, 1700000000L - (1700000000L % 60), (i * 53) % pointCount, gdi);
                    sw.Stop();
                    double avg = sw.Elapsed.TotalMilliseconds / rounds;
                    return string.Format("趋势绘制 1440 点 × {0} 次：平均 {1:0.0} ms/次，最坏含悬停十字线；位图 {2}×{3}",
                        rounds, avg, bmp.Width, bmp.Height);
                }
            }
            catch (Exception ex)
            {
                return "趋势绘制性能自测异常: " + ex.Message;
            }
        }

        // =============================================================
        // DataGridView 基础
        // =============================================================
        DataGridView CreateGrid()
        {
            DataGridView g = new DataGridView();
            g.Dock = DockStyle.Fill;
            g.ReadOnly = true;
            g.AllowUserToAddRows = false;
            g.AllowUserToDeleteRows = false;
            g.AllowUserToResizeRows = false;
            g.RowHeadersVisible = false;
            g.MultiSelect = false;
            g.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            g.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
            g.ColumnHeadersHeight = 28;
            g.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.DisableResizing;
            g.RowTemplate.Height = 24;
            g.BackgroundColor = Color.White;
            g.BorderStyle = BorderStyle.FixedSingle;
            g.GridColor = Color.FromArgb(226, 232, 240);
            g.EnableHeadersVisualStyles = false;
            g.ClipboardCopyMode = DataGridViewClipboardCopyMode.Disable;
            g.ShowCellToolTips = true;

            g.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(237, 242, 249);
            g.ColumnHeadersDefaultCellStyle.ForeColor = Color.FromArgb(28, 46, 74);
            g.ColumnHeadersDefaultCellStyle.Font = new Font("Microsoft YaHei", 9F, FontStyle.Bold);
            g.ColumnHeadersDefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleLeft;
            g.ColumnHeadersDefaultCellStyle.WrapMode = DataGridViewTriState.False;

            g.DefaultCellStyle.Font = new Font("Microsoft YaHei", 9F);
            g.DefaultCellStyle.BackColor = Color.White;
            g.DefaultCellStyle.ForeColor = Color.FromArgb(28, 32, 40);
            g.AlternatingRowsDefaultCellStyle.BackColor = Color.FromArgb(248, 250, 253);
            g.DefaultCellStyle.SelectionBackColor = Color.FromArgb(46, 110, 200);
            g.DefaultCellStyle.SelectionForeColor = Color.White;

            g.KeyDown += GridKeyDown;
            AttachCopyMenu(g);
            EnableDoubleBuffer(g);
            return g;
        }

        static void AddCol(DataGridView g, string name, string header, float weight, DataGridViewContentAlignment align)
        {
            DataGridViewTextBoxColumn c = new DataGridViewTextBoxColumn();
            c.Name = name;
            c.HeaderText = header;
            c.FillWeight = weight;
            c.MinimumWidth = 40;
            c.SortMode = DataGridViewColumnSortMode.Programmatic;
            c.DefaultCellStyle.Alignment = align;
            // 注意：不要在 g.Columns.Add 之前访问 HeaderCell.SortGlyphDirection，
            // 否则 DataGridViewColumnHeaderCell 会抛 "只能在属于 DataGridView 控件的单元格上执行操作"。
            g.Columns.Add(c);
        }

        void InitGridColumns()
        {
            // 上表：IP / 城市地区 / 运营商 / 连接数 / ↓速度 / ↑速度 / 标记
            AddCol(dgvIps, "ip", "IP 地址", 132, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvIps, "loc", "城市 / 地区", 148, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvIps, "isp", "运营商", 108, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvIps, "conns", "连接数", 56, DataGridViewContentAlignment.MiddleCenter);
            AddCol(dgvIps, "down", "↓ 速度", 86, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvIps, "up", "↑ 速度", 86, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvIps, "flag", "标记", 52, DataGridViewContentAlignment.MiddleCenter);
            dgvIps.ColumnHeaderMouseClick += delegate(object s, DataGridViewCellMouseEventArgs e)
            {
                HandleHeaderClick(dgvIps, sortIps, e, delegate { RebindLive(curSnap); });
            };
            dgvIps.ContextMenuStrip.Items.Add(new ToolStripSeparator());
            dgvIps.ContextMenuStrip.Items.Add("清除 IP 筛选", null, delegate
            {
                pinnedIp = "";
                RebindLive(curSnap);
            });

            // 下表：IP / 地址 / 应用程序 / PID / 端口 / 协议 / 上传 / 下载 / 总流量 / 时长 / 标记
            AddCol(dgvConns, "ip", "IP 地址", 116, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvConns, "loc", "地址", 132, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvConns, "proc", "应用程序", 110, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvConns, "pid", "PID", 54, DataGridViewContentAlignment.MiddleCenter);
            AddCol(dgvConns, "rport", "端口", 54, DataGridViewContentAlignment.MiddleCenter);
            AddCol(dgvConns, "proto", "协议", 50, DataGridViewContentAlignment.MiddleCenter);
            AddCol(dgvConns, "up", "上传", 80, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvConns, "down", "下载", 80, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvConns, "total", "总流量", 86, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvConns, "dur", "时长", 80, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvConns, "flag", "标记", 48, DataGridViewContentAlignment.MiddleCenter);
            dgvConns.ColumnHeaderMouseClick += delegate(object s, DataGridViewCellMouseEventArgs e)
            {
                HandleHeaderClick(dgvConns, sortConns, e, delegate { RebindLive(curSnap); });
            };

            // 按日统计：IP / 城市 / 地区 / 运营商 / 时长 / 会话数 / 连接次数 / 首次 / 最近 / 下载 / 上传 / 平均速率 / 峰值速率
            AddCol(dgvDate, "ip", "IP 地址", 118, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvDate, "city", "城市", 66, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvDate, "region", "地区", 66, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvDate, "isp", "运营商", 92, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvDate, "dur", "连接时长", 82, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvDate, "sess", "会话数", 58, DataGridViewContentAlignment.MiddleCenter);
            AddCol(dgvDate, "conns", "连接次数", 68, DataGridViewContentAlignment.MiddleCenter);
            AddCol(dgvDate, "first", "首次连接", 84, DataGridViewContentAlignment.MiddleCenter);
            AddCol(dgvDate, "last", "最近连接", 84, DataGridViewContentAlignment.MiddleCenter);
            AddCol(dgvDate, "down", "下载", 82, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvDate, "up", "上传", 82, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvDate, "avg", "平均速率", 88, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvDate, "peak", "峰值速率", 88, DataGridViewContentAlignment.MiddleRight);
            dgvDate.ColumnHeaderMouseClick += delegate(object s, DataGridViewCellMouseEventArgs e)
            {
                HandleHeaderClick(dgvDate, sortDate, e, delegate { RebindDate(); });
            };

            // 历史概览：日期 / 下载 / 上传 / 峰值 / 进程数 / IP 数 / 采样数
            AddCol(dgvHist, "date", "日期", 96, DataGridViewContentAlignment.MiddleLeft);
            AddCol(dgvHist, "down", "下载", 104, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvHist, "up", "上传", 104, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvHist, "peak", "峰值", 158, DataGridViewContentAlignment.MiddleRight);
            AddCol(dgvHist, "procs", "进程数", 70, DataGridViewContentAlignment.MiddleCenter);
            AddCol(dgvHist, "ips", "IP 数", 70, DataGridViewContentAlignment.MiddleCenter);
            AddCol(dgvHist, "samples", "采样数", 70, DataGridViewContentAlignment.MiddleCenter);
            dgvHist.ColumnHeaderMouseClick += delegate(object s, DataGridViewCellMouseEventArgs e)
            {
                HandleHeaderClick(dgvHist, sortHist, e, delegate { RebindHist(); });
            };
        }

        void HandleHeaderClick(DataGridView g, SortSpec spec, DataGridViewCellMouseEventArgs e, Action rebind)
        {
            if (e.ColumnIndex < 0 || e.ColumnIndex >= g.Columns.Count) return;
            string col = g.Columns[e.ColumnIndex].Name;
            if (spec.Col == col) spec.Desc = !spec.Desc;
            else
            {
                spec.Col = col;
                spec.Desc = true;
            }
            if (rebind != null) rebind();
        }

        static void ApplySortGlyph(DataGridView g, SortSpec spec)
        {
            foreach (DataGridViewColumn c in g.Columns)
            {
                c.HeaderCell.SortGlyphDirection = SortOrder.None;
            }
            if (spec != null && spec.Col != null && g.Columns.Contains(spec.Col))
            {
                g.Columns[spec.Col].HeaderCell.SortGlyphDirection = spec.Desc ? SortOrder.Descending : SortOrder.Ascending;
            }
        }

        void AttachCopyMenu(DataGridView g)
        {
            ContextMenuStrip m = new ContextMenuStrip();
            m.Items.Add("复制当前行", null, delegate { CopyCurrentRow(g); });
            m.Items.Add("复制全部可见行", null, delegate { CopyAllRows(g); });
            g.ContextMenuStrip = m;
        }

        void GridKeyDown(object sender, KeyEventArgs e)
        {
            DataGridView g = sender as DataGridView;
            if (g == null) return;
            if (e.Control && e.KeyCode == Keys.C)
            {
                CopyCurrentRow(g);
                e.Handled = true;
                e.SuppressKeyPress = true;
            }
        }

        void CopyCurrentRow(DataGridView g)
        {
            if (g.CurrentRow == null) return;
            string text = RowToText(g.CurrentRow);
            if (text.Length == 0) return;
            try { Clipboard.SetText(text); }
            catch { }
        }

        void CopyAllRows(DataGridView g)
        {
            StringBuilder sb = new StringBuilder();
            foreach (DataGridViewRow row in g.Rows)
            {
                if (row.IsNewRow) continue;
                if (sb.Length > 0) sb.AppendLine();
                sb.Append(RowToText(row));
            }
            if (sb.Length == 0) return;
            try { Clipboard.SetText(sb.ToString()); }
            catch { }
        }

        static string RowToText(DataGridViewRow row)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < row.Cells.Count; i++)
            {
                if (i > 0) sb.Append('\t');
                object v = row.Cells[i].Value;
                sb.Append(v == null ? "" : Convert.ToString(v));
            }
            return sb.ToString();
        }

        static void StyleRow(DataGridView g, int rowIndex, bool isNew)
        {
            if (rowIndex < 0 || rowIndex >= g.Rows.Count) return;
            DataGridViewRow r = g.Rows[rowIndex];
            if (!isNew) return;
            r.DefaultCellStyle.BackColor = Color.FromArgb(255, 248, 214);
            r.DefaultCellStyle.ForeColor = Color.FromArgb(120, 60, 0);
        }

        void MarkNewCell(DataGridView g, int rowIndex)
        {
            if (rowIndex < 0 || rowIndex >= g.Rows.Count) return;
            int idx = g.Columns.Count - 1;
            if (idx < 0) return;
            DataGridViewCell c = g.Rows[rowIndex].Cells[idx];
            c.Style.ForeColor = Color.OrangeRed;
            c.Style.Font = newBadgeFont;
        }

        static int GetScroll(DataGridView g)
        {
            try { return g.FirstDisplayedScrollingRowIndex; }
            catch { return -1; }
        }

        static void RestoreScroll(DataGridView g, int idx)
        {
            if (idx <= 0 || idx >= g.Rows.Count) return;
            try { g.FirstDisplayedScrollingRowIndex = idx; }
            catch { }
        }

        static void EnableDoubleBuffer(Control c)
        {
            try
            {
                PropertyInfo pi = c.GetType().GetProperty("DoubleBuffered", BindingFlags.Instance | BindingFlags.NonPublic);
                if (pi == null)
                {
                    pi = typeof(Control).GetProperty("DoubleBuffered", BindingFlags.Instance | BindingFlags.NonPublic);
                }
                if (pi != null) pi.SetValue(c, true, null);
            }
            catch { }
        }

        // =============================================================
        // 刷新调度（1s 定时器；仅 LastScan 变化时重绑表格）
        // =============================================================
        void OnTimerTick(object sender, EventArgs e)
        {
            Snapshot snap;
            try { snap = monitor.GetSnapshot(); }
            catch { return; }
            if (snap == null) return;
            curSnap = snap;
            UpdateHeader(snap);

            // 2.2.0 收口：跨日自动刷新日期行（今天高亮/昨天置灰/日历 MaxDate）。
            // 若用户正停在“今天”，跟随到新的今天；若停在历史日期则只刷新按钮状态。
            try
            {
                DateTime todayNow = DateTime.Now.Date;
                if (dateRowToday != DateTime.MinValue && dateRowToday != todayNow)
                {
                    string oldToday = dateRowToday.ToString(DateFmt);
                    dateRowToday = todayNow;
                    if (selectedDate == oldToday || string.CompareOrdinal(selectedDate, todayNow.ToString(DateFmt)) > 0)
                        SetDate(todayNow);
                    else
                        UpdateDateBar();
                }
            }
            catch { }

            if (snap.LastScan != lastScanRendered)
            {
                lastScanRendered = snap.LastScan;
                // 2.1 优化（P1-11）：实时页每次采样刷新；进程/按日页 5 秒、历史页 15 秒节流，
                // 避免非实时页也随 2 秒采样整表重建（UI 线程被占、选中行/滚动位置丢失）。
                if (tabs == null || tabs.SelectedTab == null)
                {
                    RebindActiveTab(true);
                }
                else if (tabs.SelectedTab == tpLive)
                {
                    RebindLive(curSnap);
                }
                else if (tabs.SelectedTab == tpProc)
                {
                    if ((DateTime.Now - lastProcRebind).TotalSeconds >= 5) { lastProcRebind = DateTime.Now; RebindProc(); }
                }
                else if (tabs.SelectedTab == tpDate)
                {
                    if ((DateTime.Now - lastDateRebind).TotalSeconds >= 5) { lastDateRebind = DateTime.Now; RebindDate(); }
                }
                else if (tabs.SelectedTab == tpTrend)
                {
                    if ((DateTime.Now - lastTrendRebind).TotalSeconds >= 15) { lastTrendRebind = DateTime.Now; RebindTrend(); }
                }
                else if (tabs.SelectedTab == tpHist)
                {
                    if ((DateTime.Now - lastHistRebind).TotalSeconds >= 15) { lastHistRebind = DateTime.Now; RebindHist(); }
                }
                else
                {
                    RebindActiveTab(true);
                }
                CheckNewIpBalloon(snap);
            }
        }

        void ForceRefresh()
        {
            try { curSnap = monitor.GetSnapshot(); }
            catch { }
            if (curSnap != null)
            {
                lastScanRendered = curSnap.LastScan;
                UpdateHeader(curSnap);
            }
            RebindActiveTab(true);
            if (curSnap != null) CheckNewIpBalloon(curSnap);
        }

        void RebindActiveTab(bool force)
        {
            if (tabs == null || tabs.SelectedTab == null) return;
            DateTime now = DateTime.Now;
            lastProcRebind = now; lastDateRebind = now; lastHistRebind = now;
            UpdateDateBar();
            if (tabs.SelectedTab == tpLive) RebindLive(curSnap);
            else if (tabs.SelectedTab == tpProc) RebindProc();
            else if (tabs.SelectedTab == tpDate) RebindDate();
            else if (tabs.SelectedTab == tpTrend) RebindTrend();
            else if (tabs.SelectedTab == tpHist) RebindHist();
        }

        void UpdateHeader(Snapshot snap)
        {
            if (lblInterval != null) lblInterval.Text = "扫描间隔: " + cfg.ScanIntervalSeconds + " 秒";
            if (snap == null || snap.LastScan == DateTime.MinValue)
            {
                if (lblStatus != null)
                {
                    lblStatus.Text = "正在等待首次扫描…";
                    lblStatus.ForeColor = Color.DimGray;
                }
                if (lblMode != null)
                {
                    lblMode.Text = "运行模式：等待首次采样…";
                    lblMode.ForeColor = Color.Gray;
                }
                return;
            }

            string s = "最近扫描: " + snap.LastScan.ToString("HH:mm:ss")
                + "   ·   已建立连接 " + snap.EstablishedCount + " 条"
                + "   ·   逐IP精确连接 " + snap.PreciseConnCount + " 条";
            if (!string.IsNullOrEmpty(snap.LastError))
            {
                s += "   ·   错误: " + Truncate(snap.LastError, 80);
                lblStatus.ForeColor = Color.Firebrick;
            }
            else
            {
                lblStatus.ForeColor = Color.DimGray;
            }
            lblStatus.Text = s;
            if (toolTip != null && lblStatus != null)
            {
                toolTip.SetToolTip(lblStatus, string.IsNullOrEmpty(snap.LastError) ? "" : snap.LastError);
            }

            // 运行模式：精确 = 管理员 且 本次采样至少一条连接 EStats 成功（按 Lead 约定，别只看 BytesPrecise）
            bool preciseNow = snap.IsAdmin && snap.PreciseConnCount > 0;
            if (preciseNow)
            {
                lblMode.Text = "运行模式：逐IP精确（管理员）";
                lblMode.ForeColor = Color.ForestGreen;
            }
            else if (snap.IsAdmin)
            {
                lblMode.Text = "运行模式：逐IP估算（管理员，本次采样无 EStats 数据）";
                lblMode.ForeColor = Color.DarkOrange;
            }
            else
            {
                lblMode.Text = "运行模式：逐IP估算（非管理员）";
                lblMode.ForeColor = Color.DarkOrange;
            }

            if (snap.IsAdmin != adminMode)
            {
                adminMode = snap.IsAdmin;
                UpdateAdminButton();
            }

            try
            {
                string estatErr = monitor.LastEStatsError;
                StringBuilder modeTip = new StringBuilder();
                modeTip.Append(preciseNow ? "本次采样 " + snap.PreciseConnCount + " 条连接拿到 EStats 精确字节" : "逐 IP 字节为总量估算");
                modeTip.Append(snap.BytesPrecise ? "\n当天曾成功读取 EStats（BytesPrecise=true）" : "\n当天尚未成功读取 EStats");
                modeTip.Append("\n精确字节仅覆盖 IPv4 TCP 连接；IPv6 / UDP 只计入总流量，无法逐 IP 归因");
                if (!string.IsNullOrEmpty(estatErr)) modeTip.Append("\nEStats 诊断: ").Append(estatErr);
                if (toolTip != null && lblMode != null) toolTip.SetToolTip(lblMode, modeTip.ToString());
            }
            catch { }

            if (lblLiveIn != null)
            {
                lblLiveIn.Text = "↓ 下载速度  " + FmtRate(snap.TotalInBps);
                lblLiveOut.Text = "↑ 上传速度  " + FmtRate(snap.TotalOutBps);
                lblTodayIn.Text = "今日下载  " + FmtBytes(snap.TodayInBytes);
                lblTodayOut.Text = "今日上传  " + FmtBytes(snap.TodayOutBytes);
            }
        }

        void UpdateVolumeLabels(Snapshot snap)
        {
            if (snap == null || lblLiveIn == null) return;
            lblLiveIn.Text = "↓ 下载速度  " + FmtRate(snap.TotalInBps);
            lblLiveOut.Text = "↑ 上传速度  " + FmtRate(snap.TotalOutBps);
            lblTodayIn.Text = "今日下载  " + FmtBytes(snap.TodayInBytes);
            lblTodayOut.Text = "今日上传  " + FmtBytes(snap.TodayOutBytes);
        }

        void UpdateAdminButton()
        {
            if (btnAdmin == null) return;
            btnAdmin.Visible = !adminMode;
        }

        void UpdateIntervalLabel()
        {
            if (lblInterval != null) lblInterval.Text = "扫描间隔: " + cfg.ScanIntervalSeconds + " 秒";
        }

        static bool SafeIsAdmin()
        {
            try { return NativeMethods.IsAdministrator(); }
            catch { return false; }
        }

        // =============================================================
        // 实时连接页
        // =============================================================
        void RebindLive(Snapshot snap)
        {
            if (dgvIps == null) return;
            string q = Query;
            List<LiveIp> ips = new List<LiveIp>();
            List<LiveConn> conns = new List<LiveConn>();

            // 2.2.0：活动筛选（全部 / 今天新出现 / 仅活跃 / 当前速度 Top20 / 仅公网 / 长连接）
            // 2.2.0 收口：第 4 项语义澄清——「当前速度 Top20」按本采样速率（BytesIn+BytesOut ÷ 采样间隔 = B/s）排序，
            // 不是历史累计；IP 表与连接表使用同一份 IP 集合（都由本采样快照得出），口径一致。
            // （旧实现用 c.BytesIn + c.BytesOut —— 那是连接生命周期累计，容易被误解为"大流量"。）
            filtMode = ActivityFilter;
            filtEst = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            filtLong = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            filtTop = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (snap != null && snap.Conns != null)
            {
                Dictionary<string, long> speeds = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
                foreach (LiveConn c in snap.Conns)
                {
                    if (c == null) continue;
                    if (c.State == "ESTABLISHED") filtEst.Add(c.Ip);
                    if (c.DurationSeconds >= 60) filtLong.Add(c.Ip);
                    long sp = c.SpeedInBps + c.SpeedOutBps;
                    long old;
                    if (!speeds.TryGetValue(c.Ip, out old)) old = 0;
                    speeds[c.Ip] = old + sp;
                }
                if (filtMode == 3)
                {
                    List<KeyValuePair<string, long>> tl = new List<KeyValuePair<string, long>>(speeds);
                    tl.Sort(delegate(KeyValuePair<string, long> a, KeyValuePair<string, long> b) { return b.Value.CompareTo(a.Value); });
                    for (int i = 0; i < tl.Count && i < 20; i++) filtTop.Add(tl[i].Key);
                }
            }

            if (snap != null)
            {
                if (snap.LiveIps != null)
                {
                    foreach (LiveIp li in snap.LiveIps)
                    {
                        if (li == null) continue;
                        if (!cfg.ShowLocalIp && li.IsLocal) continue;
                        if (!MatchLiveIp(q, li)) continue;
                        if (!ActivityMatchIp(li)) continue;
                        if (pinnedIp.Length > 0 && string.Compare(li.Ip, pinnedIp, StringComparison.OrdinalIgnoreCase) != 0) continue;
                        ips.Add(li);
                    }
                }
                if (snap.Conns != null)
                {
                    foreach (LiveConn c in snap.Conns)
                    {
                        if (c == null) continue;
                        if (!cfg.ShowLocalIp && c.IsLocal) continue;
                        if (!MatchLiveConn(q, c)) continue;
                        if (!ActivityMatchConn(c)) continue;
                        conns.Add(c);
                    }
                }
            }

            SortLiveIps(ips);
            SortLiveConns(conns);

            int scrollIps = GetScroll(dgvIps);
            int scrollConns = GetScroll(dgvConns);
            dgvIps.SuspendLayout();
            dgvConns.SuspendLayout();
            try
            {
                dgvIps.Rows.Clear();
                foreach (LiveIp li in ips)
                {
                    int idx = dgvIps.Rows.Add(new object[]
                    {
                        li.Ip,
                        Loc(li.Country, li.Region, li.City),
                        string.IsNullOrEmpty(li.Isp) ? "-" : li.Isp,
                        li.ConnCount,
                        FmtRate(li.SpeedInBps),
                        FmtRate(li.SpeedOutBps),
                        li.IsNew ? "NEW" : ""
                    });
                    if (li.IsNew)
                    {
                        StyleRow(dgvIps, idx, true);
                        MarkNewCell(dgvIps, idx);
                    }
                    StringBuilder tip = new StringBuilder();
                    if (!string.IsNullOrEmpty(li.Hostname)) tip.Append("域名: ").Append(li.Hostname).Append('\n');
                    if (!string.IsNullOrEmpty(li.Processes)) tip.Append("进程: ").Append(li.Processes).Append('\n');
                    tip.Append("本次累计 ↓").Append(FmtBytes(li.BytesIn)).Append("  ↑").Append(FmtBytes(li.BytesOut));
                    tip.Append('\n').Append(li.Precise ? "字节来源: 逐连接 EStats（精确）" : "字节来源: 总流量估算");
                    if (li.IsLocal) tip.Append("\n（内网/本机地址）");
                    dgvIps.Rows[idx].Cells["ip"].ToolTipText = tip.ToString();
                }

                dgvConns.Rows.Clear();
                foreach (LiveConn c in conns)
                {
                    string proc = string.IsNullOrEmpty(c.ProcessName) ? "(未知)" : c.ProcessName;
                    int idx = dgvConns.Rows.Add(new object[]
                    {
                        c.Ip,
                        Loc(c.Country, c.Region, c.City),
                        proc,
                        c.Pid,
                        c.RemotePort,
                        string.IsNullOrEmpty(c.Proto) ? "TCP" : c.Proto,
                        FmtBytes(c.BytesOut),
                        FmtBytes(c.BytesIn),
                        FmtBytes(c.BytesIn + c.BytesOut),
                        FmtDuration(c.DurationSeconds),
                        c.IsNew ? "NEW" : ""
                    });
                    if (c.IsNew)
                    {
                        StyleRow(dgvConns, idx, true);
                        MarkNewCell(dgvConns, idx);
                    }
                    StringBuilder tip = new StringBuilder();
                    if (!string.IsNullOrEmpty(c.ProcessPath)) tip.Append("路径: ").Append(c.ProcessPath).Append('\n');
                    if (!string.IsNullOrEmpty(c.Hostname)) tip.Append("域名: ").Append(c.Hostname).Append('\n');
                    tip.Append("本地端口: ").Append(c.LocalPort).Append("   状态: ").Append(c.State);
                    tip.Append('\n').Append(c.Precise ? "字节来源: 逐连接 EStats（精确）" : "字节来源: 总流量估算");
                    dgvConns.Rows[idx].Cells["ip"].ToolTipText = tip.ToString();
                }
            }
            finally
            {
                dgvIps.ResumeLayout();
                dgvConns.ResumeLayout();
            }

            RestoreScroll(dgvIps, scrollIps);
            RestoreScroll(dgvConns, scrollConns);
            ApplySortGlyph(dgvIps, sortIps);
            ApplySortGlyph(dgvConns, sortConns);

            string fname = ActivityFilterName();
            // 2.2.0 收口：空结果/筛选说明直接写在标题栏（复用既有文案机制，无新增 UI）
            string emptyHint = "";
            if (ips.Count == 0 || conns.Count == 0) emptyHint = BuildLiveEmptyHint(q, snap != null);
            string localNote = (filtMode == 4 && !cfg.ShowLocalIp) ? " · 设置已隐藏内网/本机地址" : "";
            lblIpsTitle.Text = "各 IP 连接摘要（" + ips.Count + " 个 IP"
                + (fname.Length > 0 ? " · 筛选: " + fname : "")
                + (pinnedIp.Length > 0 ? " · IP 筛选: " + pinnedIp : "")
                + (q.Length > 0 ? " · 搜索: " + q : "")
                + "）" + localNote + (ips.Count == 0 ? emptyHint : "") + "   点击列头排序";
            lblConnsTitle.Text = "当前连接明细（" + conns.Count + " 条连接"
                + (fname.Length > 0 ? " · 筛选: " + fname : "")
                + (q.Length > 0 ? " · 搜索: " + q : "")
                + "）" + localNote + (conns.Count == 0 ? emptyHint : "") + "   双击行 = 按该 IP 筛选上表";

            UpdateVolumeLabels(snap);
        }

        void SortLiveIps(List<LiveIp> list)
        {
            string col = sortIps.Col;
            bool desc = sortIps.Desc;
            Comparison<LiveIp> cmp;
            if (col == "ip") cmp = delegate(LiveIp a, LiveIp b) { return CmpStr(a.Ip, b.Ip); };
            else if (col == "loc") cmp = delegate(LiveIp a, LiveIp b) { return CmpStr(Loc(a.Country, a.Region, a.City), Loc(b.Country, b.Region, b.City)); };
            else if (col == "isp") cmp = delegate(LiveIp a, LiveIp b) { return CmpStr(a.Isp, b.Isp); };
            else if (col == "conns") cmp = delegate(LiveIp a, LiveIp b) { return a.ConnCount.CompareTo(b.ConnCount); };
            else if (col == "up") cmp = delegate(LiveIp a, LiveIp b) { return a.SpeedOutBps.CompareTo(b.SpeedOutBps); };
            else if (col == "flag") cmp = delegate(LiveIp a, LiveIp b) { return (a.IsNew ? 1 : 0).CompareTo(b.IsNew ? 1 : 0); };
            else cmp = delegate(LiveIp a, LiveIp b) { return a.SpeedInBps.CompareTo(b.SpeedInBps); };
            list.Sort(delegate(LiveIp a, LiveIp b) { int r = cmp(a, b); return desc ? -r : r; });
        }

        void SortLiveConns(List<LiveConn> list)
        {
            string col = sortConns.Col;
            bool desc = sortConns.Desc;
            Comparison<LiveConn> cmp;
            if (col == "ip") cmp = delegate(LiveConn a, LiveConn b) { return CmpStr(a.Ip, b.Ip); };
            else if (col == "loc") cmp = delegate(LiveConn a, LiveConn b) { return CmpStr(Loc(a.Country, a.Region, a.City), Loc(b.Country, b.Region, b.City)); };
            else if (col == "proc") cmp = delegate(LiveConn a, LiveConn b) { return CmpStr(a.ProcessName, b.ProcessName); };
            else if (col == "pid") cmp = delegate(LiveConn a, LiveConn b) { return a.Pid.CompareTo(b.Pid); };
            else if (col == "rport") cmp = delegate(LiveConn a, LiveConn b) { return a.RemotePort.CompareTo(b.RemotePort); };
            else if (col == "proto") cmp = delegate(LiveConn a, LiveConn b) { return CmpStr(a.Proto, b.Proto); };
            else if (col == "up") cmp = delegate(LiveConn a, LiveConn b) { return a.BytesOut.CompareTo(b.BytesOut); };
            else if (col == "down") cmp = delegate(LiveConn a, LiveConn b) { return a.BytesIn.CompareTo(b.BytesIn); };
            else if (col == "dur") cmp = delegate(LiveConn a, LiveConn b) { return a.DurationSeconds.CompareTo(b.DurationSeconds); };
            else if (col == "flag") cmp = delegate(LiveConn a, LiveConn b) { return (a.IsNew ? 1 : 0).CompareTo(b.IsNew ? 1 : 0); };
            else cmp = delegate(LiveConn a, LiveConn b) { return (a.BytesIn + a.BytesOut).CompareTo(b.BytesIn + b.BytesOut); };
            list.Sort(delegate(LiveConn a, LiveConn b) { int r = cmp(a, b); return desc ? -r : r; });
        }

        // =============================================================
        // 进程视图
        // =============================================================
        void RebindProc()
        {
            if (treeProcs == null) return;
            string date = selectedDate;
            DayData dd = SafeGetDay(date);
            List<ProcAgg> procs = SafeGetDayProcs(date, dd);
            string q = Query;

            Dictionary<string, List<ProcAgg>> byName = new Dictionary<string, List<ProcAgg>>(StringComparer.OrdinalIgnoreCase);
            foreach (ProcAgg p in procs)
            {
                if (p == null) continue;
                if (!ProcMatches(p, q)) continue;
                string nm = string.IsNullOrEmpty(p.name) ? "(未知进程)" : p.name;
                List<ProcAgg> list;
                if (!byName.TryGetValue(nm, out list))
                {
                    list = new List<ProcAgg>();
                    byName[nm] = list;
                }
                list.Add(p);
            }

            List<string> names = new List<string>(byName.Keys);
            names.Sort(delegate(string a, string b)
            {
                return SumTraffic(byName[b]).CompareTo(SumTraffic(byName[a]));
            });

            HashSet<string> expanded = new HashSet<string>();
            CollectExpanded(treeProcs.Nodes, expanded);

            HashSet<string> ipSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            long connTotal = 0;

            treeProcs.BeginUpdate();
            try
            {
                treeProcs.Nodes.Clear();
                foreach (string nm in names)
                {
                    List<ProcAgg> plist = byName[nm];
                    long nIn = 0, nOut = 0;
                    int nConn = 0;
                    foreach (ProcAgg p in plist)
                    {
                        nIn += p.bytesIn;
                        nOut += p.bytesOut;
                        nConn += p.connCount;
                        connTotal += p.connCount;
                        if (p.ips != null)
                        {
                            foreach (string ipKey in p.ips.Keys) ipSet.Add(ipKey);
                        }
                    }

                    TreeNode nodeName = treeProcs.Nodes.Add(nm + "   (" + plist.Count + " 个 PID)   ↓" + FmtBytes(nIn) + "   ↑" + FmtBytes(nOut) + "   · " + nConn + " 次");
                    nodeName.ForeColor = Color.FromArgb(24, 58, 110);

                    plist.Sort(delegate(ProcAgg a, ProcAgg b)
                    {
                        return (b.bytesIn + b.bytesOut).CompareTo(a.bytesIn + a.bytesOut);
                    });

                    foreach (ProcAgg p in plist)
                    {
                        TreeNode nodePid = nodeName.Nodes.Add("PID " + p.pid + "   ↓" + FmtBytes(p.bytesIn) + "   ↑" + FmtBytes(p.bytesOut) + "   · " + p.connCount + " 次");

                        List<IpConnAgg> iplist = new List<IpConnAgg>();
                        if (p.ips != null)
                        {
                            foreach (IpConnAgg ia in p.ips.Values)
                            {
                                if (ia == null) continue;
                                iplist.Add(ia);
                            }
                        }
                        bool nameMatched = string.IsNullOrEmpty(q) || Match(q, p.name, p.path, p.pid.ToString());
                        if (!nameMatched)
                        {
                            iplist.RemoveAll(delegate(IpConnAgg ia)
                            {
                                return !Match(q, ia.ip, ia.city, ia.region, ia.country, ia.isp, ia.hostname, ia.proto);
                            });
                        }
                        iplist.Sort(delegate(IpConnAgg a, IpConnAgg b)
                        {
                            return (b.bytesIn + b.bytesOut).CompareTo(a.bytesIn + a.bytesOut);
                        });
                        foreach (IpConnAgg ia in iplist)
                        {
                            string ports = JoinInts(ia.ports);
                            string proto = string.IsNullOrEmpty(ia.proto) ? "TCP" : ia.proto;
                            string loc = Loc(ia.country, ia.region, ia.city);
                            string text = ia.ip + ":" + (ports.Length == 0 ? "?" : ports) + "   [" + proto + "]   " + loc
                                + "   ↓" + FmtBytes(ia.bytesIn) + "   ↑" + FmtBytes(ia.bytesOut) + "   · " + ia.connCount + " 次";
                            TreeNode nodeIp = nodePid.Nodes.Add(text);
                            nodeIp.Tag = ia.ip;
                            nodeIp.ForeColor = Color.FromArgb(40, 40, 40);
                        }
                    }
                }
            }
            finally
            {
                treeProcs.EndUpdate();
            }

            // 展开状态需在 TreeView 句柄可用时应用（隐藏页时 Expand 会被忽略）
            procTreeExpandAllPending = !procTreeBuilt || expanded.Count == 0;
            procTreeExpandedPending = expanded;
            procTreeBuilt = true;
            ApplyTreeExpansion();

            DayData sum = dd ?? new DayData { date = date };
            long total = sum.bytesIn + sum.bytesOut;
            string mode = sum.bytesPrecise ? "逐IP精确" : "逐IP估算";
            int ipCount = ipSet.Count;
            if (ipCount == 0 && sum.ips != null) ipCount = sum.ips.Count;
            lblProcSummary.Text = date + "   进程 " + names.Count + " 个 · 远端 IP " + ipCount + " 个 · 连接 " + connTotal
                + " 次 · 总流量 " + FmtBytes(total) + "（↓" + FmtBytes(sum.bytesIn) + " / ↑" + FmtBytes(sum.bytesOut) + "）"
                + " · 峰值 ↓" + FmtRate(sum.peakInBps) + " ↑" + FmtRate(sum.peakOutBps) + " · 字节来源：" + mode
                + (q.Length > 0 ? "\n当前搜索：" + q + "（仅显示匹配进程）" : "\n按总流量排序；展开 PID 查看远端 IP:端口（协议）；双击 IP 行可在实时连接页筛选该 IP。");
        }

        bool ProcMatches(ProcAgg p, string q)
        {
            if (string.IsNullOrEmpty(q)) return true;
            if (Match(q, p.name, p.path, p.pid.ToString())) return true;
            if (p.ips != null)
            {
                foreach (KeyValuePair<string, IpConnAgg> kv in p.ips)
                {
                    IpConnAgg ia = kv.Value;
                    if (ia == null) { if (Contains(q, kv.Key)) return true; continue; }
                    if (Match(q, ia.ip, ia.city, ia.region, ia.country, ia.isp, ia.hostname, ia.proto)) return true;
                }
            }
            return false;
        }

        static long SumTraffic(List<ProcAgg> list)
        {
            long t = 0;
            foreach (ProcAgg p in list) t += p.bytesIn + p.bytesOut;
            return t;
        }

        static void CollectExpanded(TreeNodeCollection nodes, HashSet<string> set)
        {
            foreach (TreeNode n in nodes)
            {
                if (n.IsExpanded) set.Add(n.FullPath);
                CollectExpanded(n.Nodes, set);
            }
        }

        void ApplyTreeExpansion()
        {
            if (treeProcs == null || !treeProcs.IsHandleCreated) return;
            treeProcs.BeginUpdate();
            try
            {
                if (procTreeExpandAllPending)
                {
                    treeProcs.ExpandAll();
                    procTreeExpandAllPending = false;
                }
                else
                {
                    ExpandSavedNodes(treeProcs.Nodes);
                }
            }
            catch { }
            finally
            {
                treeProcs.EndUpdate();
            }
        }

        void ExpandSavedNodes(TreeNodeCollection nodes)
        {
            foreach (TreeNode n in nodes)
            {
                if (procTreeExpandedPending.Contains(n.FullPath))
                {
                    try { n.Expand(); }
                    catch { }
                }
                ExpandSavedNodes(n.Nodes);
            }
        }

        // =============================================================
        // 按日统计
        // =============================================================
        void RebindDate()
        {
            if (dgvDate == null) return;
            string date = selectedDate;
            DayData dd = SafeGetDay(date);
            List<IpAggregate> ips = SafeGetDayIps(date, dd);
            List<ProcAgg> procs = SafeGetDayProcs(date, dd);
            Dictionary<string, int> ipConn = BuildIpConnCounts(procs);
            string q = Query;

            List<DateRow> rows = new List<DateRow>();
            foreach (IpAggregate a in ips)
            {
                if (a == null) continue;
                if (!MatchIpAggregate(q, a)) continue;
                DateRow r = new DateRow();
                r.A = a;
                int cc;
                r.ConnCount = ipConn.TryGetValue(a.ip, out cc) ? cc : 0;
                rows.Add(r);
            }
            SortDateRows(rows);

            int scroll = GetScroll(dgvDate);
            dgvDate.SuspendLayout();
            try
            {
                dgvDate.Rows.Clear();
                foreach (DateRow r in rows)
                {
                    IpAggregate a = r.A;
                    long avg = a.connectedSeconds > 0 ? (a.bytesIn + a.bytesOut) / a.connectedSeconds : 0;
                    long peak = a.peakInBps + a.peakOutBps;
                    int idx = dgvDate.Rows.Add(new object[]
                    {
                        a.ip,
                        string.IsNullOrEmpty(a.city) ? "-" : a.city,
                        string.IsNullOrEmpty(a.region) ? "-" : a.region,
                        string.IsNullOrEmpty(a.isp) ? "-" : a.isp,
                        FmtDuration(a.connectedSeconds),
                        a.sessionCount,
                        r.ConnCount,
                        FmtTime(a.firstSeenUnix),
                        FmtTime(a.lastSeenUnix),
                        FmtBytes(a.bytesIn),
                        FmtBytes(a.bytesOut),
                        FmtRate(avg),
                        FmtRate(peak)
                    });
                    if (a.isNew)
                    {
                        StyleRow(dgvDate, idx, true);
                    }
                    dgvDate.Rows[idx].Cells["ip"].ToolTipText = BuildDateIpTip(a, r.ConnCount);
                }
            }
            finally
            {
                dgvDate.ResumeLayout();
            }

            RestoreScroll(dgvDate, scroll);
            ApplySortGlyph(dgvDate, sortDate);

            DayData d = dd ?? new DayData { date = date };
            long activeSec = d.lastSampleUnix > d.firstSampleUnix ? d.lastSampleUnix - d.firstSampleUnix : 0;
            long avgIn = activeSec > 0 ? d.bytesIn / activeSec : 0;
            long avgOut = activeSec > 0 ? d.bytesOut / activeSec : 0;
            int ipCount = ips.Count;
            if (ipCount == 0 && d.ips != null) ipCount = d.ips.Count;
            int procCount = procs.Count;
            if (procCount == 0 && d.procs != null) procCount = d.procs.Count;
            long sessionTotal = 0, connTotal = 0;
            foreach (DateRow r in rows)
            {
                sessionTotal += r.A.sessionCount;
                connTotal += r.ConnCount;
            }
            string mode = d.bytesPrecise ? "逐IP精确" : "逐IP估算";
            if (d.sampleCount == 0 && ipCount == 0 && procCount == 0)
            {
                lblDateSummary.Text = DateLabel(date) + "   该日期没有采集数据"
                    + (q.Length > 0 ? "（当前搜索：" + q + "）" : "")
                    + "。程序需在该日运行并落盘后才有数据；也可用右上角日历选择其它日期。";
                return;
            }
            lblDateSummary.Text = DateLabel(date) + "   下载 " + FmtBytes(d.bytesIn) + "   上传 " + FmtBytes(d.bytesOut)
                + "   平均速率 ↓" + FmtRate(avgIn) + " ↑" + FmtRate(avgOut)
                + "   峰值 ↓" + FmtRate(d.peakInBps) + " ↑" + FmtRate(d.peakOutBps)
                + "   采样 " + d.sampleCount + " 次   字节来源：" + mode
                + "\nIP " + ipCount + " 个 · 进程 " + procCount + " 个 · 会话合计 " + sessionTotal + " 次 · 连接合计 " + connTotal + " 次"
                + (q.Length > 0 ? " · 搜索：" + q : "") + " · 当前显示 " + rows.Count + " 行（点击列头排序）";
        }

        void SortDateRows(List<DateRow> list)
        {
            string col = sortDate.Col;
            bool desc = sortDate.Desc;
            Comparison<DateRow> cmp;
            if (col == "ip") cmp = delegate(DateRow a, DateRow b) { return CmpStr(a.A.ip, b.A.ip); };
            else if (col == "city") cmp = delegate(DateRow a, DateRow b) { return CmpStr(a.A.city, b.A.city); };
            else if (col == "region") cmp = delegate(DateRow a, DateRow b) { return CmpStr(a.A.region, b.A.region); };
            else if (col == "isp") cmp = delegate(DateRow a, DateRow b) { return CmpStr(a.A.isp, b.A.isp); };
            else if (col == "dur") cmp = delegate(DateRow a, DateRow b) { return a.A.connectedSeconds.CompareTo(b.A.connectedSeconds); };
            else if (col == "sess") cmp = delegate(DateRow a, DateRow b) { return a.A.sessionCount.CompareTo(b.A.sessionCount); };
            else if (col == "conns") cmp = delegate(DateRow a, DateRow b) { return a.ConnCount.CompareTo(b.ConnCount); };
            else if (col == "first") cmp = delegate(DateRow a, DateRow b) { return a.A.firstSeenUnix.CompareTo(b.A.firstSeenUnix); };
            else if (col == "last") cmp = delegate(DateRow a, DateRow b) { return a.A.lastSeenUnix.CompareTo(b.A.lastSeenUnix); };
            else if (col == "up") cmp = delegate(DateRow a, DateRow b) { return a.A.bytesOut.CompareTo(b.A.bytesOut); };
            else if (col == "avg") cmp = delegate(DateRow a, DateRow b) { return AvgSpeed(a.A).CompareTo(AvgSpeed(b.A)); };
            else if (col == "peak") cmp = delegate(DateRow a, DateRow b) { return (a.A.peakInBps + a.A.peakOutBps).CompareTo(b.A.peakInBps + b.A.peakOutBps); };
            else cmp = delegate(DateRow a, DateRow b) { return a.A.bytesIn.CompareTo(b.A.bytesIn); };
            list.Sort(delegate(DateRow a, DateRow b) { int r = cmp(a, b); return desc ? -r : r; });
        }

        static long AvgSpeed(IpAggregate a)
        {
            return a.connectedSeconds > 0 ? (a.bytesIn + a.bytesOut) / a.connectedSeconds : 0;
        }

        Dictionary<string, int> BuildIpConnCounts(List<ProcAgg> procs)
        {
            Dictionary<string, int> m = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            if (procs == null) return m;
            foreach (ProcAgg p in procs)
            {
                if (p == null || p.ips == null) continue;
                foreach (KeyValuePair<string, IpConnAgg> kv in p.ips)
                {
                    if (kv.Value == null) continue;
                    int old;
                    if (m.TryGetValue(kv.Key, out old)) m[kv.Key] = old + kv.Value.connCount;
                    else m[kv.Key] = kv.Value.connCount;
                }
            }
            return m;
        }

        string BuildDateIpTip(IpAggregate a, int connCount)
        {
            StringBuilder sb = new StringBuilder();
            if (!string.IsNullOrEmpty(a.hostname)) sb.Append("域名: ").Append(a.hostname).Append('\n');
            if (a.processes != null && a.processes.Count > 0)
            {
                sb.Append("进程: ");
                bool first = true;
                foreach (string nm in a.processes.Keys)
                {
                    if (!first) sb.Append(", ");
                    sb.Append(nm);
                    first = false;
                }
                sb.Append('\n');
            }
            if (!string.IsNullOrEmpty(a.country)) sb.Append("归属: ").Append(Loc(a.country, a.region, a.city)).Append('\n');
            sb.Append("会话 ").Append(a.sessionCount).Append(" 次 · 连接 ").Append(connCount)
                .Append(" 次 · 采样 ").Append(a.sampleCount).Append(" 次\n");
            sb.Append("峰值 ↓").Append(FmtRate(a.peakInBps)).Append(" ↑").Append(FmtRate(a.peakOutBps));
            sb.Append('\n').Append(a.bytesPrecise ? "字节来源: 逐连接 EStats（精确）" : "字节来源: 总流量估算");
            if (a.isNew) sb.Append("\n今日首次出现（NEW）");
            return sb.ToString();
        }

        // =============================================================
        // 历史概览
        // =============================================================
        void RebindHist()
        {
            if (dgvHist == null) return;
            List<DayData> days = SafeGetHistory();
            string q = Query;

            List<DayData> list = new List<DayData>();
            foreach (DayData d in days)
            {
                if (d == null) continue;
                if (!Match(q, d.date)) continue;
                list.Add(d);
            }
            SortHist(list);

            int scroll = GetScroll(dgvHist);
            dgvHist.SuspendLayout();
            try
            {
                dgvHist.Rows.Clear();
                long totalIn = 0, totalOut = 0;
                foreach (DayData d in list)
                {
                    int ipCount = CountIps(d);
                    int procCount = CountProcs(d);
                    int idx = dgvHist.Rows.Add(new object[]
                    {
                        string.IsNullOrEmpty(d.date) ? "-" : d.date,
                        FmtBytes(d.bytesIn),
                        FmtBytes(d.bytesOut),
                        "↓" + FmtRate(d.peakInBps) + "  ↑" + FmtRate(d.peakOutBps),
                        procCount,
                        ipCount,
                        d.sampleCount
                    });
                    dgvHist.Rows[idx].Cells["date"].ToolTipText = (d.bytesPrecise ? "逐IP精确（管理员）" : "逐IP估算");
                    totalIn += d.bytesIn;
                    totalOut += d.bytesOut;
                }
                lblHistSummary.Text = "共 " + list.Count + " 天数据（倒序）   ·   总下载 " + FmtBytes(totalIn)
                    + "   ·   总上传 " + FmtBytes(totalOut)
                    + "   ·   双击某行可跳转到该日" + (q.Length > 0 ? "   ·   搜索：" + q : "");
            }
            finally
            {
                dgvHist.ResumeLayout();
            }

            RestoreScroll(dgvHist, scroll);
            ApplySortGlyph(dgvHist, sortHist);
        }

        void SortHist(List<DayData> list)
        {
            string col = sortHist.Col;
            bool desc = sortHist.Desc;
            Comparison<DayData> cmp;
            if (col == "down") cmp = delegate(DayData a, DayData b) { return a.bytesIn.CompareTo(b.bytesIn); };
            else if (col == "up") cmp = delegate(DayData a, DayData b) { return a.bytesOut.CompareTo(b.bytesOut); };
            else if (col == "peak") cmp = delegate(DayData a, DayData b) { return (a.peakInBps + a.peakOutBps).CompareTo(b.peakInBps + b.peakOutBps); };
            else if (col == "procs") cmp = delegate(DayData a, DayData b) { return CountProcs(a).CompareTo(CountProcs(b)); };
            else if (col == "ips") cmp = delegate(DayData a, DayData b) { return CountIps(a).CompareTo(CountIps(b)); };
            else if (col == "samples") cmp = delegate(DayData a, DayData b) { return a.sampleCount.CompareTo(b.sampleCount); };
            else cmp = delegate(DayData a, DayData b) { return CmpStr(a.date, b.date); };
            list.Sort(delegate(DayData a, DayData b) { int r = cmp(a, b); return desc ? -r : r; });
        }

        static int CountIps(DayData d)
        {
            if (d == null) return 0;
            if (d.ips != null && d.ips.Count > 0) return d.ips.Count;
            return d.ipCount;
        }

        static int CountProcs(DayData d)
        {
            if (d == null) return 0;
            if (d.procs != null && d.procs.Count > 0) return d.procs.Count;
            return d.procCount;
        }

        // =============================================================
        // 数据读取（对引擎调用做保护，避免单次异常打断 UI）
        // =============================================================
        DayData SafeGetDay(string date)
        {
            try
            {
                DayData d = monitor.GetDay(date);
                return d ?? new DayData { date = date };
            }
            catch
            {
                return new DayData { date = date };
            }
        }

        List<IpAggregate> SafeGetDayIps(string date, DayData dd)
        {
            List<IpAggregate> list = null;
            try { list = monitor.GetDayIps(date); }
            catch { }
            if (list != null && list.Count > 0) return list;
            if (dd != null && dd.ips != null && dd.ips.Count > 0) return new List<IpAggregate>(dd.ips.Values);
            return new List<IpAggregate>();
        }

        List<ProcAgg> SafeGetDayProcs(string date, DayData dd)
        {
            List<ProcAgg> list = null;
            try { list = monitor.GetDayProcs(date); }
            catch { }
            if (list != null && list.Count > 0) return list;
            if (dd != null && dd.procs != null && dd.procs.Count > 0) return new List<ProcAgg>(dd.procs.Values);
            return new List<ProcAgg>();
        }

        List<DayData> SafeGetHistory()
        {
            try
            {
                List<DayData> h = monitor.GetHistory();
                return h ?? new List<DayData>();
            }
            catch
            {
                return new List<DayData>();
            }
        }

        // =============================================================
        // 日期 / 搜索
        // =============================================================
        void SetDate(DateTime d)
        {
            if (inSetDate) return;
            // 2.2.0 收口：防御未来日期（日历已禁未来，但历史跳转/跨日时钟回拨也要挡住）
            if (d.Date > DateTime.Now.Date) d = DateTime.Now.Date;
            inSetDate = true;
            try
            {
                selectedDate = d.ToString(DateFmt);
                try { datePicker.Value = d.Date; }
                catch { }
            }
            finally
            {
                inSetDate = false;
            }
            UpdateDateBar();
            if (tabs != null)
            {
                if (tabs.SelectedTab == tpLive) RebindLive(curSnap);
                else RebindActiveTab(true);
            }
        }

        // 2.2.0 收口：历史概览双击跳转——先切到「按日统计」再选日期。
        // 切页期间用 inSetDate 抑制 SelectedIndexChanged 里按旧日期做一次多余重绑。
        void JumpToDate(DateTime d)
        {
            if (tabs != null && tabs.SelectedTab != tpDate)
            {
                bool old = inSetDate;
                inSetDate = true;
                try { tabs.SelectedTab = tpDate; }
                finally { inSetDate = old; }
            }
            SetDate(d);
        }

        string Query
        {
            get
            {
                if (txtSearch == null) return "";
                return (txtSearch.Text ?? "").Trim();
            }
        }

        static bool Contains(string q, string s)
        {
            if (string.IsNullOrEmpty(q)) return true;
            if (string.IsNullOrEmpty(s)) return false;
            return s.IndexOf(q, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        static bool Match(string q, params string[] fields)
        {
            if (string.IsNullOrEmpty(q)) return true;
            for (int i = 0; i < fields.Length; i++)
            {
                if (Contains(q, fields[i])) return true;
            }
            return false;
        }

        static bool MatchLiveIp(string q, LiveIp li)
        {
            if (string.IsNullOrEmpty(q)) return true;
            if (Match(q, li.Ip, li.City, li.Region, li.Country, li.Isp, li.Hostname, li.Processes)) return true;
            return false;
        }

        static bool MatchLiveConn(string q, LiveConn c)
        {
            if (string.IsNullOrEmpty(q)) return true;
            if (Match(q, c.Ip, c.ProcessName, c.ProcessPath, c.State, c.Proto, c.City, c.Region, c.Country, c.Isp, c.Hostname)) return true;
            if (Match(q, c.Pid.ToString(), c.RemotePort.ToString(), c.LocalPort.ToString())) return true;
            return false;
        }

        static bool MatchIpAggregate(string q, IpAggregate a)
        {
            if (string.IsNullOrEmpty(q)) return true;
            if (Match(q, a.ip, a.city, a.region, a.country, a.isp, a.hostname)) return true;
            if (a.processes != null)
            {
                foreach (string nm in a.processes.Keys)
                {
                    if (Contains(q, nm)) return true;
                }
            }
            return false;
        }

        // =============================================================
        // 动作：设置 / 导出 / 数据目录 / 管理员重启 / 托盘
        // =============================================================
        void OpenSettings()
        {
            // 2.1 修复（P1-5）：打开设置前用注册表实际状态对账，避免 install / msconfig 改动后误显示、误删自启项
            try { cfg.AutoStart = Startup.IsEnabled(); } catch { }
            using (SettingsForm f = new SettingsForm(cfg))
            {
                if (f.ShowDialog(this) != DialogResult.OK)
                {
                    // 2.2.0 收口：设置窗口关闭后回到主窗口，强制重排一次日期行，避免弹窗期间布局未刷新
                    UpdateDateBar();
                    return;
                }
                try { cfg.Save(); }
                catch { }
                try { Startup.SetEnabled(cfg.AutoStart); cfg.AutoStart = Startup.IsEnabled(); }
                catch { }
                // 2.1 修复（P1-8）：归属地开关立即生效，不需要重启程序
                try { GeoIp.SetEnabled(cfg.GeoEnabled); } catch { }
                UpdateIntervalLabel();
                UpdateAdminButton();
                UpdateDateBar();   // 显示内网开关可能变化 → 「仅公网」提示/空态文案要跟着变
                ForceRefresh();
            }
        }

        void ExportCsv()
        {
            string date = selectedDate;
            DayData dd = SafeGetDay(date);
            List<IpAggregate> ips = SafeGetDayIps(date, dd);
            List<ProcAgg> procs = SafeGetDayProcs(date, dd);
            Dictionary<string, int> ipConn = BuildIpConnCounts(procs);

            using (SaveFileDialog dlg = new SaveFileDialog())
            {
                dlg.Title = "导出当日 IP 明细（UTF-8 BOM，Excel 可直接打开）";
                dlg.FileName = "NetWatcher_IP明细_" + date + ".csv";
                dlg.Filter = "CSV 文件 (*.csv)|*.csv|所有文件 (*.*)|*.*";
                dlg.AddExtension = true;
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                try
                {
                    List<IpAggregate> sorted = new List<IpAggregate>(ips);
                    sorted.Sort(delegate(IpAggregate a, IpAggregate b)
                    {
                        return (b.bytesIn + b.bytesOut).CompareTo(a.bytesIn + a.bytesOut);
                    });

                    StringBuilder sb = new StringBuilder();
                    sb.AppendLine("日期,IP地址,城市,地区,运营商,连接时长,连接时长(秒),会话数,连接次数,首次连接,最近连接,下载(字节),上传(字节),平均速率(B/s),峰值速率(B/s),是否今日新IP");
                    foreach (IpAggregate a in sorted)
                    {
                        int cc;
                        if (!ipConn.TryGetValue(a.ip, out cc)) cc = 0;
                        long avg = a.connectedSeconds > 0 ? (a.bytesIn + a.bytesOut) / a.connectedSeconds : 0;
                        sb.Append(Csv(date)).Append(',');
                        sb.Append(Csv(a.ip)).Append(',');
                        sb.Append(Csv(a.city)).Append(',');
                        sb.Append(Csv(a.region)).Append(',');
                        sb.Append(Csv(a.isp)).Append(',');
                        sb.Append(Csv(FmtDuration(a.connectedSeconds))).Append(',');
                        sb.Append(a.connectedSeconds).Append(',');
                        sb.Append(a.sessionCount).Append(',');
                        sb.Append(cc).Append(',');
                        sb.Append(Csv(FmtTime(a.firstSeenUnix))).Append(',');
                        sb.Append(Csv(FmtTime(a.lastSeenUnix))).Append(',');
                        sb.Append(a.bytesIn).Append(',');
                        sb.Append(a.bytesOut).Append(',');
                        sb.Append(avg).Append(',');
                        sb.Append(a.peakInBps + a.peakOutBps).Append(',');
                        sb.Append(a.isNew ? "是" : "否");
                        sb.AppendLine();
                    }
                    File.WriteAllText(dlg.FileName, sb.ToString(), new UTF8Encoding(true));
                    MessageBox.Show(this, "已导出 " + sorted.Count + " 条记录到:\n" + dlg.FileName, "IP监控2.1",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "导出失败: " + ex.Message, "IP监控2.1", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        void OpenDataDir()
        {
            try
            {
                string dir = cfg.EffectiveDataDir();
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                Process.Start(dir);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "打开数据目录失败: " + ex.Message, "IP监控2.1", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        void RestartAsAdmin()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = Application.ExecutablePath;
                // 2.1 修复（P1-7）：管理员重启必须保留数据目录，否则会切回默认目录，当天数据看起来"清空"了
                StringBuilder adminArgs = new StringBuilder();
                if (background) adminArgs.Append("--background ");
                if (!string.IsNullOrEmpty(dataDir)) adminArgs.Append("--datadir \"" + dataDir + "\"");
                psi.Arguments = adminArgs.ToString().Trim();
                psi.Verb = "runas";
                psi.UseShellExecute = true;
                Process.Start(psi);
                ExitApp();
            }
            catch
            {
                // 用户取消 UAC
            }
        }

        void BuildTray()
        {
            if (tray != null) return;   // 2.1.1：保证同一时刻只有一个 NotifyIcon
            tray = new NotifyIcon();
            tray.Icon = LoadAppIcon();
            tray.Text = "IP监控2.1（NetWatcher）";
            tray.Visible = true;

            trayMenu = new ContextMenuStrip();
            trayMenu.Items.Add("显示主窗口", null, delegate { ShowMain(); });
            trayMenu.Items.Add("刷新", null, delegate { ForceRefresh(); });
            trayMenu.Items.Add(new ToolStripSeparator());
            trayMenu.Items.Add("退出", null, delegate { ExitApp(); });
            tray.ContextMenuStrip = trayMenu;
            tray.DoubleClick += delegate { ShowMain(); };
        }

        void CheckNewIpBalloon(Snapshot snap)
        {
            if (!cfg.NewIpAlert || tray == null || snap == null || snap.LiveIps == null) return;
            List<string> found = new List<string>();
            foreach (LiveIp li in snap.LiveIps)
            {
                if (li == null || !li.IsNew || li.IsLocal) continue;
                if (alertedIps.Contains(li.Ip)) continue;
                alertedIps.Add(li.Ip);
                found.Add(li.Ip + (string.IsNullOrEmpty(li.City) ? "" : "（" + Loc(li.Country, li.Region, li.City) + "）"));
            }
            if (found.Count == 0) return;
            int show = found.Count > 3 ? 3 : found.Count;
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < show; i++)
            {
                if (i > 0) sb.Append('\n');
                sb.Append(found[i]);
            }
            if (found.Count > show) sb.Append("\n… 共 " + found.Count + " 个新 IP");
            try { tray.ShowBalloonTip(4000, "发现新公网 IP", sb.ToString(), ToolTipIcon.Info); }
            catch { }
        }

        void ShowMain()
        {
            ShowInTaskbar = true;
            Show();
            WindowState = FormWindowState.Normal;
            Activate();
            BringToFront();
            // 2.2.0 收口：从托盘隐藏→显示后重排日期行，避免 FlowLayoutPanel 停留在隐藏前的布局
            try { UpdateDateBar(); } catch { }
        }

        void ExitApp()
        {
            reallyExiting = true;
            // 2.1.1：先停掉托盘补偿定时器，避免退出过程中 Tick 再次 BuildTray()，在系统通知区域留下"幽灵图标"。
            try
            {
                if (trayRetryTimer != null) { trayRetryTimer.Stop(); trayRetryTimer.Dispose(); trayRetryTimer = null; }
            }
            catch { }
            try { if (timer != null) { timer.Stop(); timer.Dispose(); timer = null; } }
            catch { }
            try { monitor.Stop(); }
            catch { }
            try
            {
                if (tray != null)
                {
                    tray.Visible = false;
                    tray.Dispose();
                    tray = null;
                }
                if (trayMenu != null) { trayMenu.Dispose(); trayMenu = null; }
            }
            catch { }
            try { if (toolTip != null) { toolTip.Dispose(); toolTip = null; } }
            catch { }
            Close();
        }

        // 2.2.0 收口：趋势页缓存的 Font/Pen/Brush 在窗体释放时一起释放
        protected override void Dispose(bool disposing)
        {
            if (disposing) DisposeTrendResources();
            base.Dispose(disposing);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!reallyExiting && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();
                if (tray != null && !trayHintShown)
                {
                    trayHintShown = true;
                    try { tray.ShowBalloonTip(2500, "IP监控2.1", "已最小化到系统托盘，监控继续运行；双击托盘图标可恢复窗口。", ToolTipIcon.Info); }
                    catch { }
                }
                return;
            }
            base.OnFormClosing(e);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (WindowState == FormWindowState.Minimized) Hide();
        }

        // =============================================================
        // 格式化工具
        // =============================================================
        static string FmtBytes(long b)
        {
            if (b < 0) b = 0;
            if (b < 1024) return b + " B";
            double kb = b / 1024.0;
            if (kb < 1024) return kb.ToString("0.0") + " KB";
            double mb = kb / 1024.0;
            if (mb < 1024) return mb.ToString("0.00") + " MB";
            double gb = mb / 1024.0;
            if (gb < 1024) return gb.ToString("0.00") + " GB";
            return (gb / 1024.0).ToString("0.00") + " TB";
        }

        static string FmtRate(long bps)
        {
            return FmtBytes(bps) + "/s";
        }

        static string FmtDuration(long sec)
        {
            if (sec <= 0) return "-";
            long h = sec / 3600;
            long m = (sec % 3600) / 60;
            long s = sec % 60;
            if (h > 0) return h + "小时" + m + "分";
            if (m > 0) return m + "分" + s + "秒";
            return s + "秒";
        }

        static string FmtTime(long unix)
        {
            if (unix <= 0) return "-";
            try { return DateTimeOffset.FromUnixTimeSeconds(unix).ToLocalTime().ToString("MM-dd HH:mm:ss"); }
            catch { return "-"; }
        }

        static string Loc(string country, string region, string city)
        {
            StringBuilder sb = new StringBuilder();
            AppendPart(sb, country);
            AppendPart(sb, region);
            AppendPart(sb, city);
            return sb.Length == 0 ? "未知" : sb.ToString();
        }

        static void AppendPart(StringBuilder sb, string part)
        {
            if (string.IsNullOrEmpty(part)) return;
            if (sb.Length > 0) sb.Append(' ');
            sb.Append(part);
        }

        static string JoinInts(List<int> list)
        {
            if (list == null || list.Count == 0) return "";
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < list.Count; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append(list[i]);
            }
            return sb.ToString();
        }

        static int CmpStr(string a, string b)
        {
            return string.Compare(a ?? "", b ?? "", StringComparison.OrdinalIgnoreCase);
        }

        static string Csv(string s)
        {
            if (s == null) return "";
            if (s.IndexOfAny(new char[] { ',', '"', '\n', '\r' }) >= 0)
            {
                return "\"" + s.Replace("\"", "\"\"") + "\"";
            }
            return s;
        }

        static string Truncate(string s, int max)
        {
            if (string.IsNullOrEmpty(s)) return "";
            s = s.Replace("\r", " ").Replace("\n", " ");
            if (s.Length <= max) return s;
            return s.Substring(0, max) + "…";
        }

        static Icon LoadAppIcon()
        {
            try
            {
                Icon i = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (i != null) return i;
            }
            catch { }
            return SystemIcons.Application;
        }
    }
}
