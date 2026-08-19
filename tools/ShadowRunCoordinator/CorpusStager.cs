using System.Globalization;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// The durable note that says a staging directory exists and who owns it.
/// </summary>
/// <remarks>
/// Written BEFORE the directory it names, and removed only once the corpus has
/// been published. That ordering is the whole point: a coordinator killed at any
/// instant leaves either no journal and no directory, or a journal naming a
/// directory that may be complete, partial or absent - and in every one of those
/// cases the next run can tell whether the leftovers are its own. A run that
/// could not tell would have to choose between deleting somebody else's
/// directory and leaving its own forever, and both are wrong.
///
/// It carries no signature. The signed state record is what says how far the run
/// got; this says only which scratch directory this run is entitled to remove,
/// and it lives inside a coordinator root a run lease already makes exclusive.
/// </remarks>
internal sealed record CorpusStageJournal
{
    internal const string ContractVersionValue = "devpilot.shadow-run-coordinator.corpus-stage-journal.v1";
    internal const string KindValue = "shadow-run-corpus-stage-journal";

    internal required string CorrelationId { get; init; }

    internal required string RequestSha256 { get; init; }

    internal required string StageRequestSha256 { get; init; }

    internal required string StagingDirectory { get; init; }

    internal required string CorpusRoot { get; init; }

    internal required string OpenedAtUtc { get; init; }

    internal MapNode Compose() => new MapNode()
        .Set("contractVersion", ContractVersionValue)
        .Set("kind", KindValue)
        .Set("correlationId", CorrelationId)
        .Set("requestSha256", RequestSha256)
        .Set("stageRequestSha256", StageRequestSha256)
        .Set("stagingDirectory", StagingDirectory)
        .Set("corpusRoot", CorpusRoot)
        .Set("openedAtUtc", OpenedAtUtc);

    internal static CorpusStageJournal Read(string path)
    {
        const string label = "corpus stage journal";
        var root = StrictJson.ReadObjectFile(path, label);
        StrictJson.RequireNoUnknownFields(
            root,
            label,
            "contractVersion",
            "kind",
            "correlationId",
            "requestSha256",
            "stageRequestSha256",
            "stagingDirectory",
            "corpusRoot",
            "openedAtUtc");
        StrictJson.RequireLiteral(root, "contractVersion", ContractVersionValue, label);
        StrictJson.RequireLiteral(root, "kind", KindValue, label);
        return new CorpusStageJournal
        {
            CorrelationId = StrictJson.RequireString(root, "correlationId", label),
            RequestSha256 = StrictJson.RequireHex(root, "requestSha256", label, 64),
            StageRequestSha256 = StrictJson.RequireHex(root, "stageRequestSha256", label, 64),
            StagingDirectory = StrictJson.RequireString(root, "stagingDirectory", label),
            CorpusRoot = StrictJson.RequireString(root, "corpusRoot", label),
            OpenedAtUtc = StrictJson.RequireString(root, "openedAtUtc", label)
        };
    }
}

/// <summary>
/// Builds one corpus from immutable declared inputs, and publishes it in a
/// single filesystem operation.
/// </summary>
/// <remarks>
/// The sequence is fixed and every step of it is a refusal rather than a repair.
///
/// Read only from the sources. Nothing here opens a declared source for write,
/// changes an attribute on one, or deletes one, so a read-only or otherwise
/// immutable source corpus is a perfectly ordinary input rather than the failure
/// it used to be.
///
/// Build from nothing. The staging directory is created empty beside the
/// destination, on the same volume so that publication can be a move rather than
/// a copy, and every byte in it is written by this run.
///
/// Witness first. The identity witness is the first file written, so a staging
/// directory that exists at all already says which subject it is for. The old
/// private path wrote the witness LAST, by overwriting an inherited one, which
/// is how it managed to produce a corpus whose identity was whatever it had
/// copied.
///
/// Index last. The index is generated from the declaration after every payload
/// is on disk and re-read, so an index can never describe a file that was not
/// written.
///
/// Publish atomically. A directory move into a destination that must not exist
/// is what makes two concurrent builders resolve to exactly one winner without
/// either of them inspecting the other.
/// </remarks>
internal sealed class CorpusStager(CoordinatorRequest request, CorpusStageRequest stage, TextWriter log)
{
    private readonly CoordinatorRequest _request = request;
    private readonly CorpusStageRequest _stage = stage;
    private readonly TextWriter _log = log;

