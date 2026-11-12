// Isolated lab prototype. This is not part of OpenRSAT or a publication backend.
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;

[ComImport, Guid("EA502723-A23D-11d1-A7D3-0000F87571E3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ILabGroupPolicyObject {
    [PreserveSig] int New([MarshalAs(UnmanagedType.LPWStr)] string domain, [MarshalAs(UnmanagedType.LPWStr)] string name, uint flags);
    [PreserveSig] int OpenDSGPO([MarshalAs(UnmanagedType.LPWStr)] string path, uint flags);
    [PreserveSig] int OpenLocalMachineGPO(uint flags);
    [PreserveSig] int OpenRemoteMachineGPO([MarshalAs(UnmanagedType.LPWStr)] string computer, uint flags);
    [PreserveSig] int Save([MarshalAs(UnmanagedType.Bool)] bool machine, [MarshalAs(UnmanagedType.Bool)] bool add, ref Guid extension, ref Guid tool);
    [PreserveSig] int Delete();
    [PreserveSig] int GetName(StringBuilder name, int length);
    [PreserveSig] int GetDisplayName(StringBuilder name, int length);
    [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name);
    [PreserveSig] int GetPath(StringBuilder path, int length);
    [PreserveSig] int GetDSPath(uint section, StringBuilder path, int length);
    [PreserveSig] int GetFileSysPath(uint section, StringBuilder path, int length);
    [PreserveSig] int GetRegistryKey(uint section, out IntPtr key);
}

public static class OpenRsatLabGpoComProbe {
    const string Server = "orsat-dc01.openrsat.test";
    public static bool ValidTarget(string guidText, string expectedName) {
        Guid id;
        const string prefix = "Codex-COMSave-";
        if (!Guid.TryParse(guidText, out id) || id == Guid.Empty || expectedName == null ||
            !expectedName.StartsWith(prefix, StringComparison.Ordinal) || expectedName.Length != prefix.Length + 12 ||
            id == new Guid("31B2F340-016D-11D2-945F-00C04FB984F9") ||
            id == new Guid("6AC1786C-016F-11D2-945F-00C04FB984F9")) return false;
        for (int i = prefix.Length; i < expectedName.Length; i++)
            if (!((expectedName[i] >= '0' && expectedName[i] <= '9') || (expectedName[i] >= 'a' && expectedName[i] <= 'f'))) return false;
        return true;
    }
    public static bool ValidObservedTarget(string guidText, string expectedName, string name, string display, string adPath, string filePath) {
        if (!ValidTarget(guidText, expectedName) || name == null || display == null || adPath == null || filePath == null) return false;
        Guid id = new Guid(guidText);
        string canonical = "{" + id.ToString("D").ToUpperInvariant() + "}";
        string ds = "LDAP://" + Server + "/CN=" + canonical + ",CN=Policies,CN=System,DC=openrsat,DC=test";
        string files = "\\\\" + Server + "\\SYSVOL\\openrsat.test\\Policies\\" + canonical;
        return String.Equals(name, canonical, StringComparison.OrdinalIgnoreCase) &&
            String.Equals(display, expectedName, StringComparison.Ordinal) &&
            String.Equals(adPath.TrimEnd('/'), ds, StringComparison.OrdinalIgnoreCase) &&
            String.Equals(filePath.TrimEnd('\\'), files, StringComparison.OrdinalIgnoreCase);
    }
    public static bool ValidSyntheticPolicy(byte[] data) {
        if (data == null) return false;
        using (MemoryStream m = new MemoryStream()) using (BinaryWriter w = new BinaryWriter(m, Encoding.Unicode)) {
            w.Write(0x67655250u); w.Write(1u); w.Write((ushort)'[');
            w.Write(Encoding.Unicode.GetBytes("Software\\Policies\\OpenRSAT-Isolated-Probe")); w.Write((ushort)0);
            w.Write((ushort)';'); w.Write(Encoding.Unicode.GetBytes("SyntheticValue")); w.Write((ushort)0);
            w.Write((ushort)';'); w.Write(4u); w.Write((ushort)';'); w.Write(4u); w.Write((ushort)';');
            w.Write(0x01020304u); w.Write((ushort)']'); w.Flush();
            byte[] expected = m.ToArray(); if (data.Length != expected.Length) return false;
            for (int i = 0; i < data.Length; i++) if (data[i] != expected[i]) return false;
            return true;
        }
    }
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
    static extern int RegCreateKeyEx(IntPtr root, string name, uint reserved, string cls, uint options,
        uint access, IntPtr security, out IntPtr result, out uint disposition);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
    static extern int RegSetValueEx(IntPtr key, string name, uint reserved, uint type, ref uint data, uint size);
    [DllImport("advapi32.dll")]
    static extern int RegCloseKey(IntPtr key);
    static void Check(int result, string stage) {
        if (result < 0) throw new InvalidOperationException(stage + " HRESULT 0x" + result.ToString("X8"));
    }
    static void CheckRegistry(int result, string stage) {
        if (result != 0) throw new InvalidOperationException(stage + " Win32 " + result);
    }
    public static string Run(string guidText, string expectedName, bool write) {
        if (!ValidTarget(guidText, expectedName)) throw new ArgumentException("Invalid isolated target");
        Guid id = new Guid(guidText);
        string canonical = "{" + id.ToString("D").ToUpperInvariant() + "}";
        string server = Server;
        string dn = "CN=" + canonical + ",CN=Policies,CN=System,DC=openrsat,DC=test";
        string ds = "LDAP://" + server + "/" + dn;
        Type t = Type.GetTypeFromCLSID(new Guid("EA502722-A23D-11d1-A7D3-0000F87571E3"), true);
        object obj = Activator.CreateInstance(t);
        try {
            ILabGroupPolicyObject gpo = (ILabGroupPolicyObject)obj;
            Check(gpo.OpenDSGPO(ds, write ? 1u : 3u), "OpenDSGPO");
            StringBuilder name = new StringBuilder(1024), display = new StringBuilder(1024);
            StringBuilder adPath = new StringBuilder(32768), filePath = new StringBuilder(32768);
            Check(gpo.GetName(name, name.Capacity), "GetName");
            Check(gpo.GetDisplayName(display, display.Capacity), "GetDisplayName");
            Check(gpo.GetDSPath(0, adPath, adPath.Capacity), "GetDSPath");
            Check(gpo.GetFileSysPath(0, filePath, filePath.Capacity), "GetFileSysPath");
            if (!ValidObservedTarget(guidText, expectedName, name.ToString(), display.ToString(), adPath.ToString(), filePath.ToString()))
                throw new InvalidOperationException("Opened target or DC path does not match the isolated target: " + adPath + " | " + filePath);
            if (!write) return "READ_ONLY_OK " + adPath + " | " + filePath;
            IntPtr root = IntPtr.Zero, key = IntPtr.Zero;
            try {
                Check(gpo.GetRegistryKey(2, out root), "GetRegistryKey");
                uint disposition;
                CheckRegistry(RegCreateKeyEx(root, "Software\\Policies\\OpenRSAT-Isolated-Probe", 0, null, 0,
                    0x00020006, IntPtr.Zero, out key, out disposition), "RegCreateKeyEx");
                uint value = 0x01020304;
                CheckRegistry(RegSetValueEx(key, "SyntheticValue", 0, 4, ref value, 4), "RegSetValueEx");
            } finally { if (key != IntPtr.Zero) RegCloseKey(key); if (root != IntPtr.Zero) RegCloseKey(root); }
            Guid extension = new Guid("35378EAC-683F-11D2-A89A-00C04FBBCFA2");
            Guid tool = new Guid("D02B1F72-3407-48AE-BA88-E8213C6761F1");
            Check(gpo.Save(true, true, ref extension, ref tool), "Save");
            return "SAVE_RETURNED_S_OK " + adPath + " | " + filePath;
        } finally { Marshal.FinalReleaseComObject(obj); }
    }
}
