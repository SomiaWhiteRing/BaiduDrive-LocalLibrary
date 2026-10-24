// SPDX-License-Identifier: MIT
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("百度网盘")]
[assembly: System.Reflection.AssemblyVersion("1.1.1.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.1.1.0")]

internal static class Program
{
    internal static readonly string Root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
    internal static string EnvFile = Path.Combine(Root, ".env");
    internal static readonly string PowerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe");
    internal static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }

    internal static string Backend(string action, out int code)
    {
        var info = new ProcessStartInfo(PowerShell,
            "-NoLogo -NoProfile -NonInteractive -File " + Quote(Path.Combine(Root, @"windows\Library.ps1")) + " -Action " + action + " -EnvFile " + Quote(EnvFile));
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        info.StandardOutputEncoding = Encoding.UTF8;
        info.StandardErrorEncoding = Encoding.UTF8;
        using (var process = Process.Start(info))
        {
            string output = process.StandardOutput.ReadToEnd();
            string error = process.StandardError.ReadToEnd();
            process.WaitForExit();
            code = process.ExitCode;
            if (code != 0) throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? "操作失败，请查看日志。" : error.Trim());
            return output.Trim();
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == "--env-file")
        {
            EnvFile = Path.GetFullPath(args[1]);
            var remaining = new string[args.Length - 2];
            Array.Copy(args, 2, remaining, 0, remaining.Length);
            args = remaining;
        }
        if (args.Length > 0)
        {
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput(),new UTF8Encoding(false)) { AutoFlush = true });
            Console.SetError(new StreamWriter(Console.OpenStandardError(),new UTF8Encoding(false)) { AutoFlush = true });
            try
            {
                int code;
                string action;
                switch (args[0])
                {
                    case "--status": action = "Status"; break;
                    case "--stop": action = "Stop"; break;
                    case "--start": case "--background": action = "Start"; break;
                    default: throw new ArgumentException("支持 --status、--start、--stop、--background。");
                }
                Console.WriteLine(Backend(action, out code));
                return code;
            }
            catch (Exception ex) { Console.Error.WriteLine(ex.Message); return 1; }
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new DriveForm());
        return 0;
    }
}

internal sealed class DriveForm : Form
{
    private readonly Label status = new Label();
    private readonly Label pending = new Label();
    private readonly List<Button> buttons = new List<Button>();
    private readonly CheckBox startup = new CheckBox();
    private readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    private string drive = "";
    private bool busy;
    private bool updating;

    internal DriveForm()
    {
        Text = "百度网盘";
        Font = new Font("Microsoft YaHei UI", 10F);
        ClientSize = new Size(520, 280);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        status.SetBounds(24, 22, 475, 35);
        status.Font = new Font(Font.FontFamily, 14F, FontStyle.Bold);
        status.Text = "正在读取运行状态…";
        pending.SetBounds(24, 66, 475, 25);
        Controls.Add(status); Controls.Add(pending);
        AddButton("启动同步", 24, 108, delegate { RunAction("Start"); });
        AddButton("安全停止", 185, 108, delegate { RunAction("Stop"); });
        AddButton("打开文件库", 346, 108, delegate { OpenFolder(drive + @"\"); });
        AddButton("百度设置", 24, 156, delegate { OpenSetting("openlist_url"); });
        AddButton("打开源码", 185, 156, delegate { OpenFolder(Program.Root); });
        AddButton("查看日志", 346, 156, delegate { OpenSetting("log_directory"); });
        startup.Text = "登录 Windows 后自动启动同步";
        startup.SetBounds(24, 211, 310, 25);
        updating = true;
        startup.Checked = false;
        updating = false;
        startup.CheckedChanged += delegate { if (!updating) RunAction(startup.Checked ? "EnableStartup" : "DisableStartup"); };
        Controls.Add(startup);
        var note = new Label { Text = "关闭这个窗口后，网盘仍会在后台运行。", AutoSize = true, ForeColor = SystemColors.GrayText };
        note.Location = new Point(24, 248); Controls.Add(note);
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开使用说明", null, delegate { Process.Start(Path.Combine(Program.Root,"README.md")); });
        ContextMenuStrip = menu;
        var tools = new Button { Text = "其他操作" };
        tools.SetBounds(350,207,142,32);
        tools.Click += delegate { menu.Show(tools,new Point(0,tools.Height)); };
        buttons.Add(tools); Controls.Add(tools);
        timer.Interval = 15000;
        timer.Tick += delegate { if (!busy) RunAction("Status"); };
        Shown += delegate { RunAction("Status"); timer.Start(); };
        FormClosed += delegate { timer.Stop(); };
    }

    private void AddButton(string text, int x, int y, Action action)
    {
        var button = new Button { Text = text };
        button.SetBounds(x,y,145,36);
        button.Click += delegate { action(); };
        buttons.Add(button); Controls.Add(button);
    }
    private void OpenFolder(string path)
    {
        if (Directory.Exists(path)) Process.Start("explorer.exe", Program.Quote(path));
        else MessageBox.Show(this,"目录尚不可用，请先完成同步配置。","百度网盘",MessageBoxButtons.OK,MessageBoxIcon.Information);
    }
    private void RunAction(string action)
    {
        if (busy) return;
        busy = true;
        foreach (var button in buttons) button.Enabled = false;
        startup.Enabled = false;
        if (action != "Status") status.Text = "正在处理，请稍候…";
        ThreadPool.QueueUserWorkItem(delegate
        {
            string error = null;
            Dictionary<string, object> state = null;
            try
            {
                int code;
                Program.Backend(action,out code);
                state = new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(Program.Backend("Status",out code));
            }
            catch (Exception ex) { error = ex.Message; }
            if (IsDisposed) return;
            try { BeginInvoke((Action)delegate
            {
                busy = false;
                foreach (var button in buttons) button.Enabled = true;
                startup.Enabled = true;
                if (error != null)
                {
                    status.Text = "操作未完成";
                    if (action != "Status") MessageBox.Show(this,error,"百度网盘",MessageBoxButtons.OK,MessageBoxIcon.Information);
                    return;
                }
                drive = Convert.ToString(state["library"]);
                bool mounted = Convert.ToBoolean(state["ready"]);
                bool authorized = Convert.ToBoolean(state["profile_ready"]);
                status.Text = mounted ? "百度网盘文件库已就绪" : (authorized ? "同步服务尚未启动" : "请先录入百度授权");
                pending.Text = "文件库：" + drive;
                updating = true;
                startup.Checked = Convert.ToBoolean(state["startup_enabled"]);
                updating = false;
            }); } catch (InvalidOperationException) {}
        });
    }
    private void OpenSetting(string key)
    {
        int code;
        var state = new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(Program.Backend("Status",out code));
        Process.Start(Convert.ToString(state[key]));
    }
}