    /// <summary>The journal's fixed name inside the coordinator root the run lease owns.</summary>
    private const string JournalName = "corpus-stage.journal.json";

    /// <summary>The published stage result's fixed name.</summary>
    private const string ResultName = "corpus-stage.result.json";

    internal const string ResultContractVersionValue = "devpilot.shadow-run-coordinator.corpus-stage-result.v1";
    internal const string ResultKindValue = "shadow-run-corpus-stage-result";

    private string JournalPath => Path.Combine(_request.CoordinatorRoot, JournalName);

    internal string ResultPath => Path.Combine(_request.CoordinatorRoot, ResultName);

    /// <summary>
    /// Checks the declaration against the request that carries it.
    /// </summary>
    /// <remarks>
    /// The stage declaration and the coordinator request are two files, and two
    /// files can disagree. Every field they both carry is compared here rather
    /// than trusted from whichever was read second, because a corpus staged for
    /// one subject and validated as another is precisely the fault that a
    /// separate identity witness exists to make impossible.
    /// </remarks>
    internal void RequireAgreementWithRequest()
    {
        Require(_stage.CorrelationId, _request.CorrelationId, "correlationId");
        Require(_stage.ToolkitHead, _request.ToolkitHead, "toolkitHead");
        RequirePath(_stage.OutputRoot, _request.OutputRoot, "target.outputRoot", "output.root");
        RequirePath(_stage.CorpusRoot, _request.CorpusRoot, "target.corpusRoot", "corpus.root");
        Require(_stage.IndexSha256, _request.CorpusIndexSha256, "target.indexSha256");

        var expectedRepository = $"{_request.Organization}/{_request.Project}/{_request.Repository}";
        Require(_stage.Identity.Repository, expectedRepository, "identity.repository");
        RequireNumber(_stage.Identity.PullRequestId, _request.PullRequestId, "identity.pullRequestId");
        RequireNumber(_stage.Identity.IterationId, _request.IterationId, "identity.iterationId");
        Require(_stage.Identity.SourceCommit, _request.SourceCommit, "identity.sourceCommit");
        Require(_stage.Identity.CommonCommit, _request.CommonCommit, "identity.commonCommit");
        Require(_stage.Identity.TargetCommit, _request.TargetCommit, "identity.targetCommit");
    }

