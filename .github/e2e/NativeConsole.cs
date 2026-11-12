using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class ServerFilesNativeConsole
{
    private const uint OpenFlags = 0x40 | 0x100; // NOCLOSEPROCESS | NOASYNC
    private const uint ReadWrite = 0x80000000 | 0x40000000;
    private const uint SharedReadWrite = 3;
    private const uint OpenExisting = 3;
    private const uint WaitSignaled = 0;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShellOpen
    {
        public int Size;
        public uint Mask;
        public IntPtr Window;
        public string Verb, File, Parameters, Directory;
        public int Show;
        public IntPtr Instance, IdList, ClassName, ClassKey;
        public uint HotKey;
        public IntPtr IconOrMonitor, Process;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Coord { public short X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public short Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BufferInfo
    {
        public Coord Size, Cursor;
        public ushort Attributes;
        public Rect Window;
        public Coord MaxSize;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct KeyInput
    {
        public int Down;
        public ushort Repeat, VirtualKey, ScanCode, Character;
        public uint ControlState;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputRecord
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KeyInput Key;
    }

    [DllImport("shell32.dll", EntryPoint = "ShellExecuteExW", SetLastError = true)]
    private static extern bool ShellExecuteEx(ref ShellOpen info);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetConsoleProcessList([Out] uint[] processIds, uint count);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetProcessId(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr handle, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security,
                                                     uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleScreenBufferInfo(SafeFileHandle output, out BufferInfo info);
    [DllImport("kernel32.dll", EntryPoint = "ReadConsoleOutputCharacterW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ReadConsoleOutputCharacter(SafeFileHandle output, [Out] char[] characters,
                                                          uint count, Coord origin, out uint read);
    [DllImport("kernel32.dll", EntryPoint = "WriteConsoleInputW", SetLastError = true)]
    private static extern bool WriteConsoleInput(SafeFileHandle input, [In] InputRecord[] records, uint count,
                                                 out uint written);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GenerateConsoleCtrlEvent(uint signal, uint processGroup);

    public sealed class ConnectionResult
    {
        public int ProcessId { get; private set; }
        public bool VerifiedHostKeyPrompt { get; private set; }

        public ConnectionResult(int processId, bool verifiedHostKeyPrompt)
        {
            ProcessId = processId;
            VerifiedHostKeyPrompt = verifiedHostKeyPrompt;
        }
    }

    public static ConnectionResult Launch(string exePath, string host, string username, int port,
                                          string remoteFolder, string password, string expectedFingerprint,
                                          int timeoutSeconds)
    {
        if (String.IsNullOrEmpty(password)) throw new ArgumentException("The fixture password is required.");
        foreach (string value in new[] { host, username, remoteFolder, password })
        {
            if (value == null || value.IndexOfAny(new[] { '\r', '\n', '\0' }) >= 0)
                throw new ArgumentException("Console fixture inputs must be single lines.");
        }

        exePath = Path.GetFullPath(exePath);
        if (!File.Exists(exePath)) throw new FileNotFoundException("Extracted launcher is missing.", exePath);

        uint previousConsole = PreviousConsole();
        FreeConsole();
        IntPtr process = IntPtr.Zero;
        uint processId = 0;
        bool attached = false, connected = false, verifiedHostKey = false;
        var timer = Stopwatch.StartNew();
        TimeSpan timeout = TimeSpan.FromSeconds(timeoutSeconds);
        try
        {
            var shell = new ShellOpen {
                Size = Marshal.SizeOf(typeof(ShellOpen)), Mask = OpenFlags, Verb = "open",
                File = exePath, Directory = Path.GetDirectoryName(exePath), Show = 1
            };
            if (!ShellExecuteEx(ref shell)) throw NativeError("Explorer-equivalent launch");
            process = shell.Process;
            if (process == IntPtr.Zero) throw new InvalidOperationException("ShellExecuteEx returned no process handle.");
            processId = GetProcessId(process);
            if (processId == 0) throw NativeError("GetProcessId");
            Attach(processId, process, timer, timeout);
            attached = true;

            using (var input = OpenConsole("CONIN$"))
            using (var output = OpenConsole("CONOUT$"))
            {
                WaitFor(process, output, timer, timeout, "SSH host prompt", password,
                        s => s.Contains("SSH host or user@host"));
                SendLine(input, host);
                WaitFor(process, output, timer, timeout, "SSH username prompt", password,
                        s => s.Contains("SSH username"));
                SendLine(input, username);
                WaitFor(process, output, timer, timeout, "SSH port prompt", password,
                        s => s.Contains("SSH port"));
                SendLine(input, port.ToString(System.Globalization.CultureInfo.InvariantCulture));
                WaitFor(process, output, timer, timeout, "remote folder prompt", password,
                        s => s.Contains("Remote folder"));
                SendLine(input, remoteFolder);

                string authentication = WaitFor(process, output, timer, timeout, "OpenSSH authentication prompt", password,
                    s => HasPasswordPrompt(s) || HasHostPrompt(s) || s.Contains("Files:   http://127.0.0.1:8878/"));
                if (HasHostPrompt(authentication) && !HasPasswordPrompt(authentication))
                {
                    if (String.IsNullOrEmpty(expectedFingerprint) ||
                        !Regex.Replace(authentication, @"\s+", "").Contains(expectedFingerprint))
                        throw new InvalidOperationException("OpenSSH requested host-key approval without the expected fixture fingerprint.");
                    SendLine(input, "yes");
                    verifiedHostKey = true;
                    authentication = WaitFor(process, output, timer, timeout, "OpenSSH password prompt", password,
                        s => HasPasswordPrompt(s) || s.Contains("Files:   http://127.0.0.1:8878/"));
                }
                if (!HasPasswordPrompt(authentication))
                    throw new InvalidOperationException("The fixture connected without exercising an OpenSSH password prompt.");

                SendLine(input, password);
                WaitFor(process, output, timer, timeout, "authenticated browser addresses", password,
                    s => s.Contains("Connected to ") && s.Contains("http://127.0.0.1:8878/")
                         && s.Contains("http://127.0.0.1:8877/"));
            }

            connected = true;
            return new ConnectionResult((int)processId, verifiedHostKey);
        }
        finally
        {
            if (attached && !connected) TrySendInterrupt();
            if (process != IntPtr.Zero) CloseHandle(process);
            RestoreConsole(previousConsole);
        }
    }

    public static void Stop(int processId)
    {
        Process process;
        try { process = Process.GetProcessById(processId); }
        catch (ArgumentException) { return; }
        using (process)
        {
            uint previousConsole = PreviousConsole();
            FreeConsole();
            try
            {
                if (process.HasExited) return;
                if (!AttachConsole((uint)processId)) throw NativeError("AttachConsole for shutdown");
                if (!TrySendInterrupt()) throw NativeError("Send Ctrl+C");
                if (!process.WaitForExit(10000)) throw new TimeoutException("Server Files did not close after Ctrl+C.");
            }
            finally { RestoreConsole(previousConsole); }
        }
    }

    private static uint PreviousConsole()
    {
        var processes = new uint[64];
        uint count = GetConsoleProcessList(processes, (uint)processes.Length);
        using (var current = Process.GetCurrentProcess())
        {
            for (int i = 0; i < Math.Min(count, (uint)processes.Length); i++)
                if (processes[i] != 0 && processes[i] != (uint)current.Id) return processes[i];
        }
        return 0;
    }

    private static void RestoreConsole(uint previous)
    {
        FreeConsole();
        if (previous != 0) AttachConsole(previous);
    }

    private static bool TrySendInterrupt()
    {
        return SetConsoleCtrlHandler(IntPtr.Zero, true) && GenerateConsoleCtrlEvent(0, 0);
    }

    private static SafeFileHandle OpenConsole(string device)
    {
        var handle = CreateFile(device, ReadWrite, SharedReadWrite, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        var error = NativeError("Open " + device);
        handle.Dispose();
        throw error;
    }

    private static void Attach(uint processId, IntPtr process, Stopwatch timer, TimeSpan timeout)
    {
        int lastError = 0;
        while (timer.Elapsed < timeout)
        {
            if (AttachConsole(processId)) return;
            lastError = Marshal.GetLastWin32Error();
            RequireRunning(process, "the launcher console", "");
            Thread.Sleep(80);
        }
        throw new Win32Exception(lastError, "Could not attach to the console of the shell-launched executable.");
    }

    private static string WaitFor(IntPtr process, SafeFileHandle output, Stopwatch timer, TimeSpan timeout,
                                  string phase, string password, Func<string, bool> accepted)
    {
        string screen = "";
        while (timer.Elapsed < timeout)
        {
            screen = ReadScreen(output);
            if (accepted(screen)) return screen;
            string diagnostic = Diagnostic(screen, password);
            RequireRunning(process, phase, diagnostic);
            if (screen.Contains("Press Enter to close.") || screen.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
                throw new InvalidOperationException("Server Files failed before " + phase + "." + diagnostic);
            Thread.Sleep(80);
        }
        throw new TimeoutException("Timed out waiting for " + phase + "." + Diagnostic(screen, password));
    }

    private static void RequireRunning(IntPtr process, string phase, string diagnostic)
    {
        if (WaitForSingleObject(process, 0) != WaitSignaled) return;
        uint exitCode;
        GetExitCodeProcess(process, out exitCode);
        throw new InvalidOperationException("Server Files exited with code " + exitCode + " before " + phase + "." + diagnostic);
    }

    private static string ReadScreen(SafeFileHandle output)
    {
        BufferInfo info;
        if (!GetConsoleScreenBufferInfo(output, out info)) throw NativeError("Read console buffer dimensions");
        var result = new StringBuilder();
        for (int row = Math.Max(0, info.Cursor.Y - 50); row <= info.Cursor.Y; row++)
        {
            var text = new char[info.Size.X];
            uint read;
            if (!ReadConsoleOutputCharacter(output, text, (uint)info.Size.X, new Coord { Y = (short)row }, out read))
                throw NativeError("Read actual console output");
            result.AppendLine(new string(text, 0, (int)read).TrimEnd(' ', '\t', '\0'));
        }
        return result.ToString();
    }

    private static bool HasHostPrompt(string text)
    {
        return text.IndexOf("Are you sure you want to continue connecting", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static bool HasPasswordPrompt(string text)
    {
        return Regex.IsMatch(text, @"(?i)\bpassword[ \t]*:");
    }

    private static string Diagnostic(string screen, string password)
    {
        if (screen.Length == 0) return "";
        string safe = screen.Replace(password, "[redacted]").Trim();
        if (safe.Length > 2500) safe = safe.Substring(safe.Length - 2500);
        return Environment.NewLine + "Console:" + Environment.NewLine + safe;
    }

    private static void SendLine(SafeFileHandle input, string text)
    {
        string line = text + '\r';
        var records = new InputRecord[line.Length * 2];
        for (int i = 0; i < line.Length; i++)
        {
            char character = line[i];
            char uppercase = Char.ToUpperInvariant(character);
            ushort virtualKey = character == '\r' ? (ushort)13 :
                ((uppercase >= 'A' && uppercase <= 'Z') || (character >= '0' && character <= '9'))
                    ? (ushort)uppercase : (ushort)0;
            var key = new KeyInput { Down = 1, Repeat = 1, VirtualKey = virtualKey, Character = character };
            records[2 * i] = new InputRecord { EventType = 1, Key = key };
            key.Down = 0;
            records[2 * i + 1] = new InputRecord { EventType = 1, Key = key };
        }
        uint written;
        if (!WriteConsoleInput(input, records, (uint)records.Length, out written))
            throw NativeError("Send console keystrokes");
        if (written != records.Length) throw new IOException("The console received only part of the requested input.");
    }

    private static Win32Exception NativeError(string operation)
    {
        int code = Marshal.GetLastWin32Error();
        return new Win32Exception(code, operation + " failed with Win32 error " + code + ".");
    }
}
