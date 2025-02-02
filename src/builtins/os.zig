const std = @import("std");
const stdx = @import("stdx");
const fatal = stdx.fatal;
const builtin = @import("builtin");
const cy = @import("../cyber.zig");
const Value = cy.Value;
const vm_ = @import("../vm.zig");
const gvm = &vm_.gvm;
const fmt = @import("../fmt.zig");
const bindings = @import("bindings.zig");
const TagLit = bindings.TagLit;

pub fn initModule(self: *cy.VMcompiler, spec: []const u8) linksection(cy.InitSection) !cy.Module {
    var mod = cy.Module{
        .syms = .{},
        .prefix = spec,
    };

    try mod.setVar(self, "cpu", try self.buf.getOrPushStringValue(@tagName(builtin.cpu.arch)));
    if (builtin.cpu.arch.endian() == .Little) {
        try mod.setVar(self, "endian", cy.Value.initTagLiteral(@enumToInt(TagLit.little)));
    } else {
        try mod.setVar(self, "endian", cy.Value.initTagLiteral(@enumToInt(TagLit.big)));
    }
    if (cy.hasStdFiles) {
        const stdin = try self.vm.allocFile(std.os.STDIN_FILENO);
        try mod.setVar(self, "stdin", stdin);
    } else {
        try mod.setVar(self, "stdin", Value.None);
    }
    if (builtin.cpu.arch.isWasm()) {
        try mod.setVar(self, "system", try self.buf.getOrPushStringValue("wasm"));
    } else {
        try mod.setVar(self, "system", try self.buf.getOrPushStringValue(@tagName(builtin.os.tag)));
    }
    if (comptime std.simd.suggestVectorSize(u8)) |VecSize| {
        try mod.setVar(self, "vecBitSize", cy.Value.initF64(VecSize * 8));
    } else {
        try mod.setVar(self, "vecBitSize", cy.Value.initF64(0));
    }

    try mod.setNativeFunc(self, "args", 0, osArgs);
    if (cy.isWasm) {
        try mod.setNativeFunc(self, "createDir", 1, bindings.nop1);
        try mod.setNativeFunc(self, "createFile", 2, bindings.nop2);
        try mod.setNativeFunc(self, "cwd", 0, bindings.nop0);
        try mod.setNativeFunc(self, "exePath", 0, bindings.nop0);
        try mod.setNativeFunc(self, "getEnv", 1, bindings.nop1);
        try mod.setNativeFunc(self, "getEnvAll", 0, bindings.nop0);
    } else {
        try mod.setNativeFunc(self, "createDir", 1, createDir);
        try mod.setNativeFunc(self, "createFile", 2, createFile);
        try mod.setNativeFunc(self, "cwd", 0, cwd);
        try mod.setNativeFunc(self, "exePath", 0, exePath);
        try mod.setNativeFunc(self, "getEnv", 1, getEnv);
        try mod.setNativeFunc(self, "getEnvAll", 0, getEnvAll);
    }
    try mod.setNativeFunc(self, "milliTime", 0, milliTime);
    if (cy.isWasm) {
        try mod.setNativeFunc(self, "openDir", 1, bindings.nop1);
        try mod.setNativeFunc(self, "openDir", 2, bindings.nop2);
        try mod.setNativeFunc(self, "openFile", 2, bindings.nop2);
        try mod.setNativeFunc(self, "removeDir", 1, bindings.nop1);
        try mod.setNativeFunc(self, "removeFile", 1, bindings.nop1);
        try mod.setNativeFunc(self, "realPath", 1, bindings.nop1);
        try mod.setNativeFunc(self, "setEnv", 2, bindings.nop2);
    } else {
        try mod.setNativeFunc(self, "openDir", 1, openDir);
        try mod.setNativeFunc(self, "openDir", 2, openDir2);
        try mod.setNativeFunc(self, "openFile", 2, openFile);
        try mod.setNativeFunc(self, "removeDir", 1, removeDir);
        try mod.setNativeFunc(self, "removeFile", 1, removeFile);
        try mod.setNativeFunc(self, "realPath", 1, realPath);
        try mod.setNativeFunc(self, "setEnv", 2, setEnv);
    }
    try mod.setNativeFunc(self, "sleep", 1, sleep);
    if (cy.isWasm) {
        try mod.setNativeFunc(self, "unsetEnv", 1, bindings.nop1);
    } else {
        try mod.setNativeFunc(self, "unsetEnv", 1, unsetEnv);
    }
    return mod;
}

