using System.Runtime.InteropServices;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// A rename that replaces an OPEN destination without the destination ever
/// ceasing to exist.
/// </summary>
/// <remarks>
/// WHY THIS IS HERE AND NOT A FRAMEWORK CALL. Publishing state needs three
/// things at once, and Windows exposes no managed API that gives all three:
///
///   * atomic - the destination is the whole old content or the whole new
///     content, with no instant at which it is missing or partial;
///   * replacing - it overwrites what is already there;
///   * tolerant of readers - it succeeds while another handle is open.
///
/// File.Move(overwrite: true) is atomic and replacing, but on Windows it CANNOT
/// overwrite a destination anyone holds: MoveFileEx fails with
/// ERROR_ACCESS_DENIED regardless of the sharing the reader granted. That is the
/// exact failure that used to wedge a run - the cohort journal had already
/// recorded the intent to launch, the state describing it was never published,
/// and a resume found the two disagreeing with no way to continue or to abandon
/// honestly.
///
/// File.Replace (Win32 ReplaceFile) does tolerate readers, but it works by
/// renaming the destination aside and the replacement into place, so there is a
/// real instant during which the path does not resolve. Trading a wedged run for
/// a state file that momentarily does not exist is not a fix; a resume that read
/// at that instant would conclude the run had no state at all.
///
/// The kernel does have the operation we want. FILE_RENAME_POSIX_SEMANTICS,
/// available since Windows 10 1607 on NTFS, gives POSIX rename(2) behaviour: a
/// single atomic directory-entry swap that succeeds even when the destination is
/// open, provided its holders granted FILE_SHARE_DELETE - which every reader in
/// this tool now does. Existing handles keep reading the bytes they opened, and
/// the path never stops resolving.
///
/// Everything here fails soft. On a platform, filesystem, or Windows build that
/// does not support the operation, TryReplaceInPlace returns false and the
/// caller falls back to the ReplaceFile path. It never reports success it did
/// not achieve.
/// </remarks>
internal static class NativeAtomicReplace
{
    private const uint Delete = 0x00010000;      // DELETE
    private const uint Synchronize = 0x00100000; // SYNCHRONIZE
    private const uint ShareRead = 0x00000001;
    private const uint ShareWrite = 0x00000002;
    private const uint ShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FlagBackupSemantics = 0x02000000;

    // FILE_INFO_BY_HANDLE_CLASS.FileRenameInfoEx
    private const int FileRenameInfoEx = 22;

    private const uint FileRenameReplaceIfExists = 0x00000001;
    private const uint FileRenamePosixSemantics = 0x00000002;

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandleWrapper CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandleWrapper handle,
        int fileInformationClass,
        IntPtr fileInformation,
        uint bufferSize);

    private sealed class SafeFileHandleWrapper : SafeHandle
    {
        internal SafeFileHandleWrapper() : base(new IntPtr(-1), ownsHandle: true) { }

        public override bool IsInvalid => handle == IntPtr.Zero || handle == new IntPtr(-1);

        protected override bool ReleaseHandle() => CloseHandle(handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
    }

    /// <summary>
    /// Renames <paramref name="source"/> onto <paramref name="destination"/> with
    /// POSIX semantics.
    /// </summary>
    /// <returns>
    /// True when the rename completed. False when the platform does not offer the
    /// operation, in which case nothing was changed and the caller must fall back.
    /// </returns>
    /// <exception cref="IOException">
    /// The operation is available but was refused - a genuine sharing violation,
    /// for instance. Thrown with the Win32 code intact so the caller's retry
    /// classifier can recognise it.
    /// </exception>
    internal static bool TryReplaceInPlace(string source, string destination)
    {
        if (!OperatingSystem.IsWindows())
        {
            // On POSIX hosts File.Move already IS rename(2): atomic, replacing,
            // and indifferent to open readers. There is nothing to add.
            return false;
        }

        // DELETE access on the source is what a rename needs; the name is what
        // moves, not the bytes. Backup semantics keeps this working for the
        // directory-relative forms the framework may hand us.
        using var handle = CreateFile(source, Delete | Synchronize,
            ShareRead | ShareWrite | ShareDelete, IntPtr.Zero, OpenExisting, FlagBackupSemantics, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            throw new IOException(
                $"Could not open '{source}' to rename it onto '{destination}' (Win32 {error}).",
                unchecked((int)(0x80070000 | (uint)error)));
        }

        var target = Path.GetFullPath(destination);
        // FILE_RENAME_INFO: Flags (4) + padding (4) + RootDirectory (8) +
        // FileNameLength (4) + FileName[]. The name is NOT null-terminated and
        // FileNameLength counts BYTES, not characters.
        var nameBytes = (uint)(target.Length * sizeof(char));
        var headerSize = 20;
        var bufferSize = headerSize + (int)nameBytes + sizeof(char);
        var buffer = Marshal.AllocHGlobal(bufferSize);
        try
        {
            for (var offset = 0; offset < bufferSize; offset++)
            {
                Marshal.WriteByte(buffer, offset, 0);
            }
            Marshal.WriteInt32(buffer, 0, unchecked((int)(FileRenameReplaceIfExists | FileRenamePosixSemantics)));
            Marshal.WriteIntPtr(buffer, 8, IntPtr.Zero);
            Marshal.WriteInt32(buffer, 16, (int)nameBytes);
            for (var index = 0; index < target.Length; index++)
            {
                Marshal.WriteInt16(buffer, headerSize + (index * sizeof(char)), (short)target[index]);
            }

            if (SetFileInformationByHandle(handle, FileRenameInfoEx, buffer, (uint)bufferSize))
            {
                return true;
            }

            var error = Marshal.GetLastWin32Error();
            // ERROR_INVALID_PARAMETER / ERROR_NOT_SUPPORTED / ERROR_INVALID_FUNCTION
            // are how a build or filesystem without POSIX rename declines. Those
            // are "unavailable", not "refused", so the caller falls back rather
            // than treating the publish as failed.
            if (error is 87 or 50 or 1)
            {
                return false;
            }
            throw new IOException(
                $"Renaming '{source}' onto '{destination}' was refused (Win32 {error}).",
                unchecked((int)(0x80070000 | (uint)error)));
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
