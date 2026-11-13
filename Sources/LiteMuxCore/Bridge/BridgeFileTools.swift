import Foundation

/// An exact-text replacement, planned in LiteMux before anything is written.
public struct EditPlan: Equatable, Sendable {
    public var result: String
    public var count: Int
    /// `@@ 第 N 行` hunks with "- " / "+ " lines and two lines of context.
    public var diff: String

    public static func make(content: String, old: String, new: String, replaceAll: Bool) throws -> EditPlan {
        guard !old.isEmpty else { throw BridgeToolError("old_text 不能为空。") }
        guard old != new else { throw BridgeToolError("old_text 和 new_text 一样，没有要改的。") }
        var ranges: [Range<String.Index>] = []
        var from = content.startIndex
        while from < content.endIndex, let r = content.range(of: old, range: from..<content.endIndex) {
            ranges.append(r)
            from = r.upperBound
        }
        if ranges.isEmpty {
            let hint = old.trimmingCharacters(in: .whitespacesAndNewlines)
            let loose = !hint.isEmpty && content.contains(hint)
            throw BridgeToolError("文件里找不到 old_text" + (loose ? "（去掉首尾空白后能找到，检查缩进和换行）" : "") + "。先用 read_file 看看当前内容，按原样复制要替换的片段。")
        }
        if ranges.count > 1, !replaceAll {
            let lines = ranges.prefix(6).map { "第 \(Self.lineNumber(of: $0.lowerBound, in: content)) 行" }
            throw BridgeToolError("old_text 在文件里出现了 \(ranges.count) 次（\(lines.joined(separator: "、"))）。多带几行上下文让它唯一，或者设 replace_all:true 全部替换。")
        }
        func newlines<S: StringProtocol>(_ s: S) -> Int { s.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } }
        let oldBreaks = newlines(old), newBreaks = newlines(new)
        var result = ""
        var cursor = content.startIndex
        var resultLines = 0
        // (first, last) line of each match in the file and of its replacement in the result, 1-based.
        var spans: [(Int, Int, Int, Int)] = []
        var oldLine = 1
        for r in ranges {
            let gap = content[cursor..<r.lowerBound]
            oldLine += newlines(gap)
            result += gap
            resultLines += newlines(gap)
            spans.append((oldLine, oldLine + oldBreaks, resultLines + 1, resultLines + 1 + newBreaks))
            result += new
            resultLines += newBreaks
            oldLine += oldBreaks
            cursor = r.upperBound
        }
        result += content[cursor...]

