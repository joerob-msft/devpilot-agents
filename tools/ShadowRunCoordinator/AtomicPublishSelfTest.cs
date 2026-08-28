using System.Text;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// Proves that publishing state stays atomic and never wedges when another
/// process is reading the file being replaced.
/// </summary>
/// <remarks>
/// WHY THIS IS A MODE OF THE PROGRAM. The defect being guarded here is a Windows
/// file-sharing interaction, so it cannot be reproduced by reasoning about the
/// code or by a mock: it needs two real handles on one real file, in the process
/// that actually publishes. There is no unit test assembly in this tool, and
/// inventing one to hold five checks would add a build target to CI for a
/// property that is cheapest to assert from inside the binary that has it.
///
/// WHAT WENT WRONG BEFORE. The publish moved a temporary over the destination
/// with no retry, while every reader in the tool opened files with FileShare.Read
/// and denied FileShare.Delete. On Windows that combination makes the replace
/// fail with a sharing violation whenever a reader happens to hold the file - a
/// digest check, a state read, a virus scanner. The exception escaped from the
/// middle of the publish, and because the cohort journal had already recorded
/// the launch intent before the state was published, the run was left with a
/// journal that said a launch was intended and a state file that did not agree.
/// A resume could then neither continue nor honestly abandon.
///
/// WHAT IS ASSERTED. Not merely that the publish now usually succeeds, but the
/// four properties that make the wedge impossible: a held reader does not break
/// a publish; a transient violation is survived within the budget; an
/// unsurvivable one produces a TYPED, recoverable error with the destination
/// still holding whole old content and no temporary left behind; and concurrent
/// publishers leave the destination holding exactly one whole published value.
/// </remarks>
internal static class AtomicPublishSelfTest
{
    private static int _failures;
    private static int _passes;

    private static void Check(string name, Action body)
    {
        try
        {
            body();
            _passes++;
            Console.Out.WriteLine($"  PASS  {name}");
        }
        catch (Exception exception)
        {
            _failures++;
            Console.Out.WriteLine($"  FAIL  {name} :: {exception.Message}");
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new ContractException(message);
        }
    }

    /// <summary>A Windows sharing violation, shaped exactly as the kernel raises one.</summary>
    private static IOException SharingViolation() =>
        new("The process cannot access the file because it is being used by another process.",
            unchecked((int)0x80070020));

    private static void RequireNoTemporaries(string directory)
    {
        var leftovers = Directory.GetFiles(directory, "*.tmp");
        Require(leftovers.Length == 0,
            $"{leftovers.Length} temporary file(s) were left behind: {string.Join(", ", leftovers)}");
    }

