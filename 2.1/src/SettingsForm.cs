using System;
using System.Drawing;
using System.Windows.Forms;

namespace NetWatcher
{
    /// <summary>
    /// IP监控2.1 设置窗口：扫描间隔（1/2/5/10/30/60 秒）、保留天数、开机自启、
    /// 启动最小化、归属地识别、新公网 IP 提醒、是否显示内网/本机地址。
    /// </summary>
    public class SettingsForm : Form
    {
        static readonly int[] Intervals = AppConfig.AllowedIntervals;

        readonly AppConfig cfg;
        ComboBox cboInterval;
        NumericUpDown numRetention;
        CheckBox chkAutoStart, chkStartMinimized, chkGeo, chkNewIpAlert, chkShowLocalIp;

        public SettingsForm(AppConfig cfg)
        {
            this.cfg = cfg;
            BuildUi();
        }

        void BuildUi()
        {
            SuspendLayout();
            Text = "设置 · IP监控2.1";
            ClientSize = new Size(560, 448);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent;
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Microsoft YaHei", 9F);
            BackColor = Color.FromArgb(246, 248, 251);

            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.ColumnCount = 3;
            root.RowCount = 11;
            root.Padding = new Padding(14, 10, 14, 10);
            root.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 170F));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            for (int i = 0; i < 11; i++)
            {
                root.RowStyles.Add(new RowStyle(SizeType.Absolute, 34F));
            }
            Controls.Add(root);

            // 标题
            Label title = new Label();
            title.Text = "监控设置";
            title.Font = new Font("Microsoft YaHei", 12F, FontStyle.Bold);
            title.ForeColor = Color.FromArgb(24, 58, 110);
            title.Dock = DockStyle.Fill;
            title.TextAlign = ContentAlignment.MiddleLeft;
            root.Controls.Add(title, 0, 0);
            root.SetColumnSpan(title, 3);

            // 扫描间隔
            AddRow(root, 1, MakeLabel("扫描间隔:"), MakeIntervalCombo(),
                "值越小越不容易漏掉短连接，但 CPU 占用更高（默认 2 秒）");

            // 数据保留
            numRetention = new NumericUpDown();
            numRetention.Minimum = 0;
            numRetention.Maximum = 3650;
            numRetention.Value = Clamp(cfg.RetentionDays, 0, 3650);
            numRetention.Width = 100;
            numRetention.Margin = new Padding(0, 4, 0, 0);
            AddRow(root, 2, MakeLabel("数据保留天数:"), numRetention,
                "0 = 永久保留，建议 30 ~ 365 天");

            // 开机自启
            chkAutoStart = MakeCheck("开机自动启动（常驻后台监控）", cfg.AutoStart);
            AddCheckRow(root, 3, chkAutoStart);

            // 启动最小化
            chkStartMinimized = MakeCheck("启动时最小化到系统托盘", cfg.StartMinimized);
            AddCheckRow(root, 4, chkStartMinimized);

            // 归属地
            chkGeo = MakeCheck("启用 IP 归属地识别（城市级，本地缓存）", cfg.GeoEnabled);
            AddCheckRow(root, 5, chkGeo);

            // 新 IP 提醒
            chkNewIpAlert = MakeCheck("新公网 IP 首次出现时弹托盘气泡提醒", cfg.NewIpAlert);
            AddCheckRow(root, 6, chkNewIpAlert);

            // 内网地址
            chkShowLocalIp = MakeCheck("显示内网 / 本机地址（关闭则只显示公网 IP）", cfg.ShowLocalIp);
            AddCheckRow(root, 7, chkShowLocalIp);

            // 说明
            Label note = new Label();
            note.Text = "说明：逐 IP 精确字节需要管理员权限（EStats 可用时显示「精确」，否则明确标注「估算」）；\n"
                + "UDP / QUIC 流量只能计入总流量，无法归因到具体 IP；\n"
                + "归属地识别、开机自启等设置保存后生效。";
            note.Dock = DockStyle.Fill;
            note.ForeColor = Color.DimGray;
            note.TextAlign = ContentAlignment.MiddleLeft;
            root.Controls.Add(note, 0, 8);
            root.SetColumnSpan(note, 3);
            root.RowStyles[8] = new RowStyle(SizeType.Absolute, 58F);

