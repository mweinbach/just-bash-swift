import Foundation
import JavaScriptCore
import JustBashFS

/// Installs the synchronous subset of Node's `fs` module backed by the bash
/// `BashFilesystem`. The async `.promises.*` variants resolve immediately by
/// invoking the same sync implementations.
///
/// Coverage parity target: `worker.ts:432-542` from upstream.
func installFSBridge(into context: JSContext, execution: JSCExecutionContext) {
    let fs = JSValue(newObjectIn: context)!

    func resolveSymlinkPath(_ path: String, relativeTo cwd: String, depth: Int = 0) -> String {
        guard depth < 40 else {
            return execution.cmdCtx.fileSystem.normalizePath(path, relativeTo: cwd)
        }
        let normalized = execution.cmdCtx.fileSystem.normalizePath(path, relativeTo: cwd)
        if normalized == "/" {
            return normalized
        }

        let components = VirtualPath.components(for: normalized)
        var current = ""
        for index in components.indices {
            current = current.isEmpty ? "/\(components[index])" : "\(current)/\(components[index])"
            guard
                let info = try? execution.cmdCtx.fileSystem.fileInfo(path: current, relativeTo: "/"),
                info.kind == .symlink,
                let target = try? execution.cmdCtx.fileSystem.readlink(current, relativeTo: "/")
            else {
                continue
            }

            let targetPath = execution.cmdCtx.fileSystem.normalizePath(target, relativeTo: VirtualPath.dirname(current))
            let remaining = components[(index + 1)...].joined(separator: "/")
            let nextPath = remaining.isEmpty ? targetPath : "\(targetPath)/\(remaining)"
            return resolveSymlinkPath(nextPath, relativeTo: "/", depth: depth + 1)
        }
        return normalized
    }

    let readFileSync: @convention(block) (String, JSValue?) -> JSValue? = { path, encoding in
        do {
            let resolvedPath = resolveSymlinkPath(path, relativeTo: execution.cmdCtx.cwd)
            let data = try execution.cmdCtx.fileSystem.readFile(path: resolvedPath, relativeTo: "/")
            if let encoding = encoding, !encoding.isUndefined, let enc = encoding.toString() {
                if enc.lowercased() == "utf8" || enc.lowercased() == "utf-8" {
                    return JSValue(object: String(decoding: data, as: UTF8.self), in: context)
                }
                if enc.lowercased() == "base64" {
                    return JSValue(object: data.base64EncodedString(), in: context)
                }
                if enc.lowercased() == "hex" {
                    return JSValue(object: data.map { String(format: "%02x", $0) }.joined(), in: context)
                }
            }
            return jsUint8Array(from: data, in: context)
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "open", in: context)
            return nil
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.readFileSync: \(error.localizedDescription)", in: context)
            return nil
        }
    }
    fs.setObject(readFileSync, forKeyedSubscript: "readFileSync" as NSString)

    let writeFileSync: @convention(block) (String, JSValue, JSValue?) -> Void = { path, contents, _ in
        do {
            let resolvedPath = resolveSymlinkPath(path, relativeTo: execution.cmdCtx.cwd)
            let data = jsValueToData(contents)
            try execution.cmdCtx.fileSystem.writeFile(path: resolvedPath, content: data, relativeTo: "/")
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "write", in: context)
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.writeFileSync: \(error.localizedDescription)", in: context)
        }
    }
    fs.setObject(writeFileSync, forKeyedSubscript: "writeFileSync" as NSString)

    let appendFileSync: @convention(block) (String, JSValue, JSValue?) -> Void = { path, contents, _ in
        do {
            let resolvedPath = resolveSymlinkPath(path, relativeTo: execution.cmdCtx.cwd)
            let existing = (try? execution.cmdCtx.fileSystem.readFile(path: resolvedPath, relativeTo: "/")) ?? Data()
            let appended = existing + jsValueToData(contents)
            try execution.cmdCtx.fileSystem.writeFile(path: resolvedPath, content: appended, relativeTo: "/")
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "write", in: context)
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.appendFileSync: \(error.localizedDescription)", in: context)
        }
    }
    fs.setObject(appendFileSync, forKeyedSubscript: "appendFileSync" as NSString)

    let readdirSync: @convention(block) (String) -> [String]? = { path in
        do {
            let resolvedPath = resolveSymlinkPath(path, relativeTo: execution.cmdCtx.cwd)
            return try execution.cmdCtx.fileSystem.listDirectory(path: resolvedPath, relativeTo: "/")
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "scandir", in: context)
            return nil
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.readdirSync: \(error.localizedDescription)", in: context)
            return nil
        }
    }
    fs.setObject(readdirSync, forKeyedSubscript: "readdirSync" as NSString)

    let mkdirSync: @convention(block) (String, JSValue?) -> Void = { path, opts in
        let recursive = opts?.objectForKeyedSubscript("recursive")?.toBool() ?? false
        do {
            try execution.cmdCtx.fileSystem.createDirectory(path: path, relativeTo: execution.cmdCtx.cwd, recursive: recursive)
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "mkdir", in: context)
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.mkdirSync: \(error.localizedDescription)", in: context)
        }
    }
    fs.setObject(mkdirSync, forKeyedSubscript: "mkdirSync" as NSString)

    let rmSync: @convention(block) (String, JSValue?) -> Void = { path, opts in
        let recursive = opts?.objectForKeyedSubscript("recursive")?.toBool() ?? false
        let force = opts?.objectForKeyedSubscript("force")?.toBool() ?? false
        do {
            try execution.cmdCtx.fileSystem.deleteFile(path: path, relativeTo: execution.cmdCtx.cwd, recursive: recursive, force: force)
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "unlink", in: context)
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.rmSync: \(error.localizedDescription)", in: context)
        }
    }
    fs.setObject(rmSync, forKeyedSubscript: "rmSync" as NSString)

    let unlinkSync: @convention(block) (String) -> Void = { path in
        do {
            try execution.cmdCtx.fileSystem.deleteFile(path: path, relativeTo: execution.cmdCtx.cwd, recursive: false, force: false)
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "unlink", in: context)
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.unlinkSync: \(error.localizedDescription)", in: context)
        }
    }
    fs.setObject(unlinkSync, forKeyedSubscript: "unlinkSync" as NSString)

    let rmdirSync: @convention(block) (String) -> Void = { path in
        do {
            try execution.cmdCtx.fileSystem.deleteFile(path: path, relativeTo: execution.cmdCtx.cwd, recursive: false, force: false)
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "rmdir", in: context)
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.rmdirSync: \(error.localizedDescription)", in: context)
        }
    }
    fs.setObject(rmdirSync, forKeyedSubscript: "rmdirSync" as NSString)

    let existsSync: @convention(block) (String) -> Bool = { path in
        let resolvedPath = resolveSymlinkPath(path, relativeTo: execution.cmdCtx.cwd)
        return execution.cmdCtx.fileSystem.fileExists(path: resolvedPath, relativeTo: "/")
    }
    fs.setObject(existsSync, forKeyedSubscript: "existsSync" as NSString)

    let statSync: @convention(block) (String) -> JSValue? = { path in
        do {
            let resolvedPath = resolveSymlinkPath(path, relativeTo: execution.cmdCtx.cwd)
            let info = try execution.cmdCtx.fileSystem.fileInfo(path: resolvedPath, relativeTo: "/")
            return statValue(from: info, in: context)
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "stat", in: context)
            return nil
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.statSync: \(error.localizedDescription)", in: context)
            return nil
        }
    }
    fs.setObject(statSync, forKeyedSubscript: "statSync" as NSString)
    fs.setObject(statSync, forKeyedSubscript: "lstatSync" as NSString)

    let symlinkSync: @convention(block) (String, String, JSValue?) -> Void = { target, path, _ in
        do {
            try execution.cmdCtx.fileSystem.createSymlink(target, at: path, relativeTo: execution.cmdCtx.cwd)
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "symlink", in: context)
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.symlinkSync: \(error.localizedDescription)", in: context)
        }
    }
    fs.setObject(symlinkSync, forKeyedSubscript: "symlinkSync" as NSString)

    let readlinkSync: @convention(block) (String) -> JSValue? = { path in
        do {
            let target = try execution.cmdCtx.fileSystem.readlink(path, relativeTo: execution.cmdCtx.cwd)
            return JSValue(object: target, in: context)
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: path, syscall: "readlink", in: context)
            return nil
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.readlinkSync: \(error.localizedDescription)", in: context)
            return nil
        }
    }
    fs.setObject(readlinkSync, forKeyedSubscript: "readlinkSync" as NSString)

    let copyFileSync: @convention(block) (String, String) -> Void = { src, dst in
        do {
            let resolvedSource = resolveSymlinkPath(src, relativeTo: execution.cmdCtx.cwd)
            let resolvedDestination = resolveSymlinkPath(dst, relativeTo: execution.cmdCtx.cwd)
            let data = try execution.cmdCtx.fileSystem.readFile(path: resolvedSource, relativeTo: "/")
            try execution.cmdCtx.fileSystem.writeFile(path: resolvedDestination, content: data, relativeTo: "/")
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: src, syscall: "copyfile", in: context)
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.copyFileSync: \(error.localizedDescription)", in: context)
        }
    }
    fs.setObject(copyFileSync, forKeyedSubscript: "copyFileSync" as NSString)

    let renameSync: @convention(block) (String, String) -> Void = { src, dst in
        do {
            let resolvedSource = resolveSymlinkPath(src, relativeTo: execution.cmdCtx.cwd)
            let resolvedDestination = resolveSymlinkPath(dst, relativeTo: execution.cmdCtx.cwd)
            let data = try execution.cmdCtx.fileSystem.readFile(path: resolvedSource, relativeTo: "/")
            try execution.cmdCtx.fileSystem.writeFile(path: resolvedDestination, content: data, relativeTo: "/")
            try execution.cmdCtx.fileSystem.deleteFile(path: resolvedSource, relativeTo: "/", recursive: false, force: false)
        } catch let e {
            context.exception = NodeErrorMapper.makeError(forAny: e, path: src, syscall: "rename", in: context)
        } catch {
            context.exception = JSValue(newErrorFromMessage: "fs.renameSync: \(error.localizedDescription)", in: context)
        }
    }
    fs.setObject(renameSync, forKeyedSubscript: "renameSync" as NSString)

    let realpathSync: @convention(block) (String) -> String = { path in
        resolveSymlinkPath(path, relativeTo: execution.cmdCtx.cwd)
    }
    fs.setObject(realpathSync, forKeyedSubscript: "realpathSync" as NSString)

    // .promises namespace — async variants implemented via the sync ones.
    let promises = JSValue(newObjectIn: context)!
    let asyncWrap = """
    (function(syncFn, errToObj) {
      return function(...args) { return new Promise((resolve, reject) => { try { resolve(syncFn(...args)); } catch (e) { reject(e); } }); };
    })
    """
    let asyncFactory = context.evaluateScript(asyncWrap)!
    for name in ["readFile", "writeFile", "appendFile", "readdir", "mkdir", "rm", "unlink", "rmdir", "stat", "lstat", "symlink", "readlink", "copyFile", "rename", "realpath"] {
        let syncName = name + "Sync"
        if let syncFn = fs.objectForKeyedSubscript(syncName) {
            let asyncFn = asyncFactory.call(withArguments: [syncFn])!
            promises.setObject(asyncFn, forKeyedSubscript: name as NSString)
        }
    }
    fs.setObject(promises, forKeyedSubscript: "promises" as NSString)

    context.setObject(fs, forKeyedSubscript: "fs" as NSString)
    context.evaluateScript("globalThis.__jb_fs = fs;")
}

