// GenFill-Setup.exe: hosts GenFill-Setup.ps1 (embedded as a resource) in-process,
// so artists get a normal double-clickable app with no console window.
// Built by installers\build_setup.ps1 with the C# compiler that ships with Windows.
using System;
using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("GenFill Setup")]
[assembly: AssemblyProduct("GenFill for Nuke")]
[assembly: AssemblyDescription("Installs GenFill, Generative Fill for Nuke")]

static class GenFillSetup
{
    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string script;
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream("GenFill-Setup.ps1"))
            using (StreamReader r = new StreamReader(s, Encoding.UTF8))
            {
                script = r.ReadToEnd();
            }
            Environment.SetEnvironmentVariable("GENFILL_SETUP_EXE", asm.Location);

            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(script);
                    // -Name value / -Switch, passed through to the script's param() block.
                    for (int i = 0; i < args.Length; i++)
                    {
                        string a = args[i];
                        if (!(a.StartsWith("-") || a.StartsWith("/"))) continue;
                        string name = a.TrimStart('-', '/');
                        if (i + 1 < args.Length && !args[i + 1].StartsWith("-") && !args[i + 1].StartsWith("/"))
                            ps.AddParameter(name, args[++i]);
                        else
                            ps.AddParameter(name, true);
                    }
                    ps.Invoke();
                    if (ps.HadErrors && ps.Streams.Error.Count > 0)
                    {
                        List<string> errors = new List<string>();
                        foreach (ErrorRecord e in ps.Streams.Error) errors.Add(e.ToString());
                        Fail(string.Join(Environment.NewLine, errors.ToArray()));
                        return 1;
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            Fail(ex.Message);
            return 1;
        }
    }

    static void Fail(string message)
    {
        MessageBox.Show("GenFill Setup couldn't start:" + Environment.NewLine + Environment.NewLine + message,
            "GenFill Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