        let oldLines = content.components(separatedBy: "\n")
        let newLines = result.components(separatedBy: "\n")
        var hunks: [String] = []
        for (first, last, newFirst, newLast) in spans.prefix(5) {
            let removed = Array(oldLines[(first - 1)..<min(oldLines.count, last)])
            let added = Array(newLines[(newFirst - 1)..<min(newLines.count, newLast)])
            // Lines the match only touched at its edges are not changes.
            var p = 0
            while p < removed.count, p < added.count, removed[p] == added[p] { p += 1 }
            var q = 0
            while q < removed.count - p, q < added.count - p, removed[removed.count - 1 - q] == added[added.count - 1 - q] { q += 1 }
            let start = first - 1 + p, end = last - q
            var hunk = ["@@ 第 \(start + 1) 行"]
            hunk += oldLines[max(0, start - 2)..<start].map { "  " + $0 }
            hunk += Self.clip(Array(removed[p..<(removed.count - q)])).map { "- " + $0 }
            hunk += Self.clip(Array(added[p..<(added.count - q)])).map { "+ " + $0 }
            hunk += oldLines[min(oldLines.count, end)..<min(oldLines.count, end + 2)].map { "  " + $0 }
            hunks.append(hunk.joined(separator: "\n"))
        }
        if ranges.count > 5 { hunks.append("…另外 \(ranges.count - 5) 处") }
        return EditPlan(result: result, count: ranges.count, diff: hunks.joined(separator: "\n"))
    }

    static func lineNumber(of index: String.Index, in s: String) -> Int {
        s[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    static func clip(_ lines: [String]) -> [String] {
        lines.count <= 40 ? lines : Array(lines.prefix(30)) + ["…（省略 \(lines.count - 36) 行）…"] + Array(lines.suffix(6))
    }
}

extension BridgeToolbox {
    var editFile: BridgeTool {
        BridgeTool(
            name: "edit_file", title: "修改文件",
            description: "Change part of a text file on the host by exact replacement: old_text must appear exactly once (include a few lines of context), or set replace_all. The file is edited in place, so its permissions and owner stay, and only if nobody changed it since LiteMux read it. The user sees a red/green diff when asked to approve. Prefer this over write_file for existing files.",
            access: .write,
            inputSchema: Self.schema(["host": Self.hostProperty,
                                      "path": Self.string("File path; may start with ~."),
                                      "old_text": Self.string("The exact text to replace, as read_file shows it."),
                                      "new_text": Self.string("The replacement text (may be empty to delete)."),
                                      "replace_all": Self.boolean("Replace every occurrence (default false).")],
                                     required: ["path", "old_text", "new_text"])
        ) { call in
            let host = try resolveHost(call)
            guard let path = call.string("path") else { throw BridgeToolError("缺少 path。") }
            guard let old = call.rawString("old_text") else { throw BridgeToolError("缺少 old_text。") }
            let new = call.rawString("new_text") ?? ""
            call.summary = path
            let r = try await run(BridgeScripts.readForEdit(path), on: host, limit: BridgeScripts.editLimit + 8192)
            guard r.status == 0 else { throw BridgeToolError(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let marker = Data(("\n" + BridgeScripts.dataMarker + "\n").utf8)
            guard let m = r.stdout.range(of: marker) else { throw BridgeToolError("读取 \(path) 失败。") }
            let checksum = String(decoding: r.stdout[..<m.lowerBound], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let bytes = r.stdout[m.upperBound...]
            if bytes.prefix(8192).contains(0) { throw BridgeToolError("\(path) 是二进制文件，不能按文本修改。") }
            guard let content = String(data: Data(bytes), encoding: .utf8) else {
                throw BridgeToolError("\(path) 不是 UTF-8 文本，不能按文本修改。")
            }
            let plan = try EditPlan.make(content: content, old: old, new: new, replaceAll: call.bool("replace_all", default: false))
            call.summary = "\(path) · \(plan.count) 处"
            try await call.authorize(action: "修改文件", detail: "\(path)（\(plan.count) 处替换）\n────────\n" + plan.diff, isDiff: true)

            let staged = path + ".lm-edit"
            let data = Data(plan.result.utf8)
            var offset = 0
            repeat {
                let chunk = data.subdata(in: offset..<min(data.count, offset + BridgeScripts.writeChunk))
                let w = try await run(BridgeScripts.write(path: staged, chunk: chunk, append: offset > 0), on: host, timeout: 30)
                guard w.status == 0 else { throw BridgeToolError("写入失败：" + w.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
                offset += chunk.count
            } while offset < data.count
            let c = try await run(BridgeScripts.commitEdit(path, staged: staged, checksum: checksum), on: host, timeout: 30)
            if c.out.hasPrefix(BridgeScripts.changedMarker) {
                throw BridgeToolError("没有写入：\(path) 在你读取之后被改过了（可能是用户在编辑器里保存了，或者训练脚本在写它）。重新 read_file 后再改。")
            }
            guard c.status == 0 else { throw BridgeToolError("写入失败：" + c.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return BridgeToolResult("已修改 \(host.title):\(path)，\(plan.count) 处替换（文件现在 \(c.out.trimmingCharacters(in: .whitespacesAndNewlines)) 字节，权限不变）。\n" + plan.diff)
        }
    }

    // MARK: - Transfers

    /// `~`, `~/x`, absolute, or relative to the agent's working directory.
    func localURL(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return URL(fileURLWithPath: localDirectory).appendingPathComponent(expanded).standardizedFileURL
    }

    static func remoteName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if trimmed == "~" || trimmed.isEmpty { return "home" }
        return (trimmed as NSString).lastPathComponent
    }

    static func byteCount(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Size and file count of a local directory tree.
    static func tally(_ url: URL) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let item = e?.nextObject() as? URL {
            let v = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { files += 1; bytes += Int64(v?.fileSize ?? 0) }
        }
        return (files, bytes)
    }

    var downloadFile: BridgeTool {
        BridgeTool(
            name: "download_file", title: "下载到本机",
            description: "Copy a file or a whole folder from the host to this computer (where the agent runs), byte for byte: checkpoints, images, CSVs, result folders. Folders travel as one tar stream and are unpacked at local_path. Nothing is left on the server. Does not change the host.",
            access: .read,
            inputSchema: Self.schema(["host": Self.hostProperty,
                                      "path": Self.string("File or folder on the host; may start with ~."),
                                      "local_path": Self.string("Where to put it on this computer: absolute, ~/…, or relative to the agent's working directory. An existing folder receives the item inside it (like cp). Default: the agent's working directory."),
                                      "overwrite": Self.boolean("Replace an existing local file, or unpack into a non-empty folder (default false)."),
                                      "timeout_seconds": Self.integer("Give up after this many seconds (default 600).", min: 5, max: 7200)],
                                     required: ["path"])
        ) { call in
            let host = try resolveHost(call)
            guard let path = call.string("path") else { throw BridgeToolError("缺少 path。") }
            let overwrite = call.bool("overwrite", default: false)
            let timeout = TimeInterval(call.int("timeout_seconds", default: 600, range: 5...7200))
            call.summary = path
            let info = try await run(BridgeScripts.inspect(path), on: host, timeout: 20)
            guard info.status == 0 else { throw BridgeToolError(info.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let kind = info.out.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDir = kind == "dir"
            let remoteSize = Int64(kind.split(separator: " ").last.map(String.init) ?? "") ?? -1

            let fm = FileManager.default
            let name = Self.remoteName(path)
            // Like cp: an existing folder receives the item inside it.
            var target = localURL(call.string("local_path") ?? ".")
            var isLocalDir: ObjCBool = false
            if fm.fileExists(atPath: target.path, isDirectory: &isLocalDir), isLocalDir.boolValue {
                target.appendPathComponent(name)
            }
            let exists = fm.fileExists(atPath: target.path, isDirectory: &isLocalDir)
            if exists, !overwrite {
                let nonEmpty = isLocalDir.boolValue ? !((try? fm.contentsOfDirectory(atPath: target.path))?.isEmpty ?? true) : true
                if nonEmpty || !isDir {
                    throw BridgeToolError("本机已经有 \(target.path)。设 overwrite:true 覆盖，或者换个 local_path。")
                }
            }
            if exists, isDir != isLocalDir.boolValue {
                throw BridgeToolError("本机的 \(target.path) 是\(isLocalDir.boolValue ? "文件夹" : "文件")，和远端类型不同。换个 local_path。")
            }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            call.summary = "\(path) → \(target.path)"

            let part = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).lm-part\(isDir ? ".tgz" : "")")
            defer { try? fm.removeItem(at: part) }
            let r = await shell.stream(BridgeScripts.download(path, directory: isDir), on: host, input: nil, output: part, timeout: timeout)
            if r.timedOut { throw BridgeToolError("下载 \(path) 超过 \(Int(timeout)) 秒，已停止。可以调大 timeout_seconds。") }
            guard r.status == 0 else {
                throw BridgeToolError("下载失败（退出码 \(r.status)）：" + r.err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let got = ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
            if isDir {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                let x = await ProcessBridgeShell.execute("/usr/bin/tar", ["-xzf", part.path, "-C", target.path], environment: nil,
                                                         directory: nil, stdin: nil, timeout: max(60, timeout), outputLimit: 16_000)
                guard x.status == 0 else { throw BridgeToolError("解包失败：" + x.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let t = Self.tally(target)
                return BridgeToolResult("已把 \(host.title):\(path) 下载到 \(target.path)（\(t.files) 个文件，共 \(Self.byteCount(t.bytes))，传输 \(Self.byteCount(got)) 压缩包，\(String(format: "%.1f", r.duration)) 秒）。")
            }
            if remoteSize >= 0, got != remoteSize {
                throw BridgeToolError("下载不完整：收到 \(got) 字节，远端文件有 \(remoteSize) 字节（可能在下载时还在被写入）。")
            }
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            do { try fm.moveItem(at: part, to: target) } catch { throw BridgeToolError("保存到 \(target.path) 失败：\(error.localizedDescription)") }
            return BridgeToolResult("已把 \(host.title):\(path) 下载到 \(target.path)（\(Self.byteCount(got))，\(String(format: "%.1f", r.duration)) 秒）。")
        }
    }

    var uploadFile: BridgeTool {
        BridgeTool(
            name: "upload_file", title: "上传到主机",
            description: "Copy a file or a whole folder from this computer (where the agent runs) to the host, byte for byte: datasets, weights, scripts. Folders travel as one tar stream. A path ending in / receives the item inside it. Requires the user's approval in LiteMux unless they trust the agent.",
            access: .write,
            inputSchema: Self.schema(["host": Self.hostProperty,
                                      "local_path": Self.string("File or folder on this computer: absolute, ~/…, or relative to the agent's working directory."),
                                      "path": Self.string("Destination on the host; may start with ~. Ends with / to put the item inside that folder."),
                                      "timeout_seconds": Self.integer("Give up after this many seconds (default 600).", min: 5, max: 7200)],
                                     required: ["local_path", "path"])
        ) { call in
            let host = try resolveHost(call)
            guard let localRaw = call.string("local_path") else { throw BridgeToolError("缺少 local_path。") }
            guard var path = call.string("path") else { throw BridgeToolError("缺少 path。") }
            let timeout = TimeInterval(call.int("timeout_seconds", default: 600, range: 5...7200))
            let fm = FileManager.default
            let local = localURL(localRaw)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: local.path, isDirectory: &isDir) else { throw BridgeToolError("本机没有 \(local.path)。") }
            if path.hasSuffix("/") { path += local.lastPathComponent }
            let size: Int64 = isDir.boolValue ? Self.tally(local).bytes
                : ((try? fm.attributesOfItem(atPath: local.path))?[.size] as? NSNumber)?.int64Value ?? 0
            call.summary = "\(local.path) → \(path)"
            let what = isDir.boolValue ? "文件夹（\(Self.tally(local).files) 个文件，\(Self.byteCount(size))）" : "文件（\(Self.byteCount(size))）"
            try await call.authorize(action: isDir.boolValue ? "上传文件夹" : "上传文件",
                                     detail: "本机 \(local.path)\n→ \(host.title):\(path)\n\(what)，同名文件会被覆盖")

            var input = local
            var bundle: URL?
            if isDir.boolValue {
                let tgz = fm.temporaryDirectory.appendingPathComponent("litemux-upload-\(UUID().uuidString).tgz")
                bundle = tgz
                var env = ProcessInfo.processInfo.environment
                env["COPYFILE_DISABLE"] = "1"
                let t = await ProcessBridgeShell.execute("/usr/bin/tar", ["-czf", tgz.path, "-C", local.path, "."], environment: env,
                                                         directory: nil, stdin: nil, timeout: max(60, timeout), outputLimit: 16_000)
                guard t.status == 0 else {
                    try? fm.removeItem(at: tgz)
                    throw BridgeToolError("打包失败：" + t.err.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                input = tgz
            }
            defer { if let bundle { try? fm.removeItem(at: bundle) } }
            let r = await shell.stream(BridgeScripts.upload(path, directory: isDir.boolValue), on: host, input: input, output: nil, timeout: timeout)
            if r.timedOut { throw BridgeToolError("上传超过 \(Int(timeout)) 秒，已停止。可以调大 timeout_seconds。") }
            guard r.status == 0 else {
                throw BridgeToolError("上传失败（退出码 \(r.status)）：" + r.err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let remote = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isDir.boolValue, let n = Int64(remote), n != size {
                throw BridgeToolError("上传不完整：远端收到 \(n) 字节，本机文件有 \(size) 字节。")
            }
            return BridgeToolResult("已把 \(local.path) 上传到 \(host.title):\(path)（\(Self.byteCount(size))，\(String(format: "%.1f", r.duration)) 秒）。")
        }
    }
}