            // 按钮
            FlowLayoutPanel buttons = new FlowLayoutPanel();
            buttons.Dock = DockStyle.Fill;
            buttons.FlowDirection = FlowDirection.RightToLeft;
            buttons.WrapContents = false;
            buttons.Padding = new Padding(0, 8, 0, 0);

            Button cancel = new Button();
            cancel.Text = "取消";
            cancel.Size = new Size(92, 30);
            cancel.Margin = new Padding(10, 0, 0, 0);
            cancel.DialogResult = DialogResult.Cancel;
            cancel.Click += delegate { DialogResult = DialogResult.Cancel; Close(); };
            buttons.Controls.Add(cancel);

            Button ok = new Button();
            ok.Text = "保存";
            ok.Size = new Size(92, 30);
            ok.Margin = new Padding(0);
            ok.Click += delegate { SaveAndClose(); };
            buttons.Controls.Add(ok);

            root.Controls.Add(buttons, 0, 10);
            root.SetColumnSpan(buttons, 3);

            AcceptButton = ok;
            CancelButton = cancel;

            ResumeLayout(true);
        }

        ComboBox MakeIntervalCombo()
        {
            cboInterval = new ComboBox();
            cboInterval.DropDownStyle = ComboBoxStyle.DropDownList;
            cboInterval.Width = 150;
            cboInterval.Margin = new Padding(0, 3, 0, 0);
            cboInterval.Items.Add("1 秒（最精细）");
            cboInterval.Items.Add("2 秒（推荐）");
            cboInterval.Items.Add("5 秒");
            cboInterval.Items.Add("10 秒");
            cboInterval.Items.Add("30 秒");
            cboInterval.Items.Add("60 秒（最省资源）");

            int idx = 1;
            for (int i = 0; i < Intervals.Length; i++)
            {
                if (Intervals[i] == cfg.ScanIntervalSeconds) { idx = i; break; }
            }
            cboInterval.SelectedIndex = idx;
            return cboInterval;
        }

        static Label MakeLabel(string text)
        {
            Label l = new Label();
            l.Text = text;
            l.AutoSize = true;
            l.Dock = DockStyle.Fill;
            l.TextAlign = ContentAlignment.MiddleLeft;
            l.Margin = new Padding(0);
            return l;
        }

        static CheckBox MakeCheck(string text, bool value)
        {
            CheckBox c = new CheckBox();
            c.Text = text;
            c.Checked = value;
            c.AutoSize = true;
            c.Dock = DockStyle.Fill;
            c.TextAlign = ContentAlignment.MiddleLeft;
            c.Margin = new Padding(0, 0, 0, 0);
            return c;
        }

        void AddRow(TableLayoutPanel root, int row, Control label, Control control, string note)
        {
            root.Controls.Add(label, 0, row);
            root.Controls.Add(control, 1, row);

            Label n = new Label();
            n.Text = note;
            n.Dock = DockStyle.Fill;
            n.TextAlign = ContentAlignment.MiddleLeft;
            n.ForeColor = Color.Gray;
            n.AutoEllipsis = true;
            n.Margin = new Padding(10, 0, 0, 0);
            root.Controls.Add(n, 2, row);
        }

        void AddCheckRow(TableLayoutPanel root, int row, CheckBox chk)
        {
            root.Controls.Add(chk, 1, row);
            root.SetColumnSpan(chk, 2);
        }

        void SaveAndClose()
        {
            int idx = cboInterval.SelectedIndex;
            if (idx < 0 || idx >= Intervals.Length) idx = 1;
            cfg.ScanIntervalSeconds = Intervals[idx];
            cfg.RetentionDays = (int)numRetention.Value;
            cfg.AutoStart = chkAutoStart.Checked;
            cfg.StartMinimized = chkStartMinimized.Checked;
            cfg.GeoEnabled = chkGeo.Checked;
            cfg.NewIpAlert = chkNewIpAlert.Checked;
            cfg.ShowLocalIp = chkShowLocalIp.Checked;

            DialogResult = DialogResult.OK;
            Close();
        }

        static decimal Clamp(int v, int min, int max)
        {
            if (v < min) v = min;
            if (v > max) v = max;
            return v;
        }
    }
}