func statValue(from info: FileInfo, in context: JSContext) -> JSValue {
    let dict: [String: Any] = [
        "size": info.size,
        "isFile_": info.kind == .file,
        "isDirectory_": info.kind == .directory,
        "isSymbolicLink_": info.kind == .symlink
    ]
    let value = JSValue(object: dict, in: context)!
    let helpers = """
    (function(s) {
      s.isFile = function() { return s.isFile_; };
      s.isDirectory = function() { return s.isDirectory_; };
      s.isSymbolicLink = function() { return s.isSymbolicLink_; };
      s.isBlockDevice = function() { return false; };
      s.isCharacterDevice = function() { return false; };
      s.isFIFO = function() { return false; };
      s.isSocket = function() { return false; };
      return s;
    })
    """
    if let factory = context.evaluateScript(helpers) {
        return factory.call(withArguments: [value]) ?? value
    }
    return value
}

func jsUint8Array(from data: Data, in context: JSContext) -> JSValue {
    let array = data.map { Int($0) }
    let arrayValue = JSValue(object: array, in: context)!
    let factory = context.evaluateScript("(function(a) { return Uint8Array.from(a); })")!
    return factory.call(withArguments: [arrayValue]) ?? arrayValue
}

func jsValueToData(_ value: JSValue) -> Data {
    if value.isString {
        return Data((value.toString() ?? "").utf8)
    }
    if let typed = value.toObject() as? [Any] {
        var bytes: [UInt8] = []
        for entry in typed {
            if let n = entry as? Int { bytes.append(UInt8(truncatingIfNeeded: n)) }
            else if let n = entry as? NSNumber { bytes.append(n.uint8Value) }
        }
        return Data(bytes)
    }
    if let dict = value.toObject() as? [String: Any], let arr = dict["data"] as? [Any] {
        return jsValueToData(JSValue(object: arr, in: value.context)!)
    }
    return Data((value.toString() ?? "").utf8)
}