    internal static int Run(string root, TextWriter log)
    {
        _failures = 0;
        _passes = 0;
        Directory.CreateDirectory(root);
        var directory = Path.Combine(root, "atomic-publish-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        log.WriteLine("Atomic state publish");

        try
        {
            var path = Path.Combine(directory, "state.json");
            var oldContent = "{\"generation\":\"old\",\"launchIntended\":true}";
            var newContent = "{\"generation\":\"new\",\"launchIntended\":true}";

            Check("a publish over a file held open by a reader succeeds", () =>
            {
                CanonicalJson.WriteFileAtomic(path, oldContent);
                // The exact shape of the original wedge: a reader is holding the
                // destination open across the replace.
                using (var reader = new FileStream(path, FileMode.Open, FileAccess.Read,
                           FileShare.ReadWrite | FileShare.Delete))
                {
                    CanonicalJson.WriteFileAtomic(path, newContent);
                    // The held handle keeps serving the bytes it opened. That is
                    // correct snapshot behaviour, not staleness: the reader asked
                    // for the file as it stood.
                    var buffer = new byte[oldContent.Length];
                    var read = reader.Read(buffer, 0, buffer.Length);
                    Require(read == oldContent.Length, $"the held reader read {read} of {oldContent.Length} bytes");
                    Require(Encoding.UTF8.GetString(buffer) == oldContent,
                        "the held reader saw content it did not open");
                }
                Require(File.ReadAllText(path) == newContent, "the destination did not take the new content");
                RequireNoTemporaries(directory);
            });

            Check("the tool's own digest reader does not block a publish", () =>
            {
                CanonicalJson.WriteFileAtomic(path, oldContent);
                var digest = CanonicalJson.Sha256HexOfFile(path);
                Require(digest.Length == 64, "the digest was not a SHA-256");
                CanonicalJson.WriteFileAtomic(path, newContent);
                Require(File.ReadAllText(path) == newContent, "the destination did not take the new content");
            });

            Check("a foreign reader that withholds delete-sharing is waited out, not failed on", () =>
            {
                // Nothing in this tool opens files this way any more, but other
                // processes on the machine do - scanners, indexers, editors. The
                // replace cannot succeed while such a handle is open, so this is
                // exactly what the bounded retry is for.
                CanonicalJson.WriteFileAtomic(path, oldContent);
                var opened = new ManualResetEventSlim(false);
                var holder = new Thread(() =>
                {
                    using var reader = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                    opened.Set();
                    Thread.Sleep(150);
                })
                { IsBackground = true };
                holder.Start();
                Require(opened.Wait(TimeSpan.FromSeconds(10)), "the foreign reader never opened the file");
                CanonicalJson.WriteFileAtomic(path, newContent);
                holder.Join(TimeSpan.FromSeconds(10));
                Require(File.ReadAllText(path) == newContent, "the destination did not take the new content");
                RequireNoTemporaries(directory);
            });

            Check("a transient sharing violation is survived inside the budget", () =>
            {
                CanonicalJson.WriteFileAtomic(path, oldContent);
                var attempts = 0;
                CanonicalJson.AtomicPublishAttemptHook = (_, attempt) =>
                {
                    attempts = attempt;
                    if (attempt <= 4)
                    {
                        throw SharingViolation();
                    }
                };
                try
                {
                    CanonicalJson.WriteFileAtomic(path, newContent);
                }
                finally
                {
                    CanonicalJson.AtomicPublishAttemptHook = null;
                }
                Require(attempts == 5, $"the publish took {attempts} attempt(s) rather than 5");
                Require(File.ReadAllText(path) == newContent, "the destination did not take the new content");
                RequireNoTemporaries(directory);
            });

            Check("an unsurvivable violation fails typed and recoverable, leaving whole old content", () =>
            {
                CanonicalJson.WriteFileAtomic(path, oldContent);
                CanonicalJson.AtomicPublishAttemptHook = (_, _) => throw SharingViolation();
                CanonicalJson.AtomicPublishTimeoutException? caught = null;
                try
                {
                    CanonicalJson.WriteFileAtomic(path, newContent);
                }
                catch (CanonicalJson.AtomicPublishTimeoutException exception)
                {
                    caught = exception;
                }
                finally
                {
                    CanonicalJson.AtomicPublishAttemptHook = null;
                }
                Require(caught is not null, "the exhausted budget did not raise the typed error");
                Require(caught!.Recoverable, "the typed error did not declare itself recoverable");
                Require(caught.Attempts > 1, "the budget allowed only one attempt");
                Require(caught.InnerException is IOException, "the typed error did not carry the cause");
                // The whole point of the failure mode: state is old-or-new, and
                // here it is old, entire, and readable.
                Require(File.ReadAllText(path) == oldContent,
                    "the destination was left holding neither the whole old content nor the whole new content");
                RequireNoTemporaries(directory);
            });

            Check("a destination lost on the final attempt is restored to the new content, not reported as unchanged", () =>
            {
                // ERROR_UNABLE_TO_MOVE_REPLACEMENT_2 reproduced by its effect
                // rather than by its cause, because provoking the real code
                // requires a filesystem state no test can arrange reliably: the
                // destination has been renamed aside and the replacement has not
                // moved in, so at that instant the path does not resolve.
                //
                // Every attempt but the last recovers from that on its own - the
                // next attempt finds no destination and renames into place. The
                // LAST one does not, and before this case existed the code threw
                // a "recoverable, destination unchanged" timeout over a path
                // that had ceased to exist while deleting the only copy of the
                // new content. That is the wedge the whole change exists to
                // remove, reintroduced at the bottom of the retry loop.
                CanonicalJson.WriteFileAtomic(path, oldContent);
                CanonicalJson.AtomicPublishAttemptHook = (target, _) =>
                {
                    if (File.Exists(target))
                    {
                        File.Delete(target);
                    }
                    throw SharingViolation();
                };
                Exception? caught = null;
                try
                {
                    CanonicalJson.WriteFileAtomic(path, newContent);
                }
                catch (Exception exception)
                {
                    caught = exception;
                }
                finally
                {
                    CanonicalJson.AtomicPublishAttemptHook = null;
                }
                Require(caught is null,
                    $"a recoverable publish over a vanished destination raised {caught?.GetType().Name}");
                Require(File.Exists(path), "the destination was left missing entirely");
                Require(File.ReadAllText(path) == newContent,
                    "the destination was left holding neither the whole old content nor the whole new content");
                RequireNoTemporaries(directory);
            });

            Check("a failure that is not a sharing violation is reported at once, not retried", () =>
            {
                CanonicalJson.WriteFileAtomic(path, oldContent);
                var attempts = 0;
                CanonicalJson.AtomicPublishAttemptHook = (_, _) =>
                {
                    attempts++;
                    throw new IOException("There is not enough space on the disk.", unchecked((int)0x80070070));
                };
                var raised = false;
                try
                {
                    CanonicalJson.WriteFileAtomic(path, newContent);
                }
                catch (IOException)
                {
                    raised = true;
                }
                catch (CanonicalJson.AtomicPublishTimeoutException)
                {
                    throw new ContractException("a permanent failure was mistaken for a sharing violation");
                }
                finally
                {
                    CanonicalJson.AtomicPublishAttemptHook = null;
                }
                Require(raised, "a permanent failure was swallowed");
                Require(attempts == 1, $"a permanent failure was retried {attempts} time(s)");
                Require(File.ReadAllText(path) == oldContent, "the destination changed on a failed publish");
                RequireNoTemporaries(directory);
            });

            Check("readers racing a publisher never observe partial content", () =>
            {
                var racePath = Path.Combine(directory, "race.json");
                var replacesAtStart = Interlocked.Read(ref CanonicalJson.AtomicPublishReplaceCount);
                CanonicalJson.WriteFileAtomic(racePath, oldContent);
                var known = new HashSet<string>(StringComparer.Ordinal) { oldContent, newContent };
                var stop = false;
                var readerFaults = 0;
                var partial = 0;
                var reads = 0;
                var readers = new List<Thread>();
                for (var index = 0; index < 4; index++)
                {
                    var thread = new Thread(() =>
                    {
                        while (!Volatile.Read(ref stop))
                        {
                            try
                            {
                                var text = Encoding.UTF8.GetString(
                                    StrictJson.ReadFileBytes(racePath, "race"));
                                Interlocked.Increment(ref reads);
                                if (!known.Contains(text))
                                {
                                    Interlocked.Increment(ref partial);
                                }
                            }
                            catch (Exception)
                            {
                                // A reader that arrives exactly as the directory
                                // entry is swapped may be turned away. That is a
                                // reader-side retry decision, not a torn read, and
                                // it is counted rather than ignored so a flood of
                                // them would still be visible below.
                                Interlocked.Increment(ref readerFaults);
                            }
                        }
                    })
                    { IsBackground = true };
                    readers.Add(thread);
                    thread.Start();
                }

                var writerFault = (Exception?)null;
                try
                {
                    for (var round = 0; round < 200; round++)
                    {
                        CanonicalJson.WriteFileAtomic(racePath, round % 2 == 0 ? newContent : oldContent);
                    }
                }
                catch (Exception exception)
                {
                    writerFault = exception;
                }
                finally
                {
                    Volatile.Write(ref stop, true);
                    foreach (var thread in readers)
                    {
                        thread.Join(TimeSpan.FromSeconds(10));
                    }
                }

                Require(writerFault is null, $"the publisher failed under a real reader race: {writerFault?.Message}");
                Require(reads > 0, "no read completed, so the race proved nothing");
                Require(partial == 0, $"{partial} read(s) observed content that was never published");
                // On a host with POSIX rename the path never stops resolving, so
                // a reader is never even turned away. Asserted only when that
                // path was actually taken; a fallback host is allowed its retries.
                if (Interlocked.Read(ref CanonicalJson.AtomicPublishReplaceCount) == replacesAtStart)
                {
                    Require(readerFaults == 0,
                        $"{readerFaults} reader(s) were turned away despite an uninterrupted atomic rename path");
                }
                Require(known.Contains(File.ReadAllText(racePath)), "the destination ended on unpublished content");
                RequireNoTemporaries(directory);
                log.WriteLine($"        ({reads} reads, {readerFaults} reader retries, 200 publishes)");
            });

            Check("concurrent publishers leave exactly one whole published value", () =>
            {
                var contendedPath = Path.Combine(directory, "contended.json");
                var writerCount = 6;
                var perWriter = 40;
                var published = new HashSet<string>(StringComparer.Ordinal);
                for (var writer = 0; writer < writerCount; writer++)
                {
                    published.Add($"{{\"writer\":{writer}}}");
                }
                CanonicalJson.WriteFileAtomic(contendedPath, "{\"writer\":-1}");
                published.Add("{\"writer\":-1}");

                var faults = new List<Exception>();
                var threads = new List<Thread>();
                var renamesBefore = Interlocked.Read(ref CanonicalJson.AtomicPublishRenameCount);
                var posixBefore = Interlocked.Read(ref CanonicalJson.AtomicPublishPosixRenameCount);
                var replacesBefore = Interlocked.Read(ref CanonicalJson.AtomicPublishReplaceCount);
                // The destination must never be absent while publishers work. A
                // racing ReplaceFile can rename it to an internal backup name and
                // leave nothing behind; a resume that read at that instant would
                // see a run with no state at all.
                var stopWatcher = false;
                var absences = 0;
                var watcher = new Thread(() =>
                {
                    while (!Volatile.Read(ref stopWatcher))
                    {
                        if (!File.Exists(contendedPath))
                        {
                            Interlocked.Increment(ref absences);
                        }
                    }
                })
                { IsBackground = true };
                watcher.Start();
                for (var writer = 0; writer < writerCount; writer++)
                {
                    var content = $"{{\"writer\":{writer}}}";
                    var thread = new Thread(() =>
                    {
                        for (var round = 0; round < perWriter; round++)
                        {
                            try
                            {
                                CanonicalJson.WriteFileAtomic(contendedPath, content);
                            }
                            catch (Exception exception)
                            {
                                lock (faults) { faults.Add(exception); }
                                return;
                            }
                        }
                    })
                    { IsBackground = true };
                    threads.Add(thread);
                    thread.Start();
                }
                foreach (var thread in threads)
                {
                    thread.Join(TimeSpan.FromSeconds(60));
                }
                Volatile.Write(ref stopWatcher, true);
                watcher.Join(TimeSpan.FromSeconds(10));
                var renames = Interlocked.Read(ref CanonicalJson.AtomicPublishRenameCount) - renamesBefore;
                var posix = Interlocked.Read(ref CanonicalJson.AtomicPublishPosixRenameCount) - posixBefore;
                var replaces = Interlocked.Read(ref CanonicalJson.AtomicPublishReplaceCount) - replacesBefore;
                log.WriteLine($"        ({renames} rename(s), {posix} posix rename(s), {replaces} replace(s), {absences} absence(s))");
                // The guarantee this method advertises, asserted rather than
                // assumed: state is old-or-new, so the destination is never
                // missing. Only the ReplaceFile last resort can break it, and on
                // a host that has POSIX rename it is never reached.
                Require(replaces > 0 || absences == 0,
                    $"the destination was absent on {absences} observation(s) despite an atomic rename path");

                // Any fault at all must be the typed recoverable one. A raw
                // sharing violation escaping here would be the original defect.
                foreach (var fault in faults)
                {
                    Require(fault is CanonicalJson.AtomicPublishTimeoutException,
                        $"a publisher failed with an untyped error: {fault.GetType().Name}: {fault.Message}");
                }
                var final = File.ReadAllText(contendedPath);
                Require(published.Contains(final), $"the destination ended holding '{final}', which nobody published");
                RequireNoTemporaries(directory);
                // A backup is requested on every replace, so a leftover one would
                // mean a racing ReplaceFile left the state under a name nothing
                // reads instead of tidying it away.
                var strays = Directory.GetFiles(directory, "contended.json*")
                    .Where(candidate => !string.Equals(candidate, contendedPath, StringComparison.OrdinalIgnoreCase))
                    .ToArray();
                Require(strays.Length == 0, $"a replace left {strays.Length} stray file(s): {string.Join(", ", strays)}");
                log.WriteLine($"        ({writerCount} writers x {perWriter} publishes, {faults.Count} recoverable timeout(s))");
            });

            Check("a first publish creates the destination whole", () =>
            {
                var freshPath = Path.Combine(directory, "fresh", "state.json");
                CanonicalJson.WriteFileAtomic(freshPath, newContent);
                Require(File.ReadAllText(freshPath) == newContent, "the first publish did not land whole");
                RequireNoTemporaries(Path.GetDirectoryName(freshPath)!);
            });

            // EVERYTHING ABOVE TOOK THE POSIX RENAME. On NTFS the kernel rename
            // always succeeds, so the ReplaceFile last resort - and with it the
            // named backup, the restore that puts the old content back, and the
            // cleanup that removes the backup afterwards - never executed once.
            // That is exactly the code whose earlier version could leave a state
            // file with no content at all, so it is run here deliberately rather
            // than left to the hosts that happen to lack a POSIX rename.
            CanonicalJson.ForceReplaceFileFallbackForTests = true;
            try
            {
                var replacePath = Path.Combine(directory, "replace", "state.json");
                Check("the ReplaceFile fallback publishes whole content", () =>
                {
                    CanonicalJson.WriteFileAtomic(replacePath, oldContent);
                    var before = CanonicalJson.AtomicPublishReplaceCount;
                    CanonicalJson.WriteFileAtomic(replacePath, newContent);
                    Require(CanonicalJson.AtomicPublishReplaceCount > before,
                        "the forced fallback did not actually reach File.Replace");
                    Require(File.ReadAllText(replacePath) == newContent,
                        "the fallback publish did not land whole");
                    RequireNoTemporaries(Path.GetDirectoryName(replacePath)!);
                });

                Check("the ReplaceFile fallback publishes past a reader that grants delete sharing", () =>
                {
                    // The sharing mode every reader in this tool uses. ReplaceFile
                    // renames the destination aside, which needs DELETE sharing
                    // just as a rename does, so this is the reader it can pass.
                    using var reader = new FileStream(
                        replacePath, FileMode.Open, FileAccess.Read,
                        FileShare.Read | FileShare.Write | FileShare.Delete);
                    CanonicalJson.WriteFileAtomic(replacePath, oldContent);
                    Require(File.ReadAllText(replacePath) == oldContent,
                        "the fallback could not publish over an open reader");
                });

                Check("the ReplaceFile fallback fails typed and recoverable against a reader that denies delete sharing", () =>
                {
                    // Honest limit of the last resort: with no POSIX rename and no
                    // DELETE share there is no way to publish at all. What matters
                    // is that this is reported as the recoverable, old-or-new
                    // outcome rather than wedging or losing the file.
                    using var reader = new FileStream(
                        replacePath, FileMode.Open, FileAccess.Read, FileShare.Read);
                    CanonicalJson.AtomicPublishTimeoutException? caught = null;
                    try
                    {
                        CanonicalJson.WriteFileAtomic(replacePath, newContent);
                    }
                    catch (CanonicalJson.AtomicPublishTimeoutException exception)
                    {
                        caught = exception;
                    }
                    Require(caught is not null, "an impossible fallback publish did not report the typed error");
                    Require(caught!.Recoverable, "the typed error did not declare itself recoverable");
                    Require(File.ReadAllText(replacePath) == oldContent,
                        "the fallback left the destination holding neither whole old nor whole new content");
                });

                Check("a fallback destination lost on the final attempt still ends whole", () =>
                {
                    CanonicalJson.WriteFileAtomic(replacePath, oldContent);
                    CanonicalJson.AtomicPublishAttemptHook = (target, _) =>
                    {
                        if (File.Exists(target))
                        {
                            File.Delete(target);
                        }
                        throw SharingViolation();
                    };
                    Exception? caught = null;
                    try
                    {
                        CanonicalJson.WriteFileAtomic(replacePath, newContent);
                    }
                    catch (Exception exception)
                    {
                        caught = exception;
                    }
                    finally
                    {
                        CanonicalJson.AtomicPublishAttemptHook = null;
                    }
                    Require(caught is null,
                        $"a recoverable fallback publish raised {caught?.GetType().Name}");
                    Require(File.ReadAllText(replacePath) == newContent,
                        "the fallback left the destination holding neither whole old nor whole new content");
                });

                // F20: a reader that arrives during the fallback's aside-rename
                // window sees the path momentarily absent. StrictJson's reader
                // fails immediately on absence, so a concurrent verification read
                // could observe a state file that "does not exist" even though the
                // publish is old-or-new. The recovery reader waits out that
                // PROVEN-TRANSIENT window - keyed on the named backup the fallback
                // leaves beside the target - and reads whole content instead.
                Check("a reader recovers across the fallback's transient absence window", () =>
                {
                    var windowPath = Path.Combine(directory, "reader-window", "state.json");
                    CanonicalJson.WriteFileAtomic(windowPath, oldContent);

                    // Stage the exact on-disk state the fallback exposes mid-flight
                    // and the state ERROR_UNABLE_TO_MOVE_REPLACEMENT_2 leaves: the
                    // destination renamed aside to its named backup, so the path
                    // does not resolve but a '<name>.<guid>.bak' sibling holds the
                    // old content.
                    var backup = windowPath + "." + Guid.NewGuid().ToString("N") + ".bak";
                    File.Move(windowPath, backup);

                    // The naive reader - the shape StrictJson uses - fails at once
                    // on that absence. Asserted here as the pre-fix contrast the
                    // recovery is measured against; without it this check proves
                    // nothing.
                    var naiveFailed = false;
                    try
                    {
                        using var _ = new FileStream(windowPath, FileMode.Open, FileAccess.Read,
                            FileShare.ReadWrite | FileShare.Delete);
                    }
                    catch (FileNotFoundException)
                    {
                        naiveFailed = true;
                    }
                    Require(naiveFailed, "a naive reader did not fail on the transient absence");

                    // A background completion closes the window the way the kernel
                    // would: the content lands back at the path and the backup is
                    // gone. Delayed enough that the recovery reader must actually
                    // wait rather than merely find it already present.
                    var completion = new Thread(() =>
                    {
                        Thread.Sleep(120);
                        File.Move(backup, windowPath);
                    })
                    { IsBackground = true };
                    completion.Start();

                    // The recovery reader waits out the window and reads whole
                    // content rather than throwing.
                    var digest = CanonicalJson.Sha256HexOfFile(windowPath);
                    completion.Join();
                    Require(digest == CanonicalJson.Sha256HexOfText(oldContent),
                        "the recovery reader did not read the whole restored content");
                    Require(File.ReadAllText(windowPath) == oldContent,
                        "the window did not complete to whole content");
                });

                Check("an absence that ended before the reader could look is still recoverable", () =>
                {
                    // The race a hosted runner lost, asked deterministically. A
                    // reader's open fails on the fallback's absence window; by the
                    // instant it asks WHY, the publish has completed and deleted
                    // its named backup, so the only evidence left is that the
                    // destination is there again. Judging that absence by the
                    // backup alone calls a finished publish a missing state file
                    // and turns a survivable read into a hard failure.
                    var settled = Path.Combine(directory, "reader-settled", "state.json");
                    var midSwap = Path.Combine(directory, "reader-midswap", "state.json");
                    var gone = Path.Combine(directory, "reader-gone", "state.json");
                    try
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(settled)!);
                        File.WriteAllText(settled, oldContent);
                        Require(Directory.GetFiles(Path.GetDirectoryName(settled)!, "*.bak").Length == 0,
                            "the settled case was staged with a backup sibling, which is not the case under test");
                        Require(CanonicalJson.PublishInFlight(settled),
                            "an absence whose destination is already back was judged a genuine missing file");

                        // And the two states it must be told apart from: mid-swap,
                        // where the backup is the only evidence, and simply gone.
                        Directory.CreateDirectory(Path.GetDirectoryName(midSwap)!);
                        var midSwapBackup = midSwap + "." + Guid.NewGuid().ToString("N") + ".bak";
                        File.WriteAllText(midSwapBackup, oldContent);
                        Require(CanonicalJson.PublishInFlight(midSwap),
                            "an absence with the fallback's backup beside it was not judged a publish in flight");

                        Directory.CreateDirectory(Path.GetDirectoryName(gone)!);
                        Require(!CanonicalJson.PublishInFlight(gone),
                            "an absence with no publish to explain it was judged recoverable");
                        // A '.bak' belonging to some other file, which the shape-exact
                        // pattern must not read as this file's publish. Named for a
                        // different destination on purpose: 'state.json.<x>.bak' IS
                        // this file's backup shape and would rightly match.
                        File.WriteAllText(Path.Combine(Path.GetDirectoryName(gone)!, "other.json.f00d.bak"), oldContent);
                        Require(!CanonicalJson.PublishInFlight(gone),
                            "an unrelated .bak file turned a genuine absence into a recoverable one");
                    }
                    finally
                    {
                        // These fixtures stage backup siblings deliberately, and a
                        // later check sweeps the whole tree for backups no publish
                        // cleaned up. Taken back out on EVERY path: on the failing
                        // one too, or a failure here is reported a second time as a
                        // publish that leaked a backup, which is a different defect.
                        foreach (var staged in new[] { midSwap, gone })
                        {
                            var stagedDirectory = Path.GetDirectoryName(staged)!;
                            if (Directory.Exists(stagedDirectory))
                            {
                                Directory.Delete(stagedDirectory, recursive: true);
                            }
                        }
                    }
                });

                Check("a genuinely missing state file still fails fast, with no backup sibling to recover from", () =>
                {
                    // The other half of the contract: recovery is ONLY for the
                    // publish window. A path that is simply not there, with no named
                    // backup beside it, must fail on the first look rather than be
                    // retried into a delay that hides a real deletion.
                    var missing = Path.Combine(directory, "reader-missing", "state.json");
                    Directory.CreateDirectory(Path.GetDirectoryName(missing)!);
                    var threw = false;
                    var stopwatch = System.Diagnostics.Stopwatch.StartNew();
                    try
                    {
                        CanonicalJson.Sha256HexOfFile(missing);
                    }
                    catch (FileNotFoundException)
                    {
                        threw = true;
                    }
                    catch (DirectoryNotFoundException)
                    {
                        threw = true;
                    }
                    stopwatch.Stop();
                    Require(threw, "a genuinely missing state file did not fail");
                    Require(stopwatch.ElapsedMilliseconds < 1000,
                        $"a genuinely missing state file was retried for {stopwatch.ElapsedMilliseconds}ms instead of failing fast");
                });

                Check("a reader never observes absence while forced fallbacks publish concurrently", () =>
                {
                    // The integration form: real forced-fallback publishes running
                    // while a reader reads in a tight loop. Every read must land on
                    // whole old or whole new content, and none may throw the absence
                    // the recovery exists to absorb.
                    var racePath = Path.Combine(directory, "reader-race", "state.json");
                    CanonicalJson.WriteFileAtomic(racePath, oldContent);
                    var oldDigest = CanonicalJson.Sha256HexOfText(oldContent);
                    var newDigest = CanonicalJson.Sha256HexOfText(newContent);
                    var stop = new ManualResetEventSlim(false);
                    Exception? readerFault = null;
                    var sawUnexpected = false;
                    var reader = new Thread(() =>
                    {
                        try
                        {
                            while (!stop.IsSet)
                            {
                                var digest = CanonicalJson.Sha256HexOfFile(racePath);
                                if (digest != oldDigest && digest != newDigest)
                                {
                                    sawUnexpected = true;
                                }
                            }
                        }
                        catch (Exception exception)
                        {
                            readerFault = exception;
                        }
                    })
                    { IsBackground = true };
                    reader.Start();
                    for (var i = 0; i < 60; i++)
                    {
                        CanonicalJson.WriteFileAtomic(racePath, i % 2 == 0 ? newContent : oldContent);
                    }
                    stop.Set();
                    reader.Join();
                    Require(readerFault is null,
                        $"the reader faulted across concurrent fallback publishes: {readerFault?.GetType().Name}: {readerFault?.Message}");
                    Require(!sawUnexpected, "the reader observed content that was neither the whole old nor the whole new value");
                });
            }
            finally
            {
                CanonicalJson.ForceReplaceFileFallbackForTests = false;
            }

            // The named backup exists so the old content survives a failed
            // replace. It must not survive anything else: a successful publish
            // that left one behind would accumulate a stale copy of state beside
            // every state file, which is exactly the sort of thing a later reader
            // picks up by mistake. Placed after the forced-fallback group so that
            // it is asserting about a tree in which backups were really created.
            Check("a successful publish leaves no backup copy of the old state behind", () =>
            {
                var leftovers = Directory
                    .EnumerateFiles(directory, "*.bak", SearchOption.AllDirectories)
                    .ToArray();
                Require(
                    leftovers.Length == 0,
                    $"publishing left {leftovers.Length} backup file(s) behind: {string.Join(", ", leftovers)}");
            });
        }
        finally
        {
            CanonicalJson.AtomicPublishAttemptHook = null;
            try { Directory.Delete(directory, recursive: true); } catch (IOException) { }
        }

        log.WriteLine(string.Empty);
        if (_failures > 0)
        {
            log.WriteLine($"FAILED: {_failures} check(s), {_passes} passed.");
            return CoordinatorExitCodes.Contract;
        }
        log.WriteLine($"All {_passes} atomic state publish checks passed.");
        return CoordinatorExitCodes.Ok;
    }
}