pub fn deinitModule(c: *cy.VMcompiler, mod: cy.Module) !void {
    if (cy.hasStdFiles) {
        // Mark as closed to avoid closing.
        const stdin = (try mod.getVarVal(c, "stdin")).?;
        stdin.asHeapObject(*cy.HeapObject).file.closed = true;
        vm_.release(c.vm, stdin);
    }
}

fn openDir(vm: *cy.UserVM, args: [*]const Value, nargs: u8) linksection(cy.StdSection) Value {
    return openDir2(vm, &[_]Value{ args[0], Value.False }, nargs);
}

fn openDir2(vm: *cy.UserVM, args: [*]const Value, _: u8) linksection(cy.StdSection) Value {
    defer {
        vm.release(args[0]);
    }
    const path = vm.valueToTempString(args[0]);
    const iterable = args[1].toBool();
    var fd: std.os.fd_t = undefined;
    if (iterable) {
        const dir = std.fs.cwd().openIterableDir(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return Value.initErrorTagLit(@enumToInt(TagLit.FileNotFound));
            } else {
                fmt.printStderr("openDir {}", &.{fmt.v(err)});
                return Value.None;
            }
        };
        fd = dir.dir.fd;
    } else {
        const dir = std.fs.cwd().openDir(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return Value.initErrorTagLit(@enumToInt(TagLit.FileNotFound));
            } else {
                fmt.printStderr("openDir {}", &.{fmt.v(err)});
                return Value.None;
            }
        };
        fd = dir.fd;
    }
    return vm.allocDir(fd, iterable) catch fatal();
}

fn removeDir(vm: *cy.UserVM, args: [*]const Value, _: u8) linksection(cy.StdSection) Value {
    defer {
        vm.release(args[0]);
    }
    const path = vm.valueToTempString(args[0]);
    std.fs.cwd().deleteDir(path) catch |err| {
        fmt.printStderr("removeDir {}", &.{fmt.v(err)});
        return Value.None;
    };
    return Value.True;
}

fn removeFile(vm: *cy.UserVM, args: [*]const Value, _: u8) linksection(cy.StdSection) Value {
    defer {
        vm.release(args[0]);
    }
    const path = vm.valueToTempString(args[0]);
    std.fs.cwd().deleteFile(path) catch |err| {
        fmt.printStderr("removeFile {}", &.{fmt.v(err)});
        return Value.None;
    };
    return Value.True;
}

fn createDir(vm: *cy.UserVM, args: [*]const Value, _: u8) linksection(cy.StdSection) Value {
    defer {
        vm.release(args[0]);
    }
    const path = vm.valueToTempString(args[0]);
    std.fs.cwd().makeDir(path) catch |err| {
        fmt.printStderr("createDir {}", &.{fmt.v(err)});
        return Value.None;
    };
    return Value.True;
}

fn createFile(vm: *cy.UserVM, args: [*]const Value, _: u8) linksection(cy.StdSection) Value {
    defer {
        vm.release(args[0]);
    }
    const path = vm.valueToTempString(args[0]);
    const truncate = args[1].toBool();
    const file = std.fs.cwd().createFile(path, .{ .truncate = truncate }) catch |err| {
        fmt.printStderr("createFile {}", &.{fmt.v(err)});
        return Value.None;
    };
    return vm.allocFile(file.handle) catch fatal();
}

fn openFile(vm: *cy.UserVM, args: [*]const Value, _: u8) linksection(cy.StdSection) Value {
    defer {
        vm.release(args[0]);
    }
    const path = vm.valueToTempString(args[0]);
    if (args[1].isTagLiteral()) {
        const mode = @intToEnum(TagLit, args[1].asTagLiteralId());
        const zmode: std.fs.File.OpenMode = switch (mode) {
            .read => .read_only,
            .write => .write_only,
            .readWrite => .read_write,
            else => {
                return Value.None;
            }
        };
        const file = std.fs.cwd().openFile(path, .{ .mode = zmode }) catch |err| {
            if (err == error.FileNotFound) {
                return Value.initErrorTagLit(@enumToInt(TagLit.FileNotFound));
            } else {
                fmt.printStderr("openFile {}", &.{fmt.v(err)});
                return Value.None;
            }
        };
        return vm.allocFile(file.handle) catch fatal();
    } else {
        return Value.None;
    }
}