    private static void Require(string actual, string expected, string field)
    {
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The corpus stage request field '{field}' is '{actual}' and the coordinator request binds '{expected}'.");
        }
    }

    private static void RequireNumber(int actual, int expected, string field)
    {
        if (actual != expected)
        {
            throw new ContractException(
                $"The corpus stage request field '{field}' is {actual.ToString(CultureInfo.InvariantCulture)} and the coordinator request binds {expected.ToString(CultureInfo.InvariantCulture)}.");
        }
    }

    /// <summary>
    /// Compares two paths as the filesystem would, so that a declaration cannot
    /// disagree with the request merely by spelling a directory differently.
    /// </summary>
    private static void RequirePath(string actual, string expected, string field, string counterpart)
    {
        if (!string.Equals(Path.GetFullPath(actual), Path.GetFullPath(expected), StringComparison.OrdinalIgnoreCase))
        {
            throw new ContractException(
                $"The corpus stage request field '{field}' names '{actual}' and the coordinator request's '{counterpart}' names '{expected}'.");
        }
    }

    /// <summary>
    /// Assembles the corpus in a fresh staging directory and returns what was
    /// built. Nothing is published here.
    /// </summary>
    internal (MapNode Evidence, string Detail) Stage()
    {
        var destination = Path.GetFullPath(_stage.CorpusRoot);
        var parent = Path.GetDirectoryName(destination);
        if (string.IsNullOrEmpty(parent))
        {
            throw new ContractException($"The corpus root '{destination}' has no parent directory to stage beside.");
        }
        if (!Directory.Exists(parent))
        {
            throw new ContractException($"The corpus root's parent '{parent}' does not exist; this stager creates the corpus, not the tree it lives in.");
        }
        RequireNotReparsePoint(parent, "the corpus root's parent directory");
        if (Directory.Exists(destination) || File.Exists(destination))
        {
            throw new ContractException(
                $"'{destination}' already exists. A staged corpus is built at a path that does not exist, so that publication cannot overwrite, merge into, or inherit anything from a previous one.");
        }

        DiscardOwnedIncompleteStaging();

        // Beside the destination, therefore on the destination's volume: the
        // publication below is a directory MOVE, and a move across volumes is a
        // copy that can be observed half-done.
        var staging = Path.Combine(parent, ".corpus-staging-" + _request.CorrelationId + "-" + Guid.NewGuid().ToString("N"));
        if (Directory.Exists(staging) || File.Exists(staging))
        {
            throw new ContractException($"The staging directory '{staging}' already exists.");
        }

        // The note comes before the directory, so there is no instant at which a
        // staging directory exists that no journal claims.
        WriteJournal(new CorpusStageJournal
        {
            CorrelationId = _request.CorrelationId,
            RequestSha256 = _request.RequestSha256,
            StageRequestSha256 = _stage.RequestSha256,
            StagingDirectory = staging,
            CorpusRoot = destination,
            OpenedAtUtc = DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture)
        });

        try
        {
            Directory.CreateDirectory(staging);
            _log.WriteLine($"corpus-stage staging={staging}");

            var witness = _stage.Payloads.Single(payload => payload.Role == CorpusPayloadRole.IdentityWitness);
            var witnessDigest = StagePayload(staging, witness);
            _log.WriteLine($"corpus-stage witness={witness.Path} sha256={witnessDigest}");

            foreach (var payload in _stage.Payloads)
            {
                if (ReferenceEquals(payload, witness))
                {
                    continue;
                }
                StagePayload(staging, payload);
            }

            // Generated last, from the declaration, and only after every payload
            // it names is on disk and has been read back.
            var indexText = _stage.RenderIndex();
            var indexBytes = StrictJson.StrictUtf8.GetBytes(indexText);
            var indexPath = Path.Combine(staging, CorpusStageRequest.IndexFileName);
            WriteNewFile(indexPath, indexBytes);
            var indexDigest = CanonicalJson.Sha256HexOfFile(indexPath);
            if (!string.Equals(indexDigest, _stage.IndexSha256, StringComparison.Ordinal))
            {
                throw new ContractException(
                    $"The generated corpus index digests to {indexDigest} and the stage request declared {_stage.IndexSha256}. " +
                    "The declaration and the corpus it describes are not the same corpus.");
            }

            ValidateStagedTree(staging, indexDigest, indexBytes.Length);

            var evidence = new MapNode()
                .Set("stagingDirectory", staging)
                .Set("corpusRoot", destination)
                .Set("corpusKind", _stage.CorpusKind)
                .Set("stageRequestSha256", _stage.RequestSha256)
                .Set("indexSha256", indexDigest)
                .Set("identityWitnessPath", witness.Path)
                .Set("identityWitnessSha256", witnessDigest)
                .Set("payloadCount", _stage.Payloads.Count)
                .Set("stagedFileCount", _stage.Payloads.Count + 1)
                .Set("published", false)
                .Set("payloads", _stage.DescribePayloads());
            return (evidence, $"staged={_stage.Payloads.Count.ToString(CultureInfo.InvariantCulture)} index={indexDigest[..12]}");
        }
        catch
        {
            // Only ever the directory this run's own journal names. A failure is
            // not a licence to tidy up somebody else's work, and the destination
            // is never touched here because nothing has been published yet.
            DiscardOwnedIncompleteStaging();
            throw;
        }
    }

    /// <summary>
    /// Moves the staged corpus onto its published path, then makes it read-only.
    /// </summary>
    /// <remarks>
    /// Re-entrant on purpose. A run killed between the move and the read-only
    /// pass, or between the read-only pass and its own state commit, resumes into
    /// this method and finds the corpus already at its destination; it verifies
    /// that what is there is what it staged and finishes the job, rather than
    /// staging a second copy or refusing forever.
    /// </remarks>
    internal (MapNode Evidence, string Detail) Publish(MapNode stagedEvidence)
    {
        var destination = Path.GetFullPath(_stage.CorpusRoot);
        var staging = stagedEvidence.GetText("stagingDirectory")
            ?? throw new ContractException("The committed staging record names no staging directory to publish.");
        var stagedIndexDigest = stagedEvidence.GetText("indexSha256")
            ?? throw new ContractException("The committed staging record names no index digest to publish against.");

        var moved = false;
        if (Directory.Exists(destination))
        {
            // Already published, or somebody else got here first. Which of those
            // it is, is decided by the index digest this run committed - not by
            // the fact that a directory exists.
            var standing = Path.Combine(destination, CorpusStageRequest.IndexFileName);
            if (!File.Exists(standing))
            {
                // This run has just proven it will never publish, so it has no
                // further claim on the copy it staged.
                DiscardOwnedIncompleteStagingBeforeRefusal();
                throw new ContractException(
                    $"'{destination}' exists and holds no {CorpusStageRequest.IndexFileName}. It is not this run's published corpus and it is not empty, so nothing is written into it.");
            }
            var standingDigest = CanonicalJson.Sha256HexOfFile(standing);
            if (!string.Equals(standingDigest, stagedIndexDigest, StringComparison.Ordinal))
            {
                DiscardOwnedIncompleteStagingBeforeRefusal();
                throw new ContractException(
                    $"'{destination}' already holds a corpus whose index digests to {standingDigest}, and this run staged {stagedIndexDigest}. " +
                    "A published corpus is never replaced, merged into, or written over.");
            }
            _log.WriteLine($"corpus-publish already-present destination={destination}");

            // This run staged a corpus it did not have to publish, either because
            // it had already published it or because a concurrent builder won the
            // move. Either way the scratch copy is this run's own and will never
            // be published, so it is removed here rather than left behind for
            // nobody to claim.
            DiscardOwnedIncompleteStaging();
        }
        else
        {
            if (!Directory.Exists(staging))
            {
                throw new ContractException(
                    $"The staging directory '{staging}' this run committed is gone and '{destination}' does not exist, so there is nothing to publish and nothing was published.");
            }
            try
            {
                Directory.Move(staging, destination);
                moved = true;
            }
            catch (IOException error)
            {
                // The destination appeared between the check and the move, so
                // this run's staged copy is now unpublishable. It is this run's
                // own directory, named by this run's own journal, so it goes.
                DiscardOwnedIncompleteStaging();
                throw new ContractException(
                    $"Publishing '{staging}' to '{destination}' failed: {error.Message}. " +
                    "A destination that appeared between the check and the move is another builder's corpus, and this run publishes nothing over it.");
            }
            _log.WriteLine($"corpus-publish moved destination={destination}");
        }

        // Verified after the move rather than before it, because what matters is
        // what is at the destination now.
        var publishedIndex = Path.Combine(destination, CorpusStageRequest.IndexFileName);
        var publishedDigest = CanonicalJson.Sha256HexOfFile(publishedIndex);
        if (!string.Equals(publishedDigest, _stage.IndexSha256, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The published corpus index at '{publishedIndex}' digests to {publishedDigest} and the stage request declared {_stage.IndexSha256}.");
        }
        var readOnlyCount = MakeReadOnly(destination);

        var result = new MapNode()
            .Set("contractVersion", ResultContractVersionValue)
            .Set("kind", ResultKindValue)
            .Set("correlationId", _request.CorrelationId)
            .Set("stageRequestSha256", _stage.RequestSha256)
            .Set("corpusRoot", destination)
            .Set("corpusKind", _stage.CorpusKind)
            .Set("indexSha256", publishedDigest)
            .Set("payloadCount", _stage.Payloads.Count)
            .Set("readOnlyFileCount", readOnlyCount)
            .Set("identityWitnessPath", _stage.Identity.WitnessPath)
            .Set("publishedAtUtc", DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture));
        CanonicalJson.WriteFileAtomic(ResultPath, CanonicalJson.Readable(result));

        // The journal's only job was to say which scratch directory this run
        // owned. There is no scratch directory any more.
        if (File.Exists(JournalPath))
        {
            File.Delete(JournalPath);
        }

        var evidence = new MapNode()
            .Set("corpusRoot", destination)
            .Set("corpusKind", _stage.CorpusKind)
            .Set("stageRequestSha256", _stage.RequestSha256)
            .Set("indexSha256", publishedDigest)
            .Set("payloadCount", _stage.Payloads.Count)
            .Set("readOnlyFileCount", readOnlyCount)
            .Set("movedByThisRun", moved)
            .Set("resultPath", ResultPath)
            .Set("published", true);
        return (evidence, $"published={destination} readOnly={readOnlyCount.ToString(CultureInfo.InvariantCulture)}");
    }

    /// <summary>
    /// Re-reads a staging directory a previous process built, so a resumed run
    /// publishes the corpus its own record was committed against.
    /// </summary>
    internal void RecheckStaged(MapNode stagedEvidence)
    {
        var staging = stagedEvidence.GetText("stagingDirectory");
        var digest = stagedEvidence.GetText("indexSha256");
        if (staging is not { Length: > 0 } || digest is not { Length: > 0 })
        {
            throw new ContractException("The committed staging record is missing the staging directory or the index digest it staged.");
        }
        if (!Directory.Exists(staging))
        {
            // Legitimate after publication: the directory was moved, not lost.
            // The publish step is what decides whether the destination is this
            // run's corpus, so nothing is concluded here.
            return;
        }
        var indexPath = Path.Combine(staging, CorpusStageRequest.IndexFileName);
        if (!File.Exists(indexPath))
        {
            throw new ContractException($"The staging directory '{staging}' this run committed no longer holds a corpus index.");
        }
        var actual = CanonicalJson.Sha256HexOfFile(indexPath);
        if (!string.Equals(actual, digest, StringComparison.Ordinal))
        {
            throw new ContractException($"The staged corpus index at '{indexPath}' digests to {actual} and this run committed {digest}.");
        }
        ValidateStagedTree(staging, actual, new FileInfo(indexPath).Length);
    }

    /// <summary>
    /// Discards this run's staging directory on a path that is already failing,
    /// leaving the failure that got here as the refusal the caller reports.
    /// </summary>
    /// <remarks>
    /// A journal that turns out to belong to another request is itself a refusal,
    /// but it is a less informative one than the refusal already in flight, and
    /// raising it here would replace "the destination holds a different corpus"
    /// with "the journal is not yours". Nothing is swallowed: the caller throws
    /// on the next line either way.
    /// </remarks>
    private void DiscardOwnedIncompleteStagingBeforeRefusal()
    {
        try
        {
            DiscardOwnedIncompleteStaging();
        }
        catch (ContractException error)
        {
            _log.WriteLine($"corpus-stage leaving unowned staging in place: {error.Message}");
        }
    }

    /// <summary>
    /// Removes a staging directory this run's own journal claims, and nothing
    /// else. A journal that belongs to another request is a refusal.
    /// </summary>
    private void DiscardOwnedIncompleteStaging()
    {
        if (!File.Exists(JournalPath))
        {
            return;
        }
        var journal = CorpusStageJournal.Read(JournalPath);
        var mine = string.Equals(journal.CorrelationId, _request.CorrelationId, StringComparison.Ordinal)
            && string.Equals(journal.RequestSha256, _request.RequestSha256, StringComparison.Ordinal)
            && string.Equals(journal.StageRequestSha256, _stage.RequestSha256, StringComparison.Ordinal);
        if (!mine)
        {
            throw new ContractException(
                $"The corpus stage journal at '{JournalPath}' was opened by correlation '{journal.CorrelationId}' for a different request, " +
                "so the staging directory it names is not this run's to remove. Use a fresh output root.");
        }
        if (Directory.Exists(journal.StagingDirectory))
        {
            _log.WriteLine($"corpus-stage discarding owned incomplete staging {journal.StagingDirectory}");
            DeleteTree(journal.StagingDirectory);
        }
        File.Delete(JournalPath);
    }

    private void WriteJournal(CorpusStageJournal journal) =>
        CanonicalJson.WriteFileAtomic(JournalPath, CanonicalJson.Readable(journal.Compose()));

    /// <summary>
    /// Reads one declared source and writes it into the staging directory, with
    /// the declaration checked against the bytes on both sides of the copy.
    /// </summary>
    /// <remarks>
    /// The digest that is compared against the declaration is computed over the
    /// bytes this method actually read, not over a separate pass across the file.
    /// A source rewritten between a hash and a read would otherwise pass the hash
    /// and stage the other content; here there is only one read, and the bytes
    /// that were staged are the bytes that were checked.
    /// </remarks>
    private string StagePayload(string staging, CorpusPayloadDeclaration payload)
    {
        var source = payload.SourcePath;
        if (!File.Exists(source))
        {
            throw new ContractException($"The declared source '{source}' for corpus payload '{payload.Path}' does not exist.");
        }
        RequireNotReparsePoint(source, $"the declared source for corpus payload '{payload.Path}'");

        byte[] bytes;
        using (var stream = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            if (stream.Length != payload.Length)
            {
                throw new ContractException(
                    $"The declared source '{source}' for corpus payload '{payload.Path}' is {stream.Length.ToString(CultureInfo.InvariantCulture)} bytes and the declaration says {payload.Length.ToString(CultureInfo.InvariantCulture)}.");
            }
            bytes = new byte[payload.Length];
            var read = 0;
            while (read < bytes.Length)
            {
                var got = stream.Read(bytes, read, bytes.Length - read);
                if (got <= 0)
                {
                    throw new ContractException(
                        $"The declared source '{source}' for corpus payload '{payload.Path}' ended after {read.ToString(CultureInfo.InvariantCulture)} of {payload.Length.ToString(CultureInfo.InvariantCulture)} bytes.");
                }
                read += got;
            }
            if (stream.ReadByte() != -1)
            {
                throw new ContractException(
                    $"The declared source '{source}' for corpus payload '{payload.Path}' grew while it was being read; a source corpus is immutable for the duration of a staging.");
            }
        }

        var digest = CanonicalJson.Sha256Hex(bytes);
        if (!string.Equals(digest, payload.Sha256, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The declared source '{source}' for corpus payload '{payload.Path}' digests to {digest} and the declaration says {payload.Sha256}.");
        }
        if (payload.Form == CorpusPayloadForm.Utf8Text)
        {
            RequireTextualContract(bytes, payload);
        }

        var target = ResolveStagedPath(staging, payload.Path);
        var directory = Path.GetDirectoryName(target)!;
        Directory.CreateDirectory(directory);
        WriteNewFile(target, bytes);

        // Read back through the filesystem rather than trusted from memory. This
        // is what turns a short write, a full disk or a filter that rewrote the
        // bytes into a refusal instead of a corpus that merely claims a digest.
        var written = new FileInfo(target);
        if (written.Length != payload.Length)
        {
            throw new ContractException(
                $"Corpus payload '{payload.Path}' was written as {written.Length.ToString(CultureInfo.InvariantCulture)} bytes and the declaration says {payload.Length.ToString(CultureInfo.InvariantCulture)}.");
        }
        var writtenDigest = CanonicalJson.Sha256HexOfFile(target);
        if (!string.Equals(writtenDigest, payload.Sha256, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"Corpus payload '{payload.Path}' reads back as {writtenDigest} and the declaration says {payload.Sha256}.");
        }
        return writtenDigest;
    }

    /// <summary>
    /// Applies the textual half of the stage file contract to a payload that
    /// declared itself textual.
    /// </summary>
    /// <remarks>
    /// Binary payloads are deliberately exempt and are never decoded: a PNG that
    /// happens to hold the byte order mark sequence is not a mis-encoded text
    /// file, and a stager that "fixed" it would corrupt evidence. Which of the
    /// two a payload is, is declared rather than sniffed.
    /// </remarks>
    private static void RequireTextualContract(byte[] bytes, CorpusPayloadDeclaration payload)
    {
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
        {
            throw new ContractException(
                $"The declared source for corpus payload '{payload.Path}' starts with a UTF-8 byte order mark, and the payload is declared textual; the contract is UTF-8 without one.");
        }
        try
        {
            _ = StrictJson.StrictUtf8.GetString(bytes);
        }
        catch (System.Text.DecoderFallbackException error)
        {
            throw new ContractException(
                $"The declared source for corpus payload '{payload.Path}' is declared textual and is not valid UTF-8: {error.Message}");
        }
    }

    /// <summary>
    /// Joins a corpus-relative path onto the staging root and proves the result
    /// is still inside it.
    /// </summary>
    /// <remarks>
    /// The path shape was already checked when the declaration was read, so this
    /// is the second of two independent guards rather than the only one. It stays
    /// because containment is the property that actually matters, and a property
    /// that matters is checked where it is relied on.
    /// </remarks>
    private static string ResolveStagedPath(string staging, string relative)
    {
        var root = Path.GetFullPath(staging);
        var combined = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
        var prefix = root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar;
        if (!combined.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new ContractException($"Corpus payload '{relative}' resolves to '{combined}', which is outside the staging directory '{root}'.");
        }
        return combined;
    }

    /// <summary>
    /// Writes a file that must not already exist, and flushes it before
    /// returning. CreateNew is what makes a duplicated write a refusal rather
    /// than a silent overwrite.
    /// </summary>
    private static void WriteNewFile(string path, byte[] bytes)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush(flushToDisk: true);
        }
        catch (IOException) when (File.Exists(path))
        {
            throw new ContractException($"'{path}' was already written during this staging; a corpus path is staged exactly once.");
        }
    }

    /// <summary>
    /// Walks the finished staging tree and proves it is exactly the corpus that
    /// was declared - no extra file, no missing file, no link, nothing renamed.
    /// </summary>
    private void ValidateStagedTree(string staging, string indexDigest, long indexLength)
    {
        var root = Path.GetFullPath(staging);
        RequireNotReparsePoint(root, "the staging directory");
        foreach (var directory in Directory.EnumerateDirectories(root, "*", SearchOption.AllDirectories))
        {
            RequireNotReparsePoint(directory, $"the staged directory '{Relative(root, directory)}'");
        }

        var expected = new Dictionary<string, CorpusPayloadDeclaration>(StringComparer.Ordinal);
        foreach (var payload in _stage.Payloads)
        {
            expected[payload.Path] = payload;
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            RequireNotReparsePoint(file, $"the staged file '{Relative(root, file)}'");
            var relative = Relative(root, file);
            if (string.Equals(relative, CorpusStageRequest.IndexFileName, StringComparison.Ordinal))
            {
                var actualIndex = new FileInfo(file);
                if (actualIndex.Length != indexLength || !string.Equals(CanonicalJson.Sha256HexOfFile(file), indexDigest, StringComparison.Ordinal))
                {
                    throw new ContractException($"The staged corpus index at '{file}' is not the index this run generated.");
                }
                continue;
            }
            if (!expected.TryGetValue(relative, out var declaration))
            {
                throw new ContractException(
                    $"The staging directory holds '{relative}', which the stage request never declared. A corpus carries what was declared and nothing else.");
            }
            if (!seen.Add(relative))
            {
                throw new ContractException($"The staging directory holds '{relative}' more than once.");
            }
            var info = new FileInfo(file);
            if (info.Length != declaration.Length)
            {
                throw new ContractException(
                    $"The staged '{relative}' is {info.Length.ToString(CultureInfo.InvariantCulture)} bytes and the declaration says {declaration.Length.ToString(CultureInfo.InvariantCulture)}.");
            }
            var digest = CanonicalJson.Sha256HexOfFile(file);
            if (!string.Equals(digest, declaration.Sha256, StringComparison.Ordinal))
            {
                throw new ContractException($"The staged '{relative}' digests to {digest} and the declaration says {declaration.Sha256}.");
            }
        }

        foreach (var declaration in _stage.Payloads)
        {
            if (!seen.Contains(declaration.Path))
            {
                throw new ContractException($"The stage request declared '{declaration.Path}' and the staging directory does not hold it.");
            }
        }
    }

    private static string Relative(string root, string path) =>
        Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');

    /// <summary>
    /// The policy that a published corpus is not writable.
    /// </summary>
    /// <remarks>
    /// Applied AFTER publication, never to a source and never during staging. A
    /// staged file made read-only before the move would be read-only for the
    /// verification pass that still has to read it back, and a source made
    /// read-only would be this stager mutating an input.
    /// </remarks>
    private static int MakeReadOnly(string root)
    {
        var count = 0;
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            var attributes = File.GetAttributes(file);
            if (!attributes.HasFlag(FileAttributes.ReadOnly))
            {
                File.SetAttributes(file, attributes | FileAttributes.ReadOnly);
            }
            count++;
        }
        return count;
    }

    private static void RequireNotReparsePoint(string path, string label)
    {
        var attributes = File.GetAttributes(path);
        if (attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            throw new ContractException($"'{path}' is a reparse point, and {label} may not redirect somewhere else.");
        }
    }

    /// <summary>
    /// Removes a staging tree this run owns, clearing the read-only attribute
    /// only on files inside it.
    /// </summary>
    private static void DeleteTree(string root)
    {
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            var attributes = File.GetAttributes(file);
            if (attributes.HasFlag(FileAttributes.ReadOnly))
            {
                File.SetAttributes(file, attributes & ~FileAttributes.ReadOnly);
            }
        }
        Directory.Delete(root, recursive: true);
    }
}
