using System;
using System.Drawing;
using System.Windows.Forms;

namespace NetWatcher
{
    public class SettingsForm : Form
    {
        readonly AppConfig cfg;
        NumericUpDown numInterval, numRetention;
        CheckBox chkAutoStart, chkGeo;

        public SettingsForm(AppConfig cfg)
        {
            this.cfg = cfg;
            Text = "设置";
            ClientSize = new Size(420, 260);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Microsoft YaHei UI", 9F);

            Label l1 = new Label(); l1.Text = "扫描间隔（分钟）:"; l1.Location = new Point(20, 24); l1.AutoSize = true;
            Controls.Add(l1);
            numInterval = new NumericUpDown(); numInterval.Location = new Point(180, 21); numInterval.Width = 90;
            numInterval.Minimum = 1; numInterval.Maximum = 60;
            numInterval.Value = Math.Max(1, Math.Min(60, cfg.ScanIntervalSeconds / 60));
            Controls.Add(numInterval);
            Label l1b = new Label(); l1b.Text = "（1 分钟更精细，5 分钟更省资源）"; l1b.Location = new Point(280, 24); l1b.AutoSize = true; l1b.ForeColor = Color.Gray;
            Controls.Add(l1b);

            chkAutoStart = new CheckBox(); chkAutoStart.Text = "开机自动启动（常驻后台监控）";
            chkAutoStart.Location = new Point(20, 66); chkAutoStart.AutoSize = true;
            chkAutoStart.Checked = cfg.AutoStart;
            Controls.Add(chkAutoStart);

            Label l2 = new Label(); l2.Text = "数据保留天数（0 = 永久保留）:"; l2.Location = new Point(20, 106); l2.AutoSize = true;
            Controls.Add(l2);
            numRetention = new NumericUpDown(); numRetention.Location = new Point(240, 103); numRetention.Width = 80;
            numRetention.Minimum = 0; numRetention.Maximum = 3650;
            numRetention.Value = Math.Max(0, Math.Min(3650, cfg.RetentionDays));
            Controls.Add(numRetention);

            chkGeo = new CheckBox(); chkGeo.Text = "启用 IP 归属地识别（城市级，本地缓存）";
            chkGeo.Location = new Point(20, 146); chkGeo.AutoSize = true;
            chkGeo.Checked = cfg.GeoEnabled;
            Controls.Add(chkGeo);

            Button ok = new Button(); ok.Text = "保存"; ok.Size = new Size(80, 28); ok.Location = new Point(210, 210);
            ok.Click += delegate
            {
                cfg.ScanIntervalSeconds = (int)numInterval.Value * 60;
                cfg.RetentionDays = (int)numRetention.Value;
                cfg.AutoStart = chkAutoStart.Checked;
                cfg.GeoEnabled = chkGeo.Checked;
                DialogResult = DialogResult.OK;
                Close();
            };
            Controls.Add(ok);

            Button cancel = new Button(); cancel.Text = "取消"; cancel.Size = new Size(80, 28); cancel.Location = new Point(310, 210);
            cancel.Click += delegate { DialogResult = DialogResult.Cancel; Close(); };
            Controls.Add(cancel);
        }
    }
}