fn osArgs(vm: *cy.UserVM, _: [*]const Value, _: u8) linksection(cy.StdSection) Value {
    const alloc = vm.allocator();
    var iter = std.process.argsWithAllocator(alloc) catch stdx.fatal();
    defer iter.deinit();
    const listv = vm.allocEmptyList() catch stdx.fatal();
    const listo = listv.asHeapObject(*cy.HeapObject);
    while (iter.next()) |arg| {
        const argv = vm.allocRawString(arg) catch stdx.fatal();
        listo.list.append(vm.allocator(), argv);
    }
    return listv;
}

pub fn cwd(vm: *cy.UserVM, _: [*]const Value, _: u8) linksection(cy.StdSection) Value {
    const res = std.process.getCwdAlloc(vm.allocator()) catch fatal();
    defer vm.allocator().free(res);
    // TODO: Use allocOwnedString
    return vm.allocStringInfer(res) catch fatal();
}

pub fn exePath(vm: *cy.UserVM, _: [*]const Value, _: u8) Value {
    const path = std.fs.selfExePathAlloc(vm.allocator()) catch fatal();
    defer vm.allocator().free(path);
    // TODO: Use allocOwnedString
    return vm.allocStringInfer(path) catch fatal();
}

pub fn getEnv(vm: *cy.UserVM, args: [*]const Value, _: u8) Value {
    const key = vm.valueToTempString(args[0]);
    const res = std.os.getenv(key) orelse return Value.None;
    return vm.allocStringInfer(res) catch stdx.fatal();
}

pub fn getEnvAll(vm: *cy.UserVM, _: [*]const Value, _: u8) Value {
    var env = std.process.getEnvMap(vm.allocator()) catch stdx.fatal();
    defer env.deinit();

    const map = vm.allocEmptyMap() catch stdx.fatal();
    var iter = env.iterator();
    while (iter.next()) |entry| {
        const key = vm.allocStringInfer(entry.key_ptr.*) catch stdx.fatal();
        const val = vm.allocStringInfer(entry.value_ptr.*) catch stdx.fatal();
        gvm.setIndex(map, key, val) catch stdx.fatal();
    }
    return map;
}

pub fn milliTime(_: *cy.UserVM, _: [*]const Value, _: u8) linksection(cy.StdSection) Value {
    if (cy.isWasm) {
        return Value.initF64(hostMilliTime());
    } else {
        return Value.initF64(@intToFloat(f64, std.time.milliTimestamp()));
    }
}

extern fn hostMilliTime() f64;

pub fn realPath(vm: *cy.UserVM, args: [*]const Value, _: u8) Value {
    const path = vm.valueToTempString(args[0]);
    const res = std.fs.cwd().realpathAlloc(vm.allocator(), path) catch stdx.fatal();
    defer vm.allocator().free(res);
    // TODO: Use allocOwnedString.
    return vm.allocStringInfer(res) catch stdx.fatal();
}

pub fn setEnv(vm: *cy.UserVM, args: [*]const Value, _: u8) Value {
    const key = vm.valueToString(args[0]) catch stdx.fatal();
    defer vm.allocator().free(key);
    const keyz = std.cstr.addNullByte(vm.allocator(), key) catch stdx.fatal();
    defer vm.allocator().free(keyz);

    const value = vm.valueToTempString(args[1]);
    const valuez = std.cstr.addNullByte(vm.allocator(), value) catch stdx.fatal();
    defer vm.allocator().free(valuez);
    _ = setenv(keyz, valuez, 1);
    return Value.None;
}
pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn sleep(_: *cy.UserVM, args: [*]const Value, _: u8) linksection(cy.StdSection) Value {
    const ms = args[0].toF64();
    const secs = @floatToInt(u64, @divFloor(ms, 1000));
    const nsecs = @floatToInt(u64, 1e6 * (std.math.mod(f64, ms, 1000) catch stdx.fatal()));
    if (cy.isWasm) {
        hostSleep(secs, nsecs);
    } else {
        std.os.nanosleep(secs, nsecs);
    }
    return Value.None;
}

extern fn hostSleep(secs: u64, nsecs: u64) void;

pub fn unsetEnv(vm: *cy.UserVM, args: [*]const Value, _: u8) Value {
    const key = vm.valueToTempString(args[0]);
    const keyz = std.cstr.addNullByte(vm.allocator(), key) catch stdx.fatal();
    defer vm.allocator().free(keyz);
    _ = unsetenv(keyz);
    return Value.None;
}
pub extern "c" fn unsetenv(name: [*:0]const u8) c_int;