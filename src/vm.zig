const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const t = stdx.testing;
const tcc = @import("tcc");

const fmt = @import("fmt.zig");
const v = fmt.v;
const cy = @import("cyber.zig");
const sema = @import("sema.zig");
const bindings = @import("builtins/bindings.zig");
const Value = cy.Value;
const debug = @import("debug.zig");
const TraceEnabled = @import("build_options").trace;

const log = stdx.log.scoped(.vm);

const UseGlobalVM = true;
pub const TrackGlobalRC = builtin.mode != .ReleaseFast;
const StdSection = cy.StdSection;

/// Reserved object types known at comptime.
/// Starts at 9 since primitive types go up to 8.
pub const ListS: StructId = 9;
pub const ListIteratorT: StructId = 10;
pub const MapS: StructId = 11;
pub const MapIteratorT: StructId = 12;
pub const ClosureS: StructId = 13;
pub const LambdaS: StructId = 14;
pub const AstringT: StructId = 15;
pub const UstringT: StructId = 16;
pub const StringSliceT: StructId = 17;
pub const RawStringT: StructId = 18;
pub const RawStringSliceT: StructId = 19;
pub const FiberS: StructId = 20;
pub const BoxS: StructId = 21;
pub const NativeFunc1S: StructId = 22;
pub const TccStateS: StructId = 23;
pub const OpaquePtrS: StructId = 24;
pub const FileT: StructId = 25;
pub const DirT: StructId = 26;
pub const DirIteratorT: StructId = 27;

/// Temp buf for toString conversions when the len is known to be small.
var tempU8Buf: [256]u8 = undefined;
var tempU8BufIdx: u32 = undefined;
var tempU8Writer = SliceWriter{ .buf = &tempU8Buf, .idx = &tempU8BufIdx };

/// Going forward, references to gvm should be replaced with pointer access to allow multiple VMs.
/// Once all references are replaced, gvm can be removed and the default VM can be allocated from the heap.
pub var gvm: VM = undefined;

pub fn getUserVM() *UserVM {
    return @ptrCast(*UserVM, &gvm);
}

const DefaultStringInternMaxByteLen = 64;

pub const VM = struct {
    alloc: std.mem.Allocator,
    parser: cy.Parser,
    compiler: cy.VMcompiler,

    /// [Eval context]

    /// Program counter. Pointer to the current instruction data in `ops`.
    pc: [*]cy.OpData,
    /// Current stack frame ptr.
    framePtr: [*]Value,

    /// Value stack.
    stack: []Value,
    stackEndPtr: [*]const Value,

    ops: []cy.OpData,
    consts: []const cy.Const,

    /// Static string data.
    strBuf: []u8,

    /// Holds unique heap string interns (*Astring, *Ustring).
    /// Does not include static strings (those are interned at compile time).
    /// By default, small strings (at most 64 bytes) are interned.
    strInterns: std.StringHashMapUnmanaged(*HeapObject),

    /// Object heap pages.
    heapPages: cy.List(*HeapPage),
    heapFreeHead: ?*HeapObject,

    refCounts: if (TrackGlobalRC) usize else void,

    /// Symbol table used to lookup object methods.
    /// A `SymbolId` indexes into `methodSyms`. If the `mruStructId` matches it uses `mruSym`.
    /// Otherwise, the sym is looked up from the hashmap `methodTable`.
    methodSyms: cy.List(MethodSym),
    methodTable: std.AutoHashMapUnmanaged(ObjectSymKey, MethodSym),

    /// Maps a method signature to a symbol id in `methodSyms`.
    methodSymSigs: std.HashMapUnmanaged(RelFuncSigKey, SymbolId, KeyU64Context, 80),

    /// Regular function symbol table.
    funcSyms: cy.List(FuncSymbolEntry),
    funcSymSigs: std.HashMapUnmanaged(AbsFuncSigKey, SymbolId, KeyU96Context, 80),
    funcSymDetails: cy.List(FuncSymDetail),

    varSyms: cy.List(VarSym),
    varSymSigs: std.HashMapUnmanaged(AbsVarSigKey, SymbolId, KeyU64Context, 80),

    /// Struct fields symbol table.
    fieldSyms: cy.List(FieldSymbolMap),
    fieldTable: std.AutoHashMapUnmanaged(ObjectSymKey, u16),
    fieldSymSignatures: std.StringHashMapUnmanaged(SymbolId),

    /// Structs.
    structs: cy.List(Struct),
    structSignatures: std.HashMapUnmanaged(StructKey, StructId, KeyU64Context, 80),
    iteratorObjSym: SymbolId,
    pairIteratorObjSym: SymbolId,
    nextObjSym: SymbolId,
    nextPairObjSym: SymbolId,

    /// Tag types.
    tagTypes: cy.List(TagType),
    tagTypeSignatures: std.StringHashMapUnmanaged(TagTypeId),

    /// Tag literals.
    tagLitSyms: cy.List(TagLitSym),
    tagLitSymSignatures: std.StringHashMapUnmanaged(SymbolId),

    u8Buf: cy.ListAligned(u8, 8),
    u8Buf2: cy.ListAligned(u8, 8),

    stackTrace: StackTrace,

    methodSymExtras: cy.List([]const u8),
    debugTable: []const cy.OpDebug,

    curFiber: *Fiber,
    mainFiber: Fiber,

    /// Local to be returned back to eval caller.
    /// 255 indicates no return value.
    endLocal: u8,

    mainUri: []const u8,
    panicType: debug.PanicType,
    panicPayload: debug.PanicPayload,

    trace: if (TraceEnabled) *TraceInfo else void,

    /// Object to pc of instruction that allocated it.
    objectTraceMap: if (builtin.mode == .Debug) std.AutoHashMapUnmanaged(*HeapObject, u32) else void,

    /// Whether this VM is already deinited. Used to skip the next deinit to avoid using undefined memory.
    deinited: bool,

    pub fn init(self: *VM, alloc: std.mem.Allocator) !void {
        self.* = .{
            .alloc = alloc,
            .parser = cy.Parser.init(alloc),
            .compiler = undefined,
            .ops = undefined,
            .consts = undefined,
            .strBuf = undefined,
            .strInterns = .{},
            .stack = &.{},
            .stackEndPtr = undefined,
            .heapPages = .{},
            .heapFreeHead = null,
            .pc = undefined,
            .framePtr = undefined,
            .methodSymExtras = .{},
            .methodSyms = .{},
            .methodSymSigs = .{},
            .methodTable = .{},
            .funcSyms = .{},
            .funcSymSigs = .{},
            .funcSymDetails = .{},
            .varSyms = .{},
            .varSymSigs = .{},
            .fieldSyms = .{},
            .fieldTable = .{},
            .fieldSymSignatures = .{},
            .structs = .{},
            .structSignatures = .{},
            .tagTypes = .{},
            .tagTypeSignatures = .{},
            .tagLitSyms = .{},
            .tagLitSymSignatures = .{},
            .iteratorObjSym = undefined,
            .pairIteratorObjSym = undefined,
            .nextObjSym = undefined,
            .nextPairObjSym = undefined,
            .trace = undefined,
            .u8Buf = .{},
            .u8Buf2 = .{},
            .stackTrace = .{},
            .debugTable = undefined,
            .refCounts = if (TrackGlobalRC) 0 else undefined,
            .panicType = .none,
            .panicPayload = Value.None.val,
            .mainFiber = undefined,
            .curFiber = undefined,
            .endLocal = undefined,
            .mainUri = "",
            .objectTraceMap = if (builtin.mode == .Debug) .{} else undefined,
            .deinited = false,
        };
        // Pointer offset from gvm to avoid deoptimization.
        self.curFiber = &gvm.mainFiber;
        try self.compiler.init(self);

        // Perform decently sized allocation for hot data paths since the allocator
        // will likely use a more consistent allocation.
        // Also try to allocate them in the same bucket.
        try self.stackEnsureTotalCapacityPrecise(511);
        try self.methodTable.ensureTotalCapacity(self.alloc, 96);

        try self.funcSyms.ensureTotalCapacityPrecise(self.alloc, 255);
        try self.methodSyms.ensureTotalCapacityPrecise(self.alloc, 255);

        try self.parser.tokens.ensureTotalCapacityPrecise(alloc, 511);
        try self.parser.nodes.ensureTotalCapacityPrecise(alloc, 127);

        try self.structs.ensureTotalCapacityPrecise(alloc, 170);
        try self.fieldSyms.ensureTotalCapacityPrecise(alloc, 170);

        // Initialize heap.
        self.heapFreeHead = try self.growHeapPages(1);

        // Force linksection order. Using `try` makes this work.
        try @call(.never_inline, cy.forceSectionDeps, .{});

        // Core bindings.
        try @call(.never_inline, bindings.bindCore, .{self});
    }

    pub fn deinit(self: *VM) void {
        if (self.deinited) {
            return;
        }

        debug.freePanicPayload(self);

        // Deinit runtime related resources first, since they may depend on
        // compiled/debug resources.
        for (self.funcSyms.items()) |sym| {
            if (sym.entryT == @enumToInt(FuncSymbolEntryType.closure)) {
                releaseObject(self, @ptrCast(*HeapObject, sym.inner.closure));
            }
        }
        self.funcSyms.deinit(self.alloc);
        for (self.varSyms.items()) |vsym| {
            release(self, vsym.value);
        }
        self.varSyms.deinit(self.alloc);

        // Deinit compiler first since it depends on buffers from parser.
        self.compiler.deinit();
        self.parser.deinit();
        self.alloc.free(self.stack);
        self.stack = &.{};

        self.methodSyms.deinit(self.alloc);
        self.methodSymExtras.deinit(self.alloc);
        self.methodSymSigs.deinit(self.alloc);
        self.methodTable.deinit(self.alloc);

        self.funcSymSigs.deinit(self.alloc);
        for (self.funcSymDetails.items()) |detail| {
            self.alloc.free(detail.name);
        }
        self.funcSymDetails.deinit(self.alloc);

        self.varSymSigs.deinit(self.alloc);

        self.fieldSyms.deinit(self.alloc);
        self.fieldTable.deinit(self.alloc);
        self.fieldSymSignatures.deinit(self.alloc);

        for (self.heapPages.items()) |page| {
            self.alloc.destroy(page);
        }
        self.heapPages.deinit(self.alloc);

        self.structs.deinit(self.alloc);
        self.structSignatures.deinit(self.alloc);

        self.tagTypes.deinit(self.alloc);
        self.tagTypeSignatures.deinit(self.alloc);

        self.tagLitSyms.deinit(self.alloc);
        self.tagLitSymSignatures.deinit(self.alloc);

        self.u8Buf.deinit(self.alloc);
        self.u8Buf2.deinit(self.alloc);
        self.stackTrace.deinit(self.alloc);

        self.strInterns.deinit(self.alloc);

        if (builtin.mode == .Debug) {
            self.objectTraceMap.deinit(self.alloc);
        }

        self.deinited = true;
    }

    /// Initializes the page with freed object slots and returns the pointer to the first slot.
    fn initHeapPage(page: *HeapPage) *HeapObject {
        // First HeapObject at index 0 is reserved so that freeObject can get the previous slot without a bounds check.
        page.objects[0].common = .{
            .structId = 0, // Non-NullId so freeObject doesn't think it's a free span.
        };
        const first = &page.objects[1];
        first.freeSpan = .{
            .structId = NullId,
            .len = page.objects.len - 1,
            .start = first,
            .next = null,
        };
        // The rest initialize as free spans so checkMemory doesn't think they are retained objects.
        std.mem.set(HeapObject, page.objects[2..], .{
            .common = .{
                .structId = NullId,
            }
        });
        page.objects[page.objects.len-1].freeSpan.start = first;
        return first;
    }

    /// Returns the first free HeapObject.
    fn growHeapPages(self: *VM, numPages: usize) !*HeapObject {
        var idx = self.heapPages.len;
        try self.heapPages.resize(self.alloc, self.heapPages.len + numPages);

        // Allocate first page.
        var page = try self.alloc.create(HeapPage);
        self.heapPages.buf[idx] = page;

        const first = initHeapPage(page);
        var last = first;
        idx += 1;
        while (idx < self.heapPages.len) : (idx += 1) {
            page = try self.alloc.create(HeapPage);
            self.heapPages.buf[idx] = page;
            const first_ = initHeapPage(page);
            last.freeSpan.next = first_;
            last = first_;
        }
        return first;
    }

    pub fn compile(self: *VM, srcUri: []const u8, src: []const u8) !cy.ByteCodeBuffer {
        var tt = stdx.debug.trace();
        const astRes = try self.parser.parse(src);
        if (astRes.has_error) {
            if (astRes.isTokenError) {
                try debug.printUserError(self, "TokenError", astRes.err_msg, srcUri, self.parser.last_err_pos, true);
                return error.TokenError;
            } else {
                try debug.printUserError(self, "ParseError", astRes.err_msg, srcUri, self.parser.last_err_pos, false);
                return error.ParseError;
            }
        }
        tt.endPrint("parse");

        tt = stdx.debug.trace();
        const res = try self.compiler.compile(astRes, .{
            .genMainScopeReleaseOps = true,
        });
        if (res.hasError) {
            if (self.compiler.lastErrNode != NullId) {
                const token = self.parser.nodes.items[self.compiler.lastErrNode].start_token;
                const pos = self.parser.tokens.items[token].pos();
                try debug.printUserError(self, "CompileError", self.compiler.lastErr, srcUri, pos, false);
            } else {
                try debug.printUserError(self, "CompileError", self.compiler.lastErr, srcUri, NullId, false);
            }
            return error.CompileError;
        }
        tt.endPrint("compile");

        return res.buf;
    }

    pub fn eval(self: *VM, srcUri: []const u8, src: []const u8, config: EvalConfig) !Value {
        var tt = stdx.debug.trace();
        const astRes = try self.parser.parse(src);
        if (astRes.has_error) {
            if (astRes.isTokenError) {
                try debug.printUserError(self, "TokenError", astRes.err_msg, srcUri, self.parser.last_err_pos, true);
                return error.TokenError;
            } else {
                try debug.printUserError(self, "ParseError", astRes.err_msg, srcUri, self.parser.last_err_pos, false);
                return error.ParseError;
            }
        }
        tt.endPrint("parse");

        tt = stdx.debug.trace();
        const res = try self.compiler.compile(astRes, .{
            .genMainScopeReleaseOps = !config.singleRun,
        });
        if (res.hasError) {
            if (self.compiler.lastErrNode != NullId) {
                const token = self.parser.nodes.items[self.compiler.lastErrNode].start_token;
                const pos = self.parser.tokens.items[token].pos();
                try debug.printUserError(self, "CompileError", self.compiler.lastErr, srcUri, pos, false);
            } else {
                try debug.printUserError(self, "CompileError", self.compiler.lastErr, srcUri, NullId, false);
            }
            return error.CompileError;
        }
        tt.endPrint("compile");

        if (TraceEnabled) {
            if (!builtin.is_test and debug.atLeastTestDebugLevel()) {
                res.buf.dump();
            }
            const numOps = comptime std.enums.values(cy.OpCode).len;
            self.trace.opCounts = try self.alloc.alloc(cy.OpCount, numOps);
            var i: u32 = 0;
            while (i < numOps) : (i += 1) {
                self.trace.opCounts[i] = .{
                    .code = i,
                    .count = 0,
                };
            }
            self.trace.totalOpCounts = 0;
            self.trace.numReleases = 0;
            self.trace.numReleaseAttempts = 0;
            self.trace.numForceReleases = 0;
            self.trace.numRetains = 0;
            self.trace.numRetainAttempts = 0;
            self.trace.numRetainCycles = 0;
            self.trace.numRetainCycleRoots = 0;
        } else {
            if (builtin.is_test and debug.atLeastTestDebugLevel()) {
                // Only visible for tests with .debug log level.
                res.buf.dump();
            }
        }

        tt = stdx.debug.trace();
        defer {
            tt.endPrint("eval");
            if (TraceEnabled) {
                if (!builtin.is_test or debug.atLeastTestDebugLevel()) {
                    self.dumpInfo();
                }
            }
        }

        self.mainUri = srcUri;
        return self.evalByteCode(res.buf);
    }

    pub fn dumpStats(self: *const VM) void {
        const S = struct {
            fn opCountLess(_: void, a: cy.OpCount, b: cy.OpCount) bool {
                return a.count > b.count;
            }
        };
        std.debug.print("total ops evaled: {}\n", .{self.trace.totalOpCounts});
        std.sort.sort(cy.OpCount, self.trace.opCounts, {}, S.opCountLess);
        var i: u32 = 0;

        const numOps = comptime std.enums.values(cy.OpCode).len;
        while (i < numOps) : (i += 1) {
            if (self.trace.opCounts[i].count > 0) {
                const op = std.meta.intToEnum(cy.OpCode, self.trace.opCounts[i].code) catch continue;
                std.debug.print("\t{s} {}\n", .{@tagName(op), self.trace.opCounts[i].count});
            }
        }
    }

    pub fn dumpInfo(self: *VM) void {
        fmt.printStderr("stack size: {}\n", &.{v(self.stack.len)});
        fmt.printStderr("stack framePtr: {}\n", &.{v(framePtrOffset(self.framePtr))});
        fmt.printStderr("heap pages: {}\n", &.{v(self.heapPages.len)});

        // Dump object symbols.
        {
            fmt.printStderr("obj syms:\n", &.{});
            var iter = self.funcSymSigs.iterator();
            while (iter.next()) |it| {
                const key = it.key_ptr.*;
                const name = sema.getName(&self.compiler, key.rtFuncSymKey.nameId);
                if (key.rtFuncSymKey.numParams == NullId) {
                    fmt.printStderr("\t{}: {}\n", &.{v(name), v(it.value_ptr.*)});
                } else {
                    fmt.printStderr("\t{}({}): {}\n", &.{v(name), v(key.rtFuncSymKey.numParams), v(it.value_ptr.*)});
                }
            }
        }

        // Dump object fields.
        {
            fmt.printStderr("obj fields:\n", &.{});
            var iter = self.fieldSymSignatures.iterator();
            while (iter.next()) |it| {
                fmt.printStderr("\t{}: {}\n", &.{v(it.key_ptr.*), v(it.value_ptr.*)});
            }
        }
    }

    pub fn popStackFrameCold(self: *VM, comptime numRetVals: u2) linksection(cy.HotSection) void {
        _ = self;
        @setRuntimeSafety(debug);
        switch (numRetVals) {
            2 => {
                log.err("unsupported", .{});
            },
            3 => {
                // unreachable;
            },
            else => @compileError("Unsupported num return values."),
        }
    }

    fn popStackFrameLocal(self: *VM, pc: *usize, retLocal: u8, comptime numRetVals: u2) linksection(cy.HotSection) bool {
        @setRuntimeSafety(debug);
        _ = retLocal;
        _ = self;
        _ = pc;

        // If there are fewer return values than required from the function call, 
        // fill the missing slots with the none value.
        switch (numRetVals) {
            0 => @compileError("Not supported."),
            1 => @compileError("Not supported."),
            else => @compileError("Unsupported num return values."),
        }
    }

    fn prepareEvalCold(self: *VM, buf: cy.ByteCodeBuffer) void {
        @setCold(true);
        debug.freePanicPayload(self);
        self.panicType = .none;
        self.debugTable = buf.debugTable.items;
    }

    pub fn evalByteCode(self: *VM, buf: cy.ByteCodeBuffer) !Value {
        if (buf.ops.items.len == 0) {
            return error.NoEndOp;
        }

        @call(.never_inline, self.prepareEvalCold, .{buf});

        // Set these last to hint location to cache before eval.
        self.pc = @ptrCast([*]cy.OpData, buf.ops.items.ptr);
        try self.stackEnsureTotalCapacity(buf.mainStackSize);
        self.framePtr = @ptrCast([*]Value, self.stack.ptr);

        self.ops = buf.ops.items;
        self.consts = buf.mconsts;
        self.strBuf = buf.strBuf.items;

        try @call(.never_inline, evalLoopGrowStack, .{self});
        if (TraceEnabled) {
            log.info("main stack size: {}", .{buf.mainStackSize});
        }

        if (self.endLocal == 255) {
            return Value.None;
        } else {
            return self.stack[self.endLocal];
        }
    }

    fn sliceOp(self: *VM, recv: *Value, startV: Value, endV: Value) !Value {
        if (recv.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer().?);
            switch (obj.retainedCommon.structId) {
                ListS => {
                    const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
                    var start = @floatToInt(i32, startV.toF64());
                    if (start < 0) {
                        start = @intCast(i32, list.len) + start;
                    }
                    var end = if (endV.isNone()) @intCast(i32, list.len) else @floatToInt(i32, endV.toF64());
                    if (end < 0) {
                        end = @intCast(i32, list.len) + end;
                    }
                    if (start < 0 or start > list.len) {
                        return self.panic("Index out of bounds");
                    }
                    if (end < start or end > list.len) {
                        return self.panic("Index out of bounds");
                    }
                    return self.allocList(list.buf[@intCast(u32, start)..@intCast(u32, end)]);
                },
                AstringT => {
                    retainObject(self, obj);
                    return bindings.stringSlice(.astring)(@ptrCast(*UserVM, self), obj, &[_]Value{startV, endV}, 2);
                },
                UstringT => {
                    retainObject(self, obj);
                    return bindings.stringSlice(.ustring)(@ptrCast(*UserVM, self), obj, &[_]Value{startV, endV}, 2);
                },
                StringSliceT => {
                    retainObject(self, obj);
                    return bindings.stringSlice(.slice)(@ptrCast(*UserVM, self), obj, &[_]Value{startV, endV}, 2);
                },
                RawStringT => {
                    retainObject(self, obj);
                    return bindings.stringSlice(.rawstring)(@ptrCast(*UserVM, self), obj, &[_]Value{startV, endV}, 2);
                },
                RawStringSliceT => {
                    retainObject(self, obj);
                    return bindings.stringSlice(.rawSlice)(@ptrCast(*UserVM, self), obj, &[_]Value{startV, endV}, 2);
                },
                else => {
                    return self.panicFmt("Unsupported slice operation on type `{}`.", &.{v(self.structs.buf[obj.retainedCommon.structId].name)});
                },
            }
        } else {
            if (recv.isNumber()) {
                return self.panic("Unsupported slice operation on type `number`.");
            } else {
                switch (recv.getTag()) {
                    cy.StaticAstringT => return bindings.stringSlice(.staticAstring)(@ptrCast(*UserVM, self), recv, &[_]Value{startV, endV}, 2),
                    cy.StaticUstringT => return bindings.stringSlice(.staticUstring)(@ptrCast(*UserVM, self), recv, &[_]Value{startV, endV}, 2),
                    else => {
                        return self.panicFmt("Unsupported slice operation on type `{}`.", &.{v(@intCast(u8, recv.getTag()))});
                    },
                }
            }
        }
    }

    pub fn allocEmptyList(self: *VM) linksection(cy.Section) !Value {
        const obj = try self.allocPoolObject();
        obj.list = .{
            .structId = ListS,
            .rc = 1,
            .list = .{
                .ptr = undefined,
                .len = 0,
                .cap = 0,
            },
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocEmptyMap(self: *VM) !Value {
        const obj = try self.allocPoolObject();
        obj.map = .{
            .structId = MapS,
            .rc = 1,
            .inner = .{
                .metadata = null,
                .entries = null,
                .size = 0,
                .cap = 0,
                .available = 0,
            },
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    /// Allocates an object outside of the object pool.
    fn allocObject(self: *VM, sid: StructId, fields: []const Value) !Value {
        // First slot holds the structId and rc.
        const objSlice = try self.alloc.alignedAlloc(Value, @alignOf(HeapObject), 1 + fields.len);
        const obj = @ptrCast(*Object, objSlice.ptr);
        obj.* = .{
            .structId = sid,
            .rc = 1,
            .firstValue = undefined,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }

        const dst = obj.getValuesPtr();
        std.mem.copy(Value, dst[0..fields.len], fields);

        const res = Value.initPtr(obj);
        return res;
    }

    fn allocObjectSmall(self: *VM, sid: StructId, fields: []const Value) !Value {
        const obj = try self.allocPoolObject();
        obj.object = .{
            .structId = sid,
            .rc = 1,
            .firstValue = undefined,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }

        const dst = obj.object.getValuesPtr();
        std.mem.copy(Value, dst[0..fields.len], fields);

        const res = Value.initPtr(obj);
        return res;
    }

    fn allocMap(self: *VM, keyIdxs: []const cy.OpData, vals: []const Value) !Value {
        const obj = try self.allocPoolObject();
        obj.map = .{
            .structId = MapS,
            .rc = 1,
            .inner = .{
                .metadata = null,
                .entries = null,
                .size = 0,
                .cap = 0,
                .available = 0,
            },
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }

        const inner = @ptrCast(*MapInner, &obj.map.inner);
        for (keyIdxs) |idx, i| {
            const val = vals[i];

            const keyVal = Value{ .val = self.consts[idx.arg].val };
            const res = try inner.getOrPut(self.alloc, self, keyVal);
            if (res.foundExisting) {
                // TODO: Handle reference count.
                res.valuePtr.* = val;
            } else {
                res.valuePtr.* = val;
            }
        }

        const res = Value.initPtr(obj);
        return res;
    }

    pub fn freeObject(self: *VM, obj: *HeapObject) linksection(cy.HotSection) void {
        const prev = &(@ptrCast([*]HeapObject, obj) - 1)[0];
        if (prev.common.structId == NullId) {
            // Left is a free span. Extend length.
            prev.freeSpan.start.freeSpan.len += 1;
            obj.freeSpan.start = prev.freeSpan.start;
        } else {
            // Add single slot free span.
            obj.freeSpan = .{
                .structId = NullId,
                .len = 1,
                .start = obj,
                .next = self.heapFreeHead,
            };
            self.heapFreeHead = obj;
        }
    }

    pub fn allocPoolObject(self: *VM) linksection(cy.HotSection) !*HeapObject {
        if (self.heapFreeHead == null) {
            self.heapFreeHead = try self.growHeapPages(std.math.max(1, (self.heapPages.len * 15) / 10));
        }
        const ptr = self.heapFreeHead.?;
        if (ptr.freeSpan.len == 1) {
            // This is the only free slot, move to the next free span.
            self.heapFreeHead = ptr.freeSpan.next;
            return ptr;
        } else {
            const next = &@ptrCast([*]HeapObject, ptr)[1];
            next.freeSpan = .{
                .structId = NullId,
                .len = ptr.freeSpan.len - 1,
                .start = next,
                .next = ptr.freeSpan.next,
            };
            const last = &@ptrCast([*]HeapObject, ptr)[ptr.freeSpan.len-1];
            last.freeSpan.start = next;
            self.heapFreeHead = next;
            return ptr;
        }
    }

    fn allocFuncFromSym(self: *VM, symId: SymbolId) !Value {
        const sym = self.funcSyms.buf[symId];
        switch (@intToEnum(FuncSymbolEntryType, sym.entryT)) {
            .nativeFunc1 => {
                return self.allocNativeFunc1(sym.inner.nativeFunc1, sym.innerExtra.nativeFunc1.numParams, null);
            },
            .func => {
                return self.allocLambda(sym.inner.func.pc, @intCast(u8, sym.inner.func.numParams), @intCast(u8, sym.inner.func.numLocals));
            },
            .closure => {
                self.retainObject(@ptrCast(*HeapObject, sym.inner.closure));
                return Value.initPtr(sym.inner.closure);
            },
            .none => return Value.None,
        }
    }

    fn allocLambda(self: *VM, funcPc: usize, numParams: u8, numLocals: u8) !Value {
        const obj = try self.allocPoolObject();
        obj.lambda = .{
            .structId = LambdaS,
            .rc = 1,
            .funcPc = @intCast(u32, funcPc),
            .numParams = numParams,
            .numLocals = numLocals,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocEmptyClosure(self: *VM, funcPc: usize, numParams: u8, numLocals: u8, numCaptured: u8) !Value {
        var obj: *HeapObject = undefined;
        if (numCaptured <= 3) {
            obj = try self.allocPoolObject();
        } else {
            const objSlice = try self.alloc.alignedAlloc(Value, @alignOf(HeapObject), 2 + numCaptured);
            obj = @ptrCast(*HeapObject, objSlice.ptr);
        }
        obj.closure = .{
            .structId = ClosureS,
            .rc = 1,
            .funcPc = @intCast(u32, funcPc),
            .numParams = numParams,
            .numLocals = numLocals,
            .numCaptured = numCaptured,
            .padding = undefined,
            .firstCapturedVal = undefined,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        const dst = obj.closure.getCapturedValuesPtr()[0..numCaptured];
        std.mem.set(Value, dst, Value.None);
        return Value.initPtr(obj);
    }

    fn allocClosure(self: *VM, framePtr: [*]Value, funcPc: usize, numParams: u8, numLocals: u8, capturedVals: []const cy.OpData) !Value {
        var obj: *HeapObject = undefined;
        if (capturedVals.len <= 3) {
            obj = try self.allocPoolObject();
        } else {
            const objSlice = try self.alloc.alignedAlloc(Value, @alignOf(HeapObject), 2 + capturedVals.len);
            obj = @ptrCast(*HeapObject, objSlice.ptr);
        }
        obj.closure = .{
            .structId = ClosureS,
            .rc = 1,
            .funcPc = @intCast(u32, funcPc),
            .numParams = numParams,
            .numLocals = numLocals,
            .numCaptured = @intCast(u8, capturedVals.len),
            .padding = undefined,
            .firstCapturedVal = undefined,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        const dst = obj.closure.getCapturedValuesPtr();
        for (capturedVals) |local, i| {
            dst[i] = framePtr[local.arg];
        }
        return Value.initPtr(obj);
    }

    pub fn allocOpaquePtr(self: *VM, ptr: ?*anyopaque) !Value {
        const obj = try self.allocPoolObject();
        obj.opaquePtr = .{
            .structId = OpaquePtrS,
            .rc = 1,
            .ptr = ptr,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            gvm.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocDir(self: *VM, fd: std.os.fd_t, iterable: bool) linksection(StdSection) !Value {
        const obj = try self.allocPoolObject();
        obj.dir = .{
            .structId = DirT,
            .rc = 1,
            .fd = fd,
            .iterable = iterable,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocFile(self: *VM, fd: std.os.fd_t) linksection(StdSection) !Value {
        const obj = try self.allocPoolObject();
        obj.file = .{
            .structId = FileT,
            .rc = 1,
            .fd = fd,
            .curPos = 0,
            .iterLines = false,
            .hasReadBuf = false,
            .readBuf = undefined,
            .readBufCap = 0,
            .readBufEnd = 0,
            .closed = false,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocDirIterator(self: *VM, dir: *Dir, recursive: bool) linksection(StdSection) !Value {
        const objSlice = try self.alloc.alignedAlloc(u8, @alignOf(HeapObject), @sizeOf(DirIterator));
        const obj = @ptrCast(*DirIterator, objSlice.ptr);
        obj.* = .{
            .structId = DirIteratorT,
            .rc = 1,
            .dir = dir,
            .inner = undefined,
            .recursive = recursive,
        };
        if (recursive) {
            const walker = stdx.ptrAlignCast(*std.fs.IterableDir.Walker, &obj.inner.walker);
            walker.* = try dir.getStdIterableDir().walk(self.alloc);
        } else {
            const iter = stdx.ptrAlignCast(*std.fs.IterableDir.Iterator, &obj.inner.iter);
            iter.* = dir.getStdIterableDir().iterate();
        }
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocTccState(self: *VM, state: *tcc.TCCState, lib: *std.DynLib) linksection(StdSection) !Value {
        const obj = try self.allocPoolObject();
        obj.tccState = .{
            .structId = TccStateS,
            .rc = 1,
            .state = state,
            .lib = lib,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocNativeFunc1(self: *VM, func: *const fn (*UserVM, [*]Value, u8) Value, numParams: u32, tccState: ?Value) !Value {
        const obj = try self.allocPoolObject();
        obj.nativeFunc1 = .{
            .structId = NativeFunc1S,
            .rc = 1,
            .func = func,
            .numParams = numParams,
            .tccState = undefined,
            .hasTccState = false,
        };
        if (tccState) |state| {
            obj.nativeFunc1.tccState = state;
            obj.nativeFunc1.hasTccState = true;
        }
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocStringTemplate(self: *VM, strs: []const cy.OpData, vals: []const Value) !Value {
        const firstStr = self.valueAsStaticString(Value.initRaw(self.consts[strs[0].arg].val));
        try self.u8Buf.resize(self.alloc, firstStr.len);
        std.mem.copy(u8, self.u8Buf.items(), firstStr);

        const writer = self.u8Buf.writer(self.alloc);
        for (vals) |val, i| {
            self.writeValueToString(writer, val);
            release(self, val);
            try self.u8Buf.appendSlice(self.alloc, self.valueAsStaticString(Value.initRaw(self.consts[strs[i+1].arg].val)));
        }

        // TODO: As string is built, accumulate charLen and detect rawstring to avoid doing validation.
        return self.getOrAllocStringInfer(self.u8Buf.items());
    }

    pub fn getOrAllocOwnedAstring(self: *VM, obj: *HeapObject) linksection(cy.HotSection) !Value {
        return self.getOrAllocOwnedString(obj, obj.astring.getConstSlice());
    }

    pub fn getOrAllocOwnedUstring(self: *VM, obj: *HeapObject) linksection(cy.HotSection) !Value {
        return self.getOrAllocOwnedString(obj, obj.ustring.getConstSlice());
    }

    // If no such string intern exists, `obj` is added as a string intern.
    // Otherwise, `obj` is released and the existing string intern is retained and returned.
    pub fn getOrAllocOwnedString(self: *VM, obj: *HeapObject, str: []const u8) linksection(cy.HotSection) !Value {
        if (str.len <= DefaultStringInternMaxByteLen) {
            const res = try self.strInterns.getOrPut(self.alloc, str);
            if (res.found_existing) {
                releaseObject(self, obj);
                self.retainObject(res.value_ptr.*);
                return Value.initPtr(res.value_ptr.*);
            } else {
                res.key_ptr.* = str;
                res.value_ptr.* = obj;
                return Value.initPtr(obj);
            }
        } else {
            return Value.initPtr(obj);
        }
    }

    pub fn allocRawStringSlice(self: *VM, slice: []const u8, parent: *HeapObject) !Value {
        const obj = try self.allocPoolObject();
        obj.rawstringSlice = .{
            .structId = RawStringSliceT,
            .rc = 1,
            .buf = slice.ptr,
            .len = @intCast(u32, slice.len),
            .parent = @ptrCast(*RawString, parent),
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocUstringSlice(self: *VM, slice: []const u8, charLen: u32, parent: ?*HeapObject) !Value {
        const obj = try self.allocPoolObject();
        obj.stringSlice = .{
            .structId = StringSliceT,
            .rc = 1,
            .buf = slice.ptr,
            .len = @intCast(u32, slice.len),
            .uCharLen = charLen,
            .uMruIdx = 0,
            .uMruCharIdx = 0,
            .extra = @intCast(u63, @ptrToInt(parent)),
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocAstringSlice(self: *VM, slice: []const u8, parent: *HeapObject) !Value {
        const obj = try self.allocPoolObject();
        obj.stringSlice = .{
            .structId = StringSliceT,
            .rc = 1,
            .buf = slice.ptr,
            .len = @intCast(u32, slice.len),
            .uCharLen = undefined,
            .uMruIdx = undefined,
            .uMruCharIdx = undefined,
            .extra = @as(u64, @ptrToInt(parent)) | (1 << 63),
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn allocUstring(self: *VM, str: []const u8, charLen: u32) linksection(cy.Section) !Value {
        const obj = try self.allocUstringObject(str, charLen);
        return Value.initPtr(obj);
    }

    pub fn allocAstring(self: *VM, str: []const u8) linksection(cy.Section) !Value {
        const obj = try self.allocUnsetAstringObject(str.len);
        const dst = obj.astring.getSlice();
        std.mem.copy(u8, dst, str);
        return Value.initPtr(obj);
    }

    pub fn allocUstringObject(self: *VM, str: []const u8, charLen: u32) linksection(cy.Section) !*HeapObject {
        const obj = try self.allocUnsetUstringObject(str.len, charLen);
        const dst = obj.ustring.getSlice();
        std.mem.copy(u8, dst, str);
        return obj;
    }

    pub fn allocUnsetUstringObject(self: *VM, len: usize, charLen: u32) linksection(cy.Section) !*HeapObject {
        var obj: *HeapObject = undefined;
        if (len <= MaxPoolObjectUstringByteLen) {
            obj = try self.allocPoolObject();
        } else {
            const objSlice = try self.alloc.alignedAlloc(u8, @alignOf(HeapObject), len + Ustring.BufOffset);
            obj = @ptrCast(*HeapObject, objSlice.ptr);
        }
        obj.ustring = .{
            .structId = UstringT,
            .rc = 1,
            .len = @intCast(u32, len),
            .charLen = charLen,
            .mruIdx = 0,
            .mruCharIdx = 0,
            .bufStart = undefined,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return obj;
    }

    pub fn allocUnsetAstringObject(self: *VM, len: usize) linksection(cy.Section) !*HeapObject {
        var obj: *HeapObject = undefined;
        if (len <= MaxPoolObjectAstringByteLen) {
            obj = try self.allocPoolObject();
        } else {
            const objSlice = try self.alloc.alignedAlloc(u8, @alignOf(HeapObject), len + Astring.BufOffset);
            obj = @ptrCast(*HeapObject, objSlice.ptr);
        }
        obj.astring = .{
            .structId = AstringT,
            .rc = 1,
            .len = @intCast(u32, len),
            .bufStart = undefined,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return obj;
    }

    pub fn allocUnsetRawStringObject(self: *VM, len: usize) linksection(cy.Section) !*HeapObject {
        var obj: *HeapObject = undefined;
        if (len <= MaxPoolObjectRawStringByteLen) {
            obj = try self.allocPoolObject();
        } else {
            const objSlice = try self.alloc.alignedAlloc(u8, @alignOf(HeapObject), len + RawString.BufOffset);
            obj = @ptrCast(*HeapObject, objSlice.ptr);
        }
        obj.rawstring = .{
            .structId = RawStringT,
            .rc = 1,
            .len = @intCast(u32, len),
            .bufStart = undefined,
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return obj;
    }

    pub fn allocRawString(self: *VM, str: []const u8) linksection(cy.Section) !Value {
        const obj = try self.allocUnsetRawStringObject(str.len);
        const dst = @ptrCast([*]u8, &obj.rawstring.bufStart)[0..str.len];
        std.mem.copy(u8, dst, str);
        return Value.initPtr(obj);
    }

    fn getOrAllocStringInfer(self: *VM, str: []const u8) linksection(cy.Section) !Value {
        if (cy.validateUtf8(str)) |charLen| {
            if (str.len == charLen) {
                return try self.getOrAllocAstring(str);
            } else {
                return try self.getOrAllocUstring(str, @intCast(u32, charLen));
            }
        } else {
            return self.allocRawString(str);
        }
    }

    pub fn getOrAllocUstring(self: *VM, str: []const u8, charLen: u32) linksection(cy.Section) !Value {
        if (str.len <= DefaultStringInternMaxByteLen) {
            const res = try self.strInterns.getOrPut(self.alloc, str);
            if (res.found_existing) {
                self.retainObject(res.value_ptr.*);
                return Value.initPtr(res.value_ptr.*);
            } else {
                const obj = try self.allocUstringObject(str, charLen);
                res.key_ptr.* = obj.ustring.getConstSlice();
                res.value_ptr.* = obj;
                return Value.initPtr(obj);
            }
        } else {
            const obj = try self.allocUstringObject(str, charLen);
            return Value.initPtr(obj);
        }
    }

    pub fn getOrAllocAstring(self: *VM, str: []const u8) linksection(cy.Section) !Value {
        if (str.len <= DefaultStringInternMaxByteLen) {
            const res = try self.strInterns.getOrPut(self.alloc, str);
            if (res.found_existing) {
                self.retainObject(res.value_ptr.*);
                return Value.initPtr(res.value_ptr.*);
            } else {
                const obj = try self.allocAstringObject(str);
                res.key_ptr.* = obj.astring.getConstSlice();
                res.value_ptr.* = obj;
                return Value.initPtr(obj);
            }
        } else {
            const obj = try self.allocAstringObject(str);
            return Value.initPtr(obj);
        }
    }

    fn allocRawStringConcat(self: *VM, str: []const u8, str2: []const u8) linksection(cy.Section) !Value {
        const len = @intCast(u32, str.len + str2.len);
        var obj: *HeapObject = undefined;
        if (len <= MaxPoolObjectRawStringByteLen) {
            obj = try self.allocPoolObject();
        } else {
            const objSlice = try self.alloc.alignedAlloc(u8, @alignOf(HeapObject), len + 12);
            obj = @ptrCast(*HeapObject, objSlice.ptr);
        }
        obj.rawstring = .{
            .structId = RawStringT,
            .rc = 1,
            .len = len,
            .bufStart = undefined,
        };
        const dst = @ptrCast([*]u8, &obj.rawstring.bufStart)[0..len];
        std.mem.copy(u8, dst[0..str.len], str);
        std.mem.copy(u8, dst[str.len..], str2);
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    fn allocUstringConcat3Object(self: *VM, str1: []const u8, str2: []const u8, str3: []const u8, charLen: u32) linksection(cy.Section) !*HeapObject {
        const obj = try self.allocUnsetUstringObject(str1.len + str2.len + str3.len, charLen);
        const dst = obj.ustring.getSlice();
        std.mem.copy(u8, dst[0..str1.len], str1);
        std.mem.copy(u8, dst[str1.len..str1.len+str2.len], str2);
        std.mem.copy(u8, dst[str1.len+str2.len..], str3);
        return obj;
    }

    fn allocUstringConcatObject(self: *VM, str1: []const u8, str2: []const u8, charLen: u32) linksection(cy.Section) !*HeapObject {
        const obj = try self.allocUnsetUstringObject(str1.len + str2.len, charLen);
        const dst = obj.ustring.getSlice();
        std.mem.copy(u8, dst[0..str1.len], str1);
        std.mem.copy(u8, dst[str1.len..], str2);
        return obj;
    }
    
    fn allocAstringObject(self: *VM, str: []const u8) linksection(cy.Section) !*HeapObject {
        const obj = try self.allocUnsetAstringObject(str.len);
        const dst = obj.astring.getSlice();
        std.mem.copy(u8, dst, str);
        return obj;
    }

    fn allocAstringConcat3Object(self: *VM, str1: []const u8, str2: []const u8, str3: []const u8) linksection(cy.Section) !*HeapObject {
        const obj = try self.allocUnsetAstringObject(str1.len + str2.len + str3.len);
        const dst = obj.astring.getSlice();
        std.mem.copy(u8, dst[0..str1.len], str1);
        std.mem.copy(u8, dst[str1.len..str1.len+str2.len], str2);
        std.mem.copy(u8, dst[str1.len+str2.len..], str3);
        return obj;
    }

    fn allocAstringConcatObject(self: *VM, str1: []const u8, str2: []const u8) linksection(cy.Section) !*HeapObject {
        const obj = try self.allocUnsetAstringObject(str1.len + str2.len);
        const dst = obj.astring.getSlice();
        std.mem.copy(u8, dst[0..str1.len], str1);
        std.mem.copy(u8, dst[str1.len..], str2);
        return obj;
    }

    fn getOrAllocAstringConcat(self: *VM, str: []const u8, str2: []const u8) linksection(cy.Section) !Value {
        if (str.len + str2.len <= DefaultStringInternMaxByteLen) {
            const ctx = StringConcatContext{};
            const concat = StringConcat{
                .left = str,
                .right = str2,
            };
            const res = try self.strInterns.getOrPutAdapted(self.alloc, concat, ctx);
            if (res.found_existing) {
                self.retainObject(res.value_ptr.*);
                return Value.initPtr(res.value_ptr.*);
            } else {
                const obj = try self.allocAstringConcatObject(str, str2);
                res.key_ptr.* = obj.astring.getConstSlice();
                res.value_ptr.* = obj;
                return Value.initPtr(obj);
            }
        } else {
            const obj = try self.allocAstringConcatObject(str, str2);
            return Value.initPtr(obj);
        }
    }

    fn getOrAllocAstringConcat3(self: *VM, str1: []const u8, str2: []const u8, str3: []const u8) linksection(cy.Section) !Value {
        if (str1.len + str2.len + str3.len <= DefaultStringInternMaxByteLen) {
            const ctx = StringConcat3Context{};
            const concat = StringConcat3{
                .str1 = str1,
                .str2 = str2,
                .str3 = str3,
            };
            const res = try self.strInterns.getOrPutAdapted(self.alloc, concat, ctx);
            if (res.found_existing) {
                self.retainObject(res.value_ptr.*);
                return Value.initPtr(res.value_ptr.*);
            } else {
                const obj = try self.allocAstringConcat3Object(str1, str2, str3);
                res.key_ptr.* = obj.astring.getConstSlice();
                res.value_ptr.* = obj;
                return Value.initPtr(obj);
            }
        } else {
            const obj = try self.allocAstringConcat3Object(str1, str2, str3);
            return Value.initPtr(obj);
        }
    }

    fn getOrAllocUstringConcat3(self: *VM, str1: []const u8, str2: []const u8, str3: []const u8, charLen: u32) linksection(cy.Section) !Value {
        if (str1.len + str2.len + str3.len <= DefaultStringInternMaxByteLen) {
            const ctx = StringConcat3Context{};
            const concat = StringConcat3{
                .str1 = str1,
                .str2 = str2,
                .str3 = str3,
            };
            const res = try self.strInterns.getOrPutAdapted(self.alloc, concat, ctx);
            if (res.found_existing) {
                self.retainObject(res.value_ptr.*);
                return Value.initPtr(res.value_ptr.*);
            } else {
                const obj = try self.allocUstringConcat3Object(str1, str2, str3, charLen);
                res.key_ptr.* = obj.ustring.getConstSlice();
                res.value_ptr.* = obj;
                return Value.initPtr(obj);
            }
        } else {
            const obj = try self.allocUstringConcat3Object(str1, str2, str3, charLen);
            return Value.initPtr(obj);
        }
    }

    fn getOrAllocUstringConcat(self: *VM, str: []const u8, str2: []const u8, charLen: u32) linksection(cy.Section) !Value {
        if (str.len + str2.len <= DefaultStringInternMaxByteLen) {
            const ctx = StringConcatContext{};
            const concat = StringConcat{
                .left = str,
                .right = str2,
            };
            const res = try self.strInterns.getOrPutAdapted(self.alloc, concat, ctx);
            if (res.found_existing) {
                self.retainObject(res.value_ptr.*);
                return Value.initPtr(res.value_ptr.*);
            } else {
                const obj = try self.allocUstringConcatObject(str, str2, charLen);
                res.key_ptr.* = obj.ustring.getConstSlice();
                res.value_ptr.* = obj;
                return Value.initPtr(obj);
            }
        } else {
            const obj = try self.allocUstringConcatObject(str, str2, charLen);
            return Value.initPtr(obj);
        }
    }

    pub fn allocOwnedList(self: *VM, elems: []Value) !Value {
        const obj = try self.allocPoolObject();
        obj.list = .{
            .structId = ListS,
            .rc = 1,
            .list = .{
                .ptr = elems.ptr,
                .len = elems.len,
                .cap = elems.len,
            },
        };
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        if (TrackGlobalRC) {
            gvm.refCounts += 1;
        }
        return Value.initPtr(obj);
    }

    fn allocListFill(self: *VM, val: Value, n: u32) linksection(StdSection) !Value {
        const obj = try self.allocPoolObject();
        obj.list = .{
            .structId = ListS,
            .rc = 1,
            .list = .{
                .ptr = undefined,
                .len = 0,
                .cap = 0,
            },
        };
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
        // Initializes capacity to exact size.
        try list.ensureTotalCapacityPrecise(self.alloc, n);
        list.len = n;
        if (!val.isPointer()) {
            std.mem.set(Value, list.items(), val);
        } else {
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                list.buf[i] = shallowCopy(self, val);
            }
        }
        return Value.initPtr(obj);
    }

    fn allocList(self: *VM, elems: []const Value) linksection(cy.HotSection) !Value {
        const obj = try self.allocPoolObject();
        obj.list = .{
            .structId = ListS,
            .rc = 1,
            .list = .{
                .ptr = undefined,
                .len = 0,
                .cap = 0,
            },
        };
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
        // Initializes capacity to exact size.
        try list.ensureTotalCapacityPrecise(self.alloc, elems.len);
        list.len = elems.len;
        std.mem.copy(Value, list.items(), elems);
        return Value.initPtr(obj);
    }

    /// Assumes list is already retained for the iterator.
    fn allocListIterator(self: *VM, list: *List) linksection(cy.HotSection) !Value {
        const obj = try self.allocPoolObject();
        obj.listIter = .{
            .structId = ListIteratorT,
            .rc = 1,
            .list = list,
            .nextIdx = 0,
        };
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        return Value.initPtr(obj);
    }

    /// Assumes map is already retained for the iterator.
    fn allocMapIterator(self: *VM, map: *Map) linksection(cy.HotSection) !Value {
        const obj = try self.allocPoolObject();
        obj.mapIter = .{
            .structId = MapIteratorT,
            .rc = 1,
            .map = map,
            .nextIdx = 0,
        };
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
        return Value.initPtr(obj);
    }

    pub fn ensureTagType(self: *VM, name: []const u8) !TagTypeId {
        const res = try self.tagTypeSignatures.getOrPut(self.alloc, name);
        if (!res.found_existing) {
            return self.addTagType(name);
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn ensureStruct(self: *VM, nameId: sema.NameSymId, uniqId: u32) !StructId {
        const res = try @call(.never_inline, self.structSignatures.getOrPut, .{self.alloc, .{
            .structKey = .{
                .nameId = nameId,
                .uniqId = uniqId,
            },
        }});
        if (!res.found_existing) {
            return self.addStructExt(nameId, uniqId);
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn getStructFieldIdx(self: *const VM, sid: StructId, propName: []const u8) ?u32 {
        const fieldId = self.fieldSymSignatures.get(propName) orelse return null;
        const entry = &self.fieldSyms.buf[fieldId];

        if (entry.mruStructId == sid) {
            return entry.mruOffset;
        } else {
            const offset = self.fieldTable.get(.{ .structId = sid, .symId = fieldId }) orelse return null;
            entry.mruStructId = sid;
            entry.mruOffset = offset;
            return offset;
        }
    }

    pub fn addTagType(self: *VM, name: []const u8) !TagTypeId {
        const s = TagType{
            .name = name,
            .numMembers = 0,
        };
        const id = @intCast(u32, self.tagTypes.len);
        try self.tagTypes.append(self.alloc, s);
        try self.tagTypeSignatures.put(self.alloc, name, id);
        return id;
    }

    pub inline fn getStruct(self: *const VM, nameId: sema.NameSymId, uniqId: u32) ?StructId {
        return self.structSignatures.get(.{
            .structKey = .{
                .nameId = nameId,
                .uniqId = uniqId,
            },
        });
    }

    pub fn addStructExt(self: *VM, nameId: sema.NameSymId, uniqId: u32) !StructId {
        const name = sema.getName(&self.compiler, nameId);
        const s = Struct{
            .name = name,
            .numFields = 0,
        };
        const vm = self.getVM();
        const id = @intCast(u32, vm.structs.len);
        try vm.structs.append(vm.alloc, s);
        try vm.structSignatures.put(vm.alloc, .{
            .structKey = .{
                .nameId = nameId,
                .uniqId = uniqId,
            },
        }, id);
        return id;
    }

    pub fn addStruct(self: *VM, name: []const u8) !StructId {
        const nameId = try sema.ensureNameSym(&self.compiler, name);
        return self.addStructExt(nameId, 0);
    }

    inline fn getVM(self: *VM) *VM {
        if (UseGlobalVM) {
            return &gvm;
        } else {
            return self;
        }
    }

    pub inline fn getFuncSym(self: *const VM, resolvedParentId: u32, nameId: u32, numParams: u32) ?SymbolId {
        const key = AbsFuncSigKey{
            .rtFuncSymKey = .{
                .resolvedParentSymId = resolvedParentId,
                .nameId = nameId,
                .numParams = numParams,
            },
        };
        return self.funcSymSigs.get(key);
    }

    pub inline fn getVarSym(self: *const VM, resolvedParentId: u32, nameId: u32) ?SymbolId {
        const key = AbsVarSigKey{
            .rtVarSymKey = .{
                .resolvedParentSymId = resolvedParentId,
                .nameId = nameId,
            }
        };
        return self.varSymSigs.get(key);
    }

    pub fn ensureVarSym(self: *VM, parentId: SymbolId, nameId: u32) !SymbolId {
        const key = KeyU64{
            .rtVarSymKey = .{
                .resolvedParentSymId = parentId,
                .nameId = nameId,
            },
        };
        const res = try self.varSymSigs.getOrPut(self.alloc, key);
        if (!res.found_existing) {
            const id = @intCast(u32, self.varSyms.len);
            try self.varSyms.append(self.alloc, VarSym.init(Value.None));
            res.value_ptr.* = id;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }
    
    pub fn ensureFuncSym(self: *VM, resolvedParentId: SymbolId, nameId: u32, numParams: u32) !SymbolId {
        const key = KeyU96{
            .rtFuncSymKey = .{
                .resolvedParentSymId = resolvedParentId,
                .nameId = nameId,
                .numParams = numParams,
            },
        };
        const res = try self.funcSymSigs.getOrPut(self.alloc, key);
        if (!res.found_existing) {
            const id = @intCast(u32, self.funcSyms.len);
            try self.funcSyms.append(self.alloc, .{
                .entryT = @enumToInt(FuncSymbolEntryType.none),
                .inner = undefined,
            });
            res.value_ptr.* = id;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn getTagLitName(self: *const VM, id: u32) []const u8 {
        return self.tagLitSyms.buf[id].name;
    }

    pub fn ensureTagLitSym(self: *VM, name: []const u8) !SymbolId {
        _ = self;
        const res = try gvm.tagLitSymSignatures.getOrPut(gvm.alloc, name);
        if (!res.found_existing) {
            const id = @intCast(u32, gvm.tagLitSyms.len);
            try gvm.tagLitSyms.append(gvm.alloc, .{
                .symT = .empty,
                .inner = undefined,
                .name = name,
            });
            res.value_ptr.* = id;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn ensureFieldSym(self: *VM, name: []const u8) !SymbolId {
        const res = try self.fieldSymSignatures.getOrPut(self.alloc, name);
        if (!res.found_existing) {
            const id = @intCast(u32, self.fieldSyms.len);
            try self.fieldSyms.append(self.alloc, .{
                .mruStructId = NullId,
                .mruOffset = undefined,
                .name = name,
            });
            res.value_ptr.* = id;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn hasMethodSym(self: *const VM, sid: StructId, methodId: SymbolId) bool {
        const map = self.methodSyms.buf[methodId];
        if (map.mapT == .one) {
            return map.inner.one.id == sid;
        }
        return false;
    }

    pub fn ensureMethodSymKey(self: *VM, name: []const u8, numParams: u32) !SymbolId {
        const nameId = try sema.ensureNameSym(&self.compiler, name);
        const key = RelFuncSigKey{
            .relFuncSigKey = .{
                .nameId = nameId,
                .numParams = numParams,
            },
        };
        const res = try @call(.never_inline, self.methodSymSigs.getOrPut, .{self.alloc, key});
        if (!res.found_existing) {
            const id = @intCast(u32, self.methodSyms.len);
            try self.methodSyms.append(self.alloc, .{
                .entryT = undefined,
                .mruStructId = NullId,
                .inner = undefined,
            });
            try self.methodSymExtras.append(self.alloc, name);
            res.value_ptr.* = id;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn addFieldSym(self: *VM, sid: StructId, symId: SymbolId, offset: u16) !void {
        const sym = &self.fieldSyms.buf[symId];
        if (sym.mruStructId != NullId) {
            // Add prev mru if it doesn't exist in hashmap.
            const prev = ObjectSymKey{
                .structId = sym.mruStructId,
                .symId = symId,
            };
            if (!self.fieldTable.contains(prev)) {
                try self.fieldTable.putNoClobber(self.alloc, prev, sym.mruOffset);
            }
            const key = ObjectSymKey{
                .structId = sid,
                .symId = symId,
            };
            try self.fieldTable.putNoClobber(self.alloc, key, offset);
            sym.mruStructId = sid;
            sym.mruOffset = offset;
        } else {
            sym.mruStructId = sid;
            sym.mruOffset = offset;
        }
    }

    pub inline fn setTagLitSym(self: *VM, tid: TagTypeId, symId: SymbolId, val: u32) void {
        self.tagLitSyms.buf[symId].symT = .one;
        self.tagLitSyms.buf[symId].inner = .{
            .one = .{
                .id = tid,
                .val = val,
            },
        };
    }

    pub inline fn setVarSym(self: *VM, symId: SymbolId, sym: VarSym) void {
        self.varSyms.buf[symId] = sym;
    }

    pub inline fn setFuncSym(self: *VM, symId: SymbolId, sym: FuncSymbolEntry) void {
        self.funcSyms.buf[symId] = sym;
    }

    pub fn addMethodSym(self: *VM, id: StructId, symId: SymbolId, entry: MethodSym) !void {
        const sym = &self.methodSyms.buf[symId];
        if (sym.mruStructId != NullId) {
            const prev = ObjectSymKey{
                .structId = sym.mruStructId,
                .symId = symId,
            };
            if (!self.methodTable.contains(prev)) {
                try self.methodTable.putNoClobber(self.alloc, prev, sym.*);
            }
            const key = ObjectSymKey{
                .structId = id,
                .symId = symId,
            };
            try self.methodTable.putNoClobber(self.alloc, key, entry);
            sym.* = .{
                .entryT = entry.entryT,
                .mruStructId = id,
                .inner = entry.inner,
            };
        } else {
            sym.* = .{
                .entryT = entry.entryT,
                .mruStructId = id,
                .inner = entry.inner,
            };
        }
    }

    pub fn setIndexRelease(self: *VM, left: Value, index: Value, right: Value) !void {
        if (left.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, left.asPointer().?);
            switch (obj.retainedCommon.structId) {
                ListS => {
                    const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
                    const idx = @floatToInt(u32, index.toF64());
                    if (idx < list.len) {
                        release(self, list.buf[idx]);
                        list.buf[idx] = right;
                    } else {
                        // var i: u32 = @intCast(u32, list.val.items.len);
                        // try list.val.resize(self.alloc, idx + 1);
                        // while (i < idx) : (i += 1) {
                        //     list.val.items[i] = Value.None;
                        // }
                        // list.val.items[idx] = right;
                        return self.panic("Index out of bounds.");
                    }
                },
                MapS => {
                    const map = stdx.ptrAlignCast(*MapInner, &obj.map.inner);
                    const res = try map.getOrPut(self.alloc, self, index);
                    if (res.foundExisting) {
                        release(self, res.valuePtr.*);
                    }
                    res.valuePtr.* = right;
                },
                else => {
                    return stdx.panic("unsupported struct");
                },
            }
        } else {
            return stdx.panic("expected pointer");
        }
    }

    pub fn setIndex(self: *VM, left: Value, index: Value, right: Value) !void {
        if (left.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, left.asPointer().?);
            switch (obj.retainedCommon.structId) {
                ListS => {
                    const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
                    const idx = @floatToInt(u32, index.toF64());
                    if (idx < list.len) {
                        list.buf[idx] = right;
                    } else {
                        // var i: u32 = @intCast(u32, list.val.items.len);
                        // try list.val.resize(self.alloc, idx + 1);
                        // while (i < idx) : (i += 1) {
                        //     list.val.items[i] = Value.None;
                        // }
                        // list.val.items[idx] = right;
                        return self.panic("Index out of bounds.");
                    }
                },
                MapS => {
                    const map = stdx.ptrAlignCast(*MapInner, &obj.map.inner);
                    try map.put(self.alloc, self, index, right);
                },
                else => {
                    log.debug("unsupported object: {}", .{obj.retainedCommon.structId});
                    stdx.fatal();
                },
            }
        } else {
            return stdx.panic("expected pointer");
        }
    }

    /// Assumes sign of index is preserved.
    fn getReverseIndex(self: *VM, left: *Value, index: Value) linksection(cy.Section) !Value {
        if (left.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, left.asPointer().?);
            switch (obj.retainedCommon.structId) {
                ListS => {
                    const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
                    const idx = @intCast(i32, list.len) + @floatToInt(i32, index.toF64());
                    if (idx < list.len) {
                        const res = list.buf[@intCast(u32, idx)];
                        retain(self, res);
                        return res;
                    } else {
                        return error.OutOfBounds;
                    }
                },
                MapS => {
                    const map = stdx.ptrAlignCast(*MapInner, &obj.map.inner);
                    const key = Value.initF64(index.toF64());
                    if (map.get(self, key)) |val| {
                        retain(self, val);
                        return val;
                    } else return Value.None;
                },
                AstringT => {
                    const idx = @intToFloat(f64, @intCast(i32, obj.astring.len) + @floatToInt(i32, index.toF64()));
                    retainObject(self, obj);
                    return bindings.stringCharAt(.astring)(@ptrCast(*UserVM, self), obj, &[_]Value{Value.initF64(idx)}, 1);
                },
                UstringT => {
                    const idx = @intToFloat(f64, @intCast(i32, obj.ustring.charLen) + @floatToInt(i32, index.toF64()));
                    retainObject(self, obj);
                    return bindings.stringCharAt(.ustring)(@ptrCast(*UserVM, self), obj, &[_]Value{Value.initF64(idx)}, 1);
                },
                StringSliceT => {
                    if (obj.stringSlice.isAstring()) {
                        const idx = @intToFloat(f64, @intCast(i32, obj.stringSlice.len) + @floatToInt(i32, index.toF64()));
                        retainObject(self, obj);
                        return bindings.stringCharAt(.slice)(@ptrCast(*UserVM, self), obj, &[_]Value{Value.initF64(idx)}, 1);
                    } else {
                        const idx = @intToFloat(f64, @intCast(i32, obj.stringSlice.uCharLen) + @floatToInt(i32, index.toF64()));
                        retainObject(self, obj);
                        return bindings.stringCharAt(.slice)(@ptrCast(*UserVM, self), obj, &[_]Value{Value.initF64(idx)}, 1);
                    }
                },
                RawStringT => {
                    const idx = @intToFloat(f64, @intCast(i32, obj.rawstring.len) + @floatToInt(i32, index.toF64()));
                    retainObject(self, obj);
                    return bindings.stringCharAt(.rawstring)(@ptrCast(*UserVM, self), obj, &[_]Value{Value.initF64(idx)}, 1);
                },
                RawStringSliceT => {
                    const idx = @intToFloat(f64, @intCast(i32, obj.rawstringSlice.len) + @floatToInt(i32, index.toF64()));
                    retainObject(self, obj);
                    return bindings.stringCharAt(.rawSlice)(@ptrCast(*UserVM, self), obj, &[_]Value{Value.initF64(idx)}, 1);
                },
                else => {
                    return self.panicFmt("Unsupported reverse index operation on type `{}`.", &.{v(self.structs.buf[obj.common.structId].name)});
                },
            }
        } else {
            if (left.isNumber()) {
                return self.panic("Unsupported reverse index operation on type `number`.");
            } else {
                switch (left.getTag()) {
                    cy.StaticAstringT => {
                        const idx = @intToFloat(f64, @intCast(i32, left.asStaticStringSlice().len()) + @floatToInt(i32, index.toF64()));
                        return bindings.stringCharAt(.staticAstring)(@ptrCast(*UserVM, self), left, &[_]Value{Value.initF64(idx)}, 1);
                    },
                    cy.StaticUstringT => {
                        const start = left.asStaticStringSlice().start;
                        const idx = @intToFloat(f64, @intCast(i32, getStaticUstringHeader(self, start).charLen) + @floatToInt(i32, index.toF64()));
                        return bindings.stringCharAt(.staticUstring)(@ptrCast(*UserVM, self), left, &[_]Value{Value.initF64(idx)}, 1);
                    },
                    else => {
                        return self.panicFmt("Unsupported reverse index operation on type `{}`.", &.{v(@intCast(u8, left.getTag()))});
                    },
                }
            }
        }
    }

    fn getIndex(self: *VM, left: *Value, index: Value) linksection(cy.Section) !Value {
        if (left.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, left.asPointer().?);
            switch (obj.retainedCommon.structId) {
                ListS => {
                    const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
                    const idx = @floatToInt(u32, index.toF64());
                    if (idx < list.len) {
                        retain(self, list.buf[idx]);
                        return list.buf[idx];
                    } else {
                        return error.OutOfBounds;
                    }
                },
                MapS => {
                    const map = stdx.ptrAlignCast(*MapInner, &obj.map.inner);
                    if (@call(.never_inline, map.get, .{self, index})) |val| {
                        retain(self, val);
                        return val;
                    } else return Value.None;
                },
                AstringT => {
                    retainObject(self, obj);
                    return bindings.stringCharAt(.astring)(@ptrCast(*UserVM, self), obj, &[_]Value{index}, 1);
                },
                UstringT => {
                    retainObject(self, obj);
                    return bindings.stringCharAt(.ustring)(@ptrCast(*UserVM, self), obj, &[_]Value{index}, 1);
                },
                StringSliceT => {
                    retainObject(self, obj);
                    return bindings.stringCharAt(.slice)(@ptrCast(*UserVM, self), obj, &[_]Value{index}, 1);
                },
                RawStringT => {
                    retainObject(self, obj);
                    return bindings.stringCharAt(.rawstring)(@ptrCast(*UserVM, self), obj, &[_]Value{index}, 1);
                },
                RawStringSliceT => {
                    retainObject(self, obj);
                    return bindings.stringCharAt(.rawSlice)(@ptrCast(*UserVM, self), obj, &[_]Value{index}, 1);
                },
                else => {
                    return self.panicFmt("Unsupported index operation on type `{}`.", &.{v(self.structs.buf[obj.common.structId].name)});
                },
            }
        } else {
            if (left.isNumber()) {
                return self.panic("Unsupported index operation on type `number`.");
            } else {
                switch (left.getTag()) {
                    cy.StaticAstringT => return bindings.stringCharAt(.staticAstring)(@ptrCast(*UserVM, self), left, &[_]Value{index}, 1),
                    cy.StaticUstringT => return bindings.stringCharAt(.staticUstring)(@ptrCast(*UserVM, self), left, &[_]Value{index}, 1),
                    else => {
                        return self.panicFmt("Unsupported index operation on type `{}`.", &.{v(@intCast(u8, left.getTag()))});
                    },
                }
            }
        }
    }

    fn panicFmt(self: *VM, format: []const u8, args: []const fmt.FmtValue) error{Panic, OutOfMemory} {
        @setCold(true);
        const msg = fmt.allocFormat(self.alloc, format, args) catch |err| {
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            } else {
                stdx.panic("unexpected");
            }
        };
        self.panicPayload = @intCast(u64, @ptrToInt(msg.ptr)) | (@as(u64, msg.len) << 48);
        self.panicType = .msg;
        log.debug("{s}", .{msg});
        return error.Panic;
    }

    fn panic(self: *VM, comptime msg: []const u8) error{Panic, OutOfMemory} {
        @setCold(true);
        const dupe = try self.alloc.dupe(u8, msg);
        self.panicPayload = @intCast(u64, @ptrToInt(dupe.ptr)) | (@as(u64, dupe.len) << 48);
        self.panicType = .msg;
        log.debug("{s}", .{dupe});
        return error.Panic;
    }

    pub fn getGlobalRC(self: *const VM) usize {
        if (TrackGlobalRC) {
            return self.refCounts;
        } else {
            stdx.panic("Enable TrackGlobalRC.");
        }
    }

    /// Performs an iteration over the heap pages to check whether there are retain cycles.
    pub fn checkMemory(self: *VM) !bool {
        var nodes: std.AutoHashMapUnmanaged(*HeapObject, RcNode) = .{};
        defer nodes.deinit(self.alloc);

        var cycleRoots: std.ArrayListUnmanaged(*HeapObject) = .{};
        defer cycleRoots.deinit(self.alloc);

        // No concept of root vars yet. Just report any existing retained objects.
        // First construct the graph.
        for (self.heapPages.items()) |page| {
            for (page.objects[1..]) |*obj| {
                if (obj.common.structId != NullId) {
                    try nodes.put(self.alloc, obj, .{
                        .visited = false,
                        .entered = false,
                    });
                }
            }
        }
        const S = struct {
            fn visit(alloc: std.mem.Allocator, graph: *std.AutoHashMapUnmanaged(*HeapObject, RcNode), cycleRoots_: *std.ArrayListUnmanaged(*HeapObject), obj: *HeapObject, node: *RcNode) bool {
                if (node.visited) {
                    return false;
                }
                if (node.entered) {
                    return true;
                }
                node.entered = true;

                switch (obj.retainedCommon.structId) {
                    ListS => {
                        const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
                        for (list.items()) |it| {
                            if (it.isPointer()) {
                                const ptr = stdx.ptrAlignCast(*HeapObject, it.asPointer().?);
                                if (visit(alloc, graph, cycleRoots_, ptr, graph.getPtr(ptr).?)) {
                                    cycleRoots_.append(alloc, obj) catch stdx.fatal();
                                    return true;
                                }
                            }
                        }
                    },
                    else => {
                    },
                }
                node.entered = false;
                node.visited = true;
                return false;
            }
        };
        var iter = nodes.iterator();
        while (iter.next()) |*entry| {
            if (S.visit(self.alloc, &nodes, &cycleRoots, entry.key_ptr.*, entry.value_ptr)) {
                if (TraceEnabled) {
                    self.trace.numRetainCycles = 1;
                    self.trace.numRetainCycleRoots = @intCast(u32, cycleRoots.items.len);
                }
                for (cycleRoots.items) |root| {
                    // Force release.
                    self.forceRelease(root);
                }
                return false;
            }
        }
        return true;
    }

    pub inline fn retainObject(self: *VM, obj: *HeapObject) linksection(cy.HotSection) void {
        obj.retainedCommon.rc += 1;
        log.debug("retain {} {}", .{obj.getUserTag(), obj.retainedCommon.rc});
        if (TrackGlobalRC) {
            self.refCounts += 1;
        }
        if (TraceEnabled) {
            self.trace.numRetains += 1;
            self.trace.numRetainAttempts += 1;
        }
    }

    pub inline fn retain(self: *VM, val: Value) linksection(cy.HotSection) void {
        if (TraceEnabled) {
            self.trace.numRetainAttempts += 1;
        }
        if (val.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer());
            obj.retainedCommon.rc += 1;
            log.debug("retain {} {}", .{obj.getUserTag(), obj.retainedCommon.rc});
            if (TrackGlobalRC) {
                self.refCounts += 1;
            }
            if (TraceEnabled) {
                self.trace.numRetains += 1;
            }
        }
    }

    pub inline fn retainInc(self: *const VM, val: Value, inc: u32) linksection(cy.HotSection) void {
        if (TraceEnabled) {
            self.trace.numRetainAttempts += inc;
        }
        if (val.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer());
            obj.retainedCommon.rc += inc;
            log.debug("retain {} {}", .{obj.getUserTag(), obj.retainedCommon.rc});
            if (TrackGlobalRC) {
                gvm.refCounts += inc;
            }
            if (TraceEnabled) {
                self.trace.numRetains += inc;
            }
        }
    }

    pub fn forceRelease(self: *VM, obj: *HeapObject) void {
        if (TraceEnabled) {
            self.trace.numForceReleases += 1;
        }
        switch (obj.retainedCommon.structId) {
            ListS => {
                const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
                list.deinit(self.alloc);
                self.freeObject(obj);
                if (TrackGlobalRC) {
                    gvm.refCounts -= obj.retainedCommon.rc;
                }
            },
            MapS => {
                const map = stdx.ptrAlignCast(*MapInner, &obj.map.inner);
                map.deinit(self.alloc);
                self.freeObject(obj);
                if (TrackGlobalRC) {
                    gvm.refCounts -= obj.retainedCommon.rc;
                }
            },
            else => {
                return stdx.panic("unsupported struct type");
            },
        }
    }

    fn setField(self: *VM, recv: Value, fieldId: SymbolId, val: Value) linksection(cy.HotSection) !void {
        if (recv.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer());
            const symMap = &self.fieldSyms.buf[fieldId];

            if (obj.common.structId == symMap.mruStructId) {
                obj.object.getValuePtr(symMap.mruOffset).* = val;
            } else {
                const offset = self.getFieldOffset(obj, fieldId);
                if (offset != NullByteId) {
                    symMap.mruStructId = obj.common.structId;
                    symMap.mruOffset = offset;
                    obj.object.getValuePtr(offset).* = val;
                } else {
                    return self.getFieldMissingSymbolError();
                }
            }
        } else {
            return self.setFieldNotObjectError();
        }
    }

    fn getFieldMissingSymbolError(self: *VM) error{Panic, OutOfMemory} {
        @setCold(true);
        return self.panic("Field not found in value.");
    }

    fn setFieldNotObjectError(self: *VM) !void {
        @setCold(true);
        return self.panic("Can't assign to value's field since the value is not an object.");
    }

    fn getFieldOffsetFromTable(self: *VM, sid: StructId, symId: SymbolId) u8 {
        if (self.fieldTable.get(.{ .structId = sid, .symId = symId })) |offset| {
            const sym = &self.fieldSyms.buf[symId];
            sym.mruStructId = sid;
            sym.mruOffset = offset;
            return @intCast(u8, offset);
        } else {
            return NullByteId;
        }
    }

    pub fn getFieldOffset(self: *VM, obj: *HeapObject, symId: SymbolId) linksection(cy.HotSection) u8 {
        const symMap = self.fieldSyms.buf[symId];
        if (obj.common.structId == symMap.mruStructId) {
            return @intCast(u8, symMap.mruOffset);
        } else {
            return @call(.never_inline, self.getFieldOffsetFromTable, .{obj.common.structId, symId});
        }
    }

    pub fn setFieldRelease(self: *VM, recv: Value, symId: SymbolId, val: Value) linksection(cy.HotSection) !void {
        @setCold(true);
        if (recv.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer().?);
            const offset = self.getFieldOffset(obj, symId);
            if (offset != NullByteId) {
                const lastValue = obj.object.getValuePtr(offset);
                release(self, lastValue.*);
                lastValue.* = val;
            } else {
                return self.getFieldMissingSymbolError();
            }
        } else {
            return self.getFieldMissingSymbolError();
        }
    }

    pub fn getField2(self: *VM, recv: Value, symId: SymbolId) linksection(cy.Section) !Value {
        if (recv.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer().?);
            const offset = self.getFieldOffset(obj, symId);
            if (offset != NullByteId) {
                return obj.object.getValue(offset);
            } else {
                return self.getFieldFallback(obj, self.fieldSyms.buf[symId].name);
            }
        } else {
            return self.getFieldMissingSymbolError();
        }
    }

    pub fn getField(self: *VM, recv: Value, symId: SymbolId) linksection(cy.HotSection) !Value {
        if (recv.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer().?);
            const offset = self.getFieldOffset(obj, symId);
            if (offset != NullByteId) {
                return obj.object.getValue(offset);
            } else {
                return self.getFieldFallback(obj, self.fieldSyms.buf[symId].name);
            }
        } else {
            return self.getFieldMissingSymbolError();
        }
    }

    fn getFieldFallback(self: *const VM, obj: *const HeapObject, name: []const u8) linksection(cy.HotSection) Value {
        @setCold(true);
        if (obj.common.structId == MapS) {
            const map = stdx.ptrAlignCast(*const MapInner, &obj.map.inner);
            if (map.getByString(self, name)) |val| {
                return val;
            } else return Value.None;
        } else {
            log.debug("Missing symbol for object: {}", .{obj.common.structId});
            return Value.None;
        }
    }

    /// startLocal points to the first arg in the current stack frame.
    fn callSym(self: *VM, pc: [*]cy.OpData, framePtr: [*]Value, symId: SymbolId, startLocal: u8, numArgs: u8, reqNumRetVals: u2) linksection(cy.HotSection) !PcFramePtr {
        const sym = self.funcSyms.buf[symId];
        switch (@intToEnum(FuncSymbolEntryType, sym.entryT)) {
            .nativeFunc1 => {
                const newFramePtr = framePtr + startLocal;

                // Optimize.
                pc[0] = cy.OpData{ .code = .callNativeFuncIC };
                @ptrCast(*align(1) u48, pc + 5).* = @intCast(u48, @ptrToInt(sym.inner.nativeFunc1));

                gvm.framePtr = newFramePtr;
                const res = sym.inner.nativeFunc1(@ptrCast(*UserVM, self), @ptrCast([*]const Value, newFramePtr + 4), numArgs);
                if (res.isPanic()) {
                    return error.Panic;
                }
                if (reqNumRetVals == 1) {
                    newFramePtr[0] = res;
                } else {
                    switch (reqNumRetVals) {
                        0 => {
                            // Nop.
                        },
                        1 => stdx.panic("not possible"),
                        else => stdx.panic("unsupported"),
                    }
                }
                return PcFramePtr{
                    .pc = pc + 11,
                    .framePtr = framePtr,
                };
            },
            .func => {
                if (@ptrToInt(framePtr + startLocal + sym.inner.func.numLocals) >= @ptrToInt(self.stackEndPtr)) {
                    return error.StackOverflow;
                }

                // Optimize.
                pc[0] = cy.OpData{ .code = .callFuncIC };
                pc[4] = cy.OpData{ .arg = @intCast(u8, sym.inner.func.numLocals) };
                @ptrCast(*align(1) u48, pc + 5).* = @intCast(u48, @ptrToInt(toPc(sym.inner.func.pc)));

                const newFramePtr = framePtr + startLocal;
                newFramePtr[1] = buildReturnInfo(reqNumRetVals, true);
                newFramePtr[2] = Value{ .retPcPtr = pc + 11 };
                newFramePtr[3] = Value{ .retFramePtr = framePtr };
                return PcFramePtr{
                    .pc = toPc(sym.inner.func.pc),
                    .framePtr = newFramePtr,
                };
            },
            .closure => {
                if (@ptrToInt(framePtr + startLocal + sym.inner.closure.numLocals) >= @ptrToInt(gvm.stackEndPtr)) {
                    return error.StackOverflow;
                }

                const newFramePtr = framePtr + startLocal;
                newFramePtr[1] = buildReturnInfo(reqNumRetVals, true);
                newFramePtr[2] = Value{ .retPcPtr = pc + 11 };
                newFramePtr[3] = Value{ .retFramePtr = framePtr };

                // Copy over captured vars to new call stack locals.
                const src = sym.inner.closure.getCapturedValuesPtr()[0..sym.inner.closure.numCaptured];
                std.mem.copy(Value, newFramePtr[numArgs + 4 + 1..numArgs + 4 + 1 + sym.inner.closure.numCaptured], src);

                return PcFramePtr{
                    .pc = toPc(sym.inner.closure.funcPc),
                    .framePtr = newFramePtr,
                };
            },
            .none => {
                return self.panic("Symbol is not defined.");
            },
            // else => {
            //     return self.panic("unsupported callsym");
            // },
        }
    }

    fn callSymEntry(self: *VM, pc: [*]cy.OpData, framePtr: [*]Value, sym: MethodSym, obj: *HeapObject, typeId: u32, startLocal: u8, numArgs: u8, reqNumRetVals: u8) linksection(cy.HotSection) !PcFramePtr {
        switch (sym.entryT) {
            .func => {
                if (@ptrToInt(framePtr + startLocal + sym.inner.func.numLocals) >= @ptrToInt(gvm.stackEndPtr)) {
                    return error.StackOverflow;
                }

                // Optimize.
                pc[0] = cy.OpData{ .code = .callObjFuncIC };
                pc[5] = cy.OpData{ .arg = @intCast(u8, sym.inner.func.numLocals) };
                @ptrCast(*align(1) u48, pc + 6).* = @intCast(u48, @ptrToInt(toPc(sym.inner.func.pc)));
                @ptrCast(*align(1) u16, pc + 12).* = @intCast(u16, typeId);
                
                const newFramePtr = framePtr + startLocal;
                newFramePtr[1] = buildReturnInfo2(reqNumRetVals, true);
                newFramePtr[2] = Value{ .retPcPtr = pc + 14 };
                newFramePtr[3] = Value{ .retFramePtr = framePtr };
                return PcFramePtr{
                    .pc = toPc(sym.inner.func.pc),
                    .framePtr = newFramePtr,
                };
            },
            .nativeFunc1 => {
                // Optimize.
                pc[0] = cy.OpData{ .code = .callObjNativeFuncIC };
                @ptrCast(*align(1) u48, pc + 6).* = @intCast(u48, @ptrToInt(sym.inner.nativeFunc1));
                @ptrCast(*align(1) u16, pc + 12).* = @intCast(u16, typeId);

                self.framePtr = framePtr;
                const res = sym.inner.nativeFunc1(@ptrCast(*UserVM, self), obj, @ptrCast([*]const Value, framePtr + startLocal + 4), numArgs);
                if (res.isPanic()) {
                    return error.Panic;
                }
                if (reqNumRetVals == 1) {
                    framePtr[startLocal] = res;
                } else {
                    switch (reqNumRetVals) {
                        0 => {
                            // Nop.
                        },
                        1 => stdx.panic("not possible"),
                        else => {
                            stdx.panic("unsupported");
                        },
                    }
                }
                return PcFramePtr{
                    .pc = pc + 14,
                    .framePtr = framePtr,
                };
            },
            .nativeFunc2 => {
                self.framePtr = framePtr;
                const res = sym.inner.nativeFunc2(@ptrCast(*UserVM, self), obj, @ptrCast([*]const Value, framePtr + startLocal + 4), numArgs);
                if (res.left.isPanic()) {
                    return error.Panic;
                }
                if (reqNumRetVals == 2) {
                    framePtr[startLocal] = res.left;
                    framePtr[startLocal+1] = res.right;
                } else {
                    switch (reqNumRetVals) {
                        0 => {
                            release(self, res.left);
                            release(self, res.right);
                        },
                        1 => {
                            framePtr[startLocal] = res.left;
                            release(self, res.right);
                        },
                        else => {
                            stdx.panic("unsupported");
                        },
                    }
                }
                return PcFramePtr{
                    .pc = pc + 14,
                    .framePtr = framePtr,
                };
            },
            // else => {
            //     // stdx.panicFmt("unsupported {}", .{sym.entryT});
            //     unreachable;
            // },
        }
    }

    fn getCallObjSymFromTable(self: *VM, sid: StructId, symId: SymbolId) ?MethodSym {
        if (self.methodTable.get(.{ .structId = sid, .symId = symId })) |entry| {
            const sym = &self.methodSyms.buf[symId];
            sym.* = .{
                .entryT = entry.entryT,
                .mruStructId = sid,
                .inner = entry.inner,
            };
            return entry;
        } else {
            return null;
        }
    }

    fn getCallObjSym(self: *VM, typeId: u32, symId: SymbolId) linksection(cy.HotSection) ?MethodSym {
        const entry = self.methodSyms.buf[symId];
        if (entry.mruStructId == typeId) {
            return entry;
        } else {
            return @call(.never_inline, self.getCallObjSymFromTable, .{typeId, symId});
        }
    }

    /// Stack layout: arg0, arg1, ..., receiver
    /// numArgs includes the receiver.
    /// Return new pc to avoid deoptimization.
    fn callObjSym(self: *VM, pc: [*]const cy.OpData, framePtr: [*]Value, recv: Value, symId: SymbolId, startLocal: u8, numArgs: u8, comptime reqNumRetVals: u2) linksection(cy.HotSection) !PcFramePtr {
        if (recv.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer().?);
            const map = self.methodSyms.buf[symId];
            switch (map.mapT) {
                .one => {
                    if (obj.retainedCommon.structId == map.inner.one.id) {
                        return try @call(.{.modifier = .never_inline }, callSymEntryNoInline, .{pc, framePtr, map.inner.one.sym, obj, startLocal, numArgs, reqNumRetVals});
                    } else return self.panic("Symbol does not exist for receiver.");
                },
                .many => {
                    if (map.inner.many.mruStructId == obj.retainedCommon.structId) {
                        return try @call(.never_inline, callSymEntryNoInline, .{pc, framePtr, map.inner.many.mruSym, obj, startLocal, numArgs, reqNumRetVals});
                    } else {
                        const sym = self.methodTable.get(.{ .structId = obj.retainedCommon.structId, .methodId = symId }) orelse {
                            log.debug("Symbol does not exist for receiver.", .{});
                            stdx.fatal();
                        };
                        self.methodSyms.buf[symId].inner.many = .{
                            .mruStructId = obj.retainedCommon.structId,
                            .mruSym = sym,
                        };
                        return try @call(.never_inline, callSymEntryNoInline, .{pc, framePtr, sym, obj, startLocal, numArgs, reqNumRetVals});
                    }
                },
                .empty => {
                    return try @call(.never_inline, callObjSymFallback, .{self, pc, framePtr, obj, symId, startLocal, numArgs, reqNumRetVals});
                },
                // else => {
                //     unreachable;
                //     // stdx.panicFmt("unsupported {}", .{map.mapT});
                // },
            } 
        }
        return PcFramePtr{
            .pc = pc,
            .framePtr = undefined,
        };
    }

    pub fn getStackTrace(self: *const VM) *const StackTrace {
        return &self.stackTrace;
    }

    pub fn buildStackTrace(self: *VM, fromPanic: bool) !void {
        @setCold(true);
        self.stackTrace.deinit(self.alloc);
        var frames: std.ArrayListUnmanaged(StackFrame) = .{};

        var framePtr = framePtrOffset(self.framePtr);
        var pc = pcOffset(self.pc);
        var isTopFrame = true;
        while (true) {
            const idx = b: {
                if (isTopFrame) {
                    isTopFrame = false;
                    if (fromPanic) {
                        const len = cy.getInstLenAt(self.ops.ptr + pc);
                        break :b debug.indexOfDebugSym(self, pc + len) orelse return error.NoDebugSym;
                    }
                }
                break :b debug.indexOfDebugSym(self, pc) orelse return error.NoDebugSym;
            };
            const sym = self.debugTable[idx];

            if (sym.frameLoc == NullId) {
                const node = self.compiler.nodes[sym.loc];
                var line: u32 = undefined;
                var col: u32 = undefined;
                var lineStart: u32 = undefined;
                const pos = self.compiler.tokens[node.start_token].pos();
                debug.computeLinePosWithTokens(self.parser.tokens.items, self.parser.src.items, pos, &line, &col, &lineStart);
                try frames.append(self.alloc, .{
                    .name = "main",
                    .uri = self.mainUri,
                    .line = line,
                    .col = col,
                    .lineStartPos = lineStart,
                });
                break;
            } else {
                const frameNode = self.compiler.nodes[sym.frameLoc];
                const func = self.compiler.funcDecls[frameNode.head.func.decl_id];
                const name = self.compiler.src[func.name.start..func.name.end];

                const node = self.compiler.nodes[sym.loc];
                var line: u32 = undefined;
                var col: u32 = undefined;
                var lineStart: u32 = undefined;
                const pos = self.compiler.tokens[node.start_token].pos();
                debug.computeLinePosWithTokens(self.parser.tokens.items, self.parser.src.items, pos, &line, &col, &lineStart);
                try frames.append(self.alloc, .{
                    .name = name,
                    .uri = self.mainUri,
                    .line = line,
                    .col = col,
                    .lineStartPos = lineStart,
                });
                pc = pcOffset(self.stack[framePtr + 2].retPcPtr);
                framePtr = framePtrOffset(self.stack[framePtr + 3].retFramePtr);
            }
        }

        self.stackTrace.frames = try frames.toOwnedSlice(self.alloc);
    }

    fn valueAsStaticString(self: *const VM, val: Value) linksection(cy.HotSection) []const u8 {
        const slice = val.asStaticStringSlice();
        return self.strBuf[slice.start..slice.end];
    }

    /// A comparable string can be any string or a rawstring.
    pub fn tryValueAsComparableString(self: *const VM, val: Value) linksection(cy.Section) ?[]const u8 {
        if (val.isPointer()) {
            const obj = val.asHeapObject(*HeapObject);
            if (obj.common.structId == cy.AstringT) {
                return obj.astring.getConstSlice();
            } else if (obj.common.structId == cy.UstringT) {
                return obj.ustring.getConstSlice();
            } else if (obj.common.structId == cy.StringSliceT) {
                return obj.stringSlice.getConstSlice();
            } else if (obj.common.structId == cy.RawStringT) {
                return obj.rawstring.getConstSlice();
            } else if (obj.common.structId == cy.RawStringSliceT) {
                return obj.rawstringSlice.getConstSlice();
            } else return null;
        } else {
            if (val.assumeNotPtrIsStaticString()) {
                const slice = val.asStaticStringSlice();
                return self.strBuf[slice.start..slice.end];
            } else return null;
        }
        return null;
    }

    fn valueAsStringType(self: *const VM, val: Value, strT: StringType) linksection(cy.Section) []const u8 {
        switch (strT) {
            .staticAstring,
            .staticUstring => {
                const slice = val.asStaticStringSlice();
                return self.strBuf[slice.start..slice.end];
            },
            .astring => {
                const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer().?);
                return obj.astring.getConstSlice();
            },
            .ustring => {
                const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer().?);
                return obj.ustring.getConstSlice();
            },
            .slice => {
                const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer().?);
                return obj.stringSlice.getConstSlice();
            },
            .rawstring => {
                const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer().?);
                return obj.rawstring.getConstSlice();
            },
            .rawSlice => {
                const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer().?);
                return obj.rawstringSlice.getConstSlice();
            },
        }
    }

    pub fn valueAsString(self: *const VM, val: Value) linksection(cy.Section) []const u8 {
        if (val.isPointer()) {
            const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer().?);
            if (obj.common.structId == cy.AstringT) {
                return obj.astring.getConstSlice();
            } else if (obj.common.structId == cy.UstringT) {
                return obj.ustring.getConstSlice();
            } else if (obj.common.structId == cy.StringSliceT) {
                return obj.stringSlice.getConstSlice();
            } else unreachable;
        } else {
            // Assume const string.
            const slice = val.asStaticStringSlice();
            return self.strBuf[slice.start..slice.end];
        }
    }

    pub fn valueToString(self: *const VM, val: Value) ![]const u8 {
        const str = self.valueToTempString(val);
        return try self.alloc.dupe(u8, str);
    }

    pub fn valueToTempString(self: *const VM, val: Value) linksection(cy.Section) []const u8 {
        tempU8Writer.reset();
        return self.getOrWriteValueString(tempU8Writer, val, undefined, false);
    }

    pub fn valueToTempString2(self: *const VM, val: Value, outCharLen: *u32) linksection(cy.Section) []const u8 {
        tempU8Writer.reset();
        return self.getOrWriteValueString(tempU8Writer, val, outCharLen, true);
    }

    pub fn valueToNextTempString(self: *const VM, val: Value) linksection(cy.Section) []const u8 {
        return self.getOrWriteValueString(tempU8Writer, val, undefined, false);
    }

    pub fn valueToNextTempString2(self: *const VM, val: Value, outCharLen: *u32) linksection(cy.Section) []const u8 {
        return self.getOrWriteValueString(tempU8Writer, val, outCharLen, true);
    }

    /// Conversion goes into a temporary buffer. Must use the result before a subsequent call.
    fn getOrWriteValueString(self: *const VM, writer: anytype, val: Value, outCharLen: *u32, comptime getCharLen: bool) linksection(cy.Section) []const u8 {
        if (val.isNumber()) {
            const f = val.asF64();
            const start = writer.pos();
            if (Value.floatIsSpecial(f)) {
                std.fmt.format(writer, "{}", .{f}) catch stdx.fatal();
            } else {
                if (Value.floatCanBeInteger(f)) {
                    std.fmt.format(writer, "{d:.0}", .{f}) catch stdx.fatal();
                } else {
                    std.fmt.format(writer, "{d:.10}", .{f}) catch stdx.fatal();
                }
            }
            const slice = writer.sliceFrom(start);
            if (getCharLen) {
                outCharLen.* = @intCast(u32, slice.len);
            }
            return slice;
        } else {
            if (val.isPointer()) {
                const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer().?);
                if (obj.common.structId == AstringT) {
                    const res = obj.astring.getConstSlice();
                    if (getCharLen) {
                        outCharLen.* = @intCast(u32, res.len);
                    }
                    return res;
                } else if (obj.common.structId == UstringT) {
                    if (getCharLen) {
                        outCharLen.* = obj.ustring.charLen;
                    }
                    return obj.ustring.getConstSlice();
                } else if (obj.common.structId == RawStringT) {
                    const start = writer.pos();
                    std.fmt.format(writer, "rawstring ({})", .{obj.rawstring.len}) catch stdx.fatal();
                    const slice = writer.sliceFrom(start);
                    if (getCharLen) {
                        outCharLen.* = @intCast(u32, slice.len);
                    }
                    return slice;
                } else if (obj.common.structId == ListS) {
                    const start = writer.pos();
                    std.fmt.format(writer, "List ({})", .{obj.list.list.len}) catch stdx.fatal();
                    const slice = writer.sliceFrom(start);
                    if (getCharLen) {
                        outCharLen.* = @intCast(u32, slice.len);
                    }
                    return slice;
                } else if (obj.common.structId == MapS) {
                    const start = writer.pos();
                    std.fmt.format(writer, "Map ({})", .{obj.map.inner.size}) catch stdx.fatal();
                    const slice = writer.sliceFrom(start);
                    if (getCharLen) {
                        outCharLen.* = @intCast(u32, slice.len);
                    }
                    return slice;
                } else {
                    const buf = self.structs.buf[obj.common.structId].name;
                    if (getCharLen) {
                        outCharLen.* = @intCast(u32, buf.len);
                    }
                    return buf;
                }
            } else {
                switch (val.getTag()) {
                    cy.NoneT => {
                        if (getCharLen) {
                            outCharLen.* = "none".len;
                        }
                        return "none";
                    },
                    cy.BooleanT => {
                        if (val.asBool()) {
                            if (getCharLen) {
                                outCharLen.* = "true".len;
                            }
                            return "true";
                        } else {
                            if (getCharLen) {
                                outCharLen.* = "false".len;
                            }
                            return "false";
                        }
                    },
                    cy.ErrorT => {
                        const start = writer.pos();
                        const litId = val.asErrorTagLit();
                        std.fmt.format(writer, "error#{s}", .{self.getTagLitName(litId)}) catch stdx.fatal();
                        const slice = writer.sliceFrom(start);
                        if (getCharLen) {
                            outCharLen.* = @intCast(u32, slice.len);
                        }
                        return slice;
                    },
                    cy.StaticAstringT => {
                        const slice = val.asStaticStringSlice();
                        const buf = self.strBuf[slice.start..slice.end];
                        if (getCharLen) {
                            outCharLen.* = @intCast(u32, buf.len);
                        }
                        return buf;
                    },
                    cy.StaticUstringT => {
                        const slice = val.asStaticStringSlice();
                        if (getCharLen) {
                            outCharLen.* = @ptrCast(*align (1) cy.StaticUstringHeader, self.strBuf.ptr + slice.start - 12).charLen;
                        }
                        return self.strBuf[slice.start..slice.end];
                    },
                    cy.UserTagLiteralT => {
                        const start = writer.pos();
                        const litId = val.asTagLiteralId();
                        std.fmt.format(writer, "#{s}", .{self.getTagLitName(litId)}) catch stdx.fatal();
                        const slice = writer.sliceFrom(start);
                        if (getCharLen) {
                            outCharLen.* = @intCast(u32, slice.len);
                        }
                        return slice;
                    },
                    cy.IntegerT => {
                        const start = writer.pos();
                        std.fmt.format(writer, "{}", .{val.asI32()}) catch stdx.fatal();
                        const slice = writer.sliceFrom(start);
                        if (getCharLen) {
                            outCharLen.* = @intCast(u32, slice.len);
                        }
                        return slice;
                    },
                    else => {
                        log.debug("unexpected tag {}", .{val.getTag()});
                        stdx.fatal();
                    },
                }
            }
        }
    }

    fn writeValueToString(self: *const VM, writer: anytype, val: Value) void {
        const str = self.valueToTempString(val);
        _ = writer.write(str) catch stdx.fatal();
    }

    pub inline fn stackEnsureUnusedCapacity(self: *VM, unused: u32) linksection(cy.HotSection) !void {
        if (@ptrToInt(self.framePtr) + 8 * unused >= @ptrToInt(self.stack.ptr + self.stack.len)) {
            try self.stackGrowTotalCapacity((@ptrToInt(self.framePtr) + 8 * unused) / 8);
        }
    }

    inline fn stackEnsureTotalCapacity(self: *VM, newCap: usize) linksection(cy.HotSection) !void {
        if (newCap > self.stack.len) {
            try self.stackGrowTotalCapacity(newCap);
        }
    }

    pub fn stackEnsureTotalCapacityPrecise(self: *VM, newCap: usize) !void {
        if (newCap > self.stack.len) {
            try self.stackGrowTotalCapacityPrecise(newCap);
        }
    }

    pub fn stackGrowTotalCapacity(self: *VM, newCap: usize) !void {
        var betterCap = self.stack.len;
        while (true) {
            betterCap +|= betterCap / 2 + 8;
            if (betterCap >= newCap) {
                break;
            }
        }
        if (self.alloc.resize(self.stack, betterCap)) {
            self.stack.len = betterCap;
            self.stackEndPtr = self.stack.ptr + betterCap;
        } else {
            self.stack = try self.alloc.realloc(self.stack, betterCap);
            self.stackEndPtr = self.stack.ptr + betterCap;
        }
    }

    pub fn stackGrowTotalCapacityPrecise(self: *VM, newCap: usize) !void {
        if (self.alloc.resize(self.stack, newCap)) {
            self.stack.len = newCap;
            self.stackEndPtr = self.stack.ptr + newCap;
        } else {
            self.stack = try self.alloc.realloc(self.stack, newCap);
            self.stackEndPtr = self.stack.ptr + newCap;
        }
    }
};

pub fn releaseObject(vm: *VM, obj: *HeapObject) linksection(cy.HotSection) void {
    if (builtin.mode == .Debug or builtin.is_test) {
        if (obj.retainedCommon.structId == NullId) {
            stdx.panic("object already freed.");
        }
    }
    obj.retainedCommon.rc -= 1;
    log.debug("release {} {}", .{obj.getUserTag(), obj.retainedCommon.rc});
    if (TrackGlobalRC) {
        vm.refCounts -= 1;
    }
    if (TraceEnabled) {
        vm.trace.numReleases += 1;
        vm.trace.numReleaseAttempts += 1;
    }
    if (obj.retainedCommon.rc == 0) {
        @call(.never_inline, freeObject, .{vm, obj});
    }
}

fn freeObject(vm: *VM, obj: *HeapObject) linksection(cy.HotSection) void {
    log.debug("free {}", .{obj.getUserTag()});
    switch (obj.retainedCommon.structId) {
        ListS => {
            const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
            for (list.items()) |it| {
                release(vm, it);
            }
            list.deinit(vm.alloc);
            vm.freeObject(obj);
        },
        ListIteratorT => {
            releaseObject(vm, stdx.ptrAlignCast(*HeapObject, obj.listIter.list));
            vm.freeObject(obj);
        },
        MapS => {
            const map = stdx.ptrAlignCast(*MapInner, &obj.map.inner);
            var iter = map.iterator();
            while (iter.next()) |entry| {
                release(vm, entry.key);
                release(vm, entry.value);
            }
            map.deinit(vm.alloc);
            vm.freeObject(obj);
        },
        MapIteratorT => {
            releaseObject(vm, stdx.ptrAlignCast(*HeapObject, obj.mapIter.map));
            vm.freeObject(obj);
        },
        ClosureS => {
            const src = obj.closure.getCapturedValuesPtr()[0..obj.closure.numCaptured];
            for (src) |capturedVal| {
                release(vm, capturedVal);
            }
            if (obj.closure.numCaptured <= 3) {
                vm.freeObject(obj);
            } else {
                const slice = @ptrCast([*]u8, obj)[0..2 + obj.closure.numCaptured];
                vm.alloc.free(slice);
            }
        },
        LambdaS => {
            vm.freeObject(obj);
        },
        AstringT => {
            if (obj.astring.len <= DefaultStringInternMaxByteLen) {
                // Check both the key and value to make sure this object is the intern entry.
                const key = obj.astring.getConstSlice();
                if (vm.strInterns.get(key)) |val| {
                    if (val == obj) {
                        _ = vm.strInterns.remove(key);
                    }
                }
            }
            if (obj.astring.len <= MaxPoolObjectAstringByteLen) {
                vm.freeObject(obj);
            } else {
                const slice = @ptrCast([*]u8, obj)[0..Astring.BufOffset + obj.astring.len];
                vm.alloc.free(slice);
            }
        },
        UstringT => {
            if (obj.ustring.len <= DefaultStringInternMaxByteLen) {
                const key = obj.ustring.getConstSlice();
                if (vm.strInterns.get(key)) |val| {
                    if (val == obj) {
                        _ = vm.strInterns.remove(key);
                    }
                }
            }
            if (obj.ustring.len <= MaxPoolObjectUstringByteLen) {
                vm.freeObject(obj);
            } else {
                const slice = @ptrCast([*]u8, obj)[0..Ustring.BufOffset + obj.ustring.len];
                vm.alloc.free(slice);
            }
        },
        StringSliceT => {
            if (obj.stringSlice.getParentPtr()) |parent| {
                releaseObject(vm, parent);
            }
            vm.freeObject(obj);
        },
        RawStringT => {
            if (obj.rawstring.len <= MaxPoolObjectRawStringByteLen) {
                vm.freeObject(obj);
            } else {
                const slice = @ptrCast([*]u8, obj)[0..RawString.BufOffset + obj.rawstring.len];
                vm.alloc.free(slice);
            }
        },
        RawStringSliceT => {
            const parent = @ptrCast(*cy.HeapObject, obj.rawstringSlice.parent);
            releaseObject(vm, parent);
            vm.freeObject(obj);
        },
        FiberS => {
            releaseFiberStack(vm, &obj.fiber);
            vm.freeObject(obj);
        },
        BoxS => {
            release(vm, obj.box.val);
            vm.freeObject(obj);
        },
        NativeFunc1S => {
            if (obj.nativeFunc1.hasTccState) {
                releaseObject(vm, stdx.ptrAlignCast(*HeapObject, obj.nativeFunc1.tccState.asPointer().?));
            }
            vm.freeObject(obj);
        },
        TccStateS => {
            if (cy.hasJit) {
                tcc.tcc_delete(obj.tccState.state);
                obj.tccState.lib.close();
                vm.alloc.destroy(obj.tccState.lib);
                vm.freeObject(obj);
            } else {
                unreachable;
            }
        },
        OpaquePtrS => {
            vm.freeObject(obj);
        },
        FileT => {
            if (cy.hasStdFiles) {
                if (obj.file.hasReadBuf) {
                    vm.alloc.free(obj.file.readBuf[0..obj.file.readBufCap]);
                }
                obj.file.close();
            }
            vm.freeObject(obj);
        },
        DirT => {
            if (cy.hasStdFiles) {
                var dir = obj.dir.getStdDir();
                dir.close();   
            }
            vm.freeObject(obj);
        },
        DirIteratorT => {
            if (cy.hasStdFiles) {
                var dir = @ptrCast(*DirIterator, obj);
                if (dir.recursive) {
                    const walker = stdx.ptrAlignCast(*std.fs.IterableDir.Walker, &dir.inner.walker);
                    walker.deinit();   
                }
                releaseObject(vm, @ptrCast(*HeapObject, dir.dir));
            }
            const slice = @ptrCast([*]align(@alignOf(HeapObject)) u8, obj)[0..@sizeOf(DirIterator)];
            vm.alloc.free(slice);
        },
        else => {
            log.debug("free {s}", .{vm.structs.buf[obj.retainedCommon.structId].name});
            // Struct deinit.
            if (builtin.mode == .Debug) {
                // Check range.
                if (obj.retainedCommon.structId >= vm.structs.len) {
                    log.debug("unsupported struct type {}", .{obj.retainedCommon.structId});
                    stdx.fatal();
                }
            }
            const numFields = vm.structs.buf[obj.retainedCommon.structId].numFields;
            for (obj.object.getValuesConstPtr()[0..numFields]) |child| {
                release(vm, child);
            }
            if (numFields <= 4) {
                vm.freeObject(obj);
            } else {
                const slice = @ptrCast([*]Value, obj)[0..1 + numFields];
                vm.alloc.free(slice);
            }
        },
    }
}

pub fn release(vm: *VM, val: Value) linksection(cy.HotSection) void {
    if (TraceEnabled) {
        vm.trace.numReleaseAttempts += 1;
    }
    if (val.isPointer()) {
        const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer().?);
        if (builtin.mode == .Debug or builtin.is_test) {
            if (obj.retainedCommon.structId == NullId) {
                log.debug("object already freed. {*}", .{obj});
                debug.dumpObjectTrace(vm, obj);
                stdx.fatal();
            }
        }
        obj.retainedCommon.rc -= 1;
        log.debug("release {} {}", .{val.getUserTag(), obj.retainedCommon.rc});
        if (TrackGlobalRC) {
            vm.refCounts -= 1;
        }
        if (TraceEnabled) {
            vm.trace.numReleases += 1;
        }
        if (obj.retainedCommon.rc == 0) {
            @call(.never_inline, freeObject, .{vm, obj});
        }
    }
}

fn evalBitwiseOr(left: Value, right: Value) linksection(cy.HotSection) Value {
    @setCold(true);
    if (left.isNumber()) {
       const f = @intToFloat(f64, left.asF64toI32() | @floatToInt(i32, right.toF64()));
       return Value.initF64(f);
    } else {
        log.debug("unsupported", .{});
        unreachable;
    }
}

fn evalBitwiseXor(left: Value, right: Value) linksection(cy.HotSection) Value {
    @setCold(true);
    if (left.isNumber()) {
       const f = @intToFloat(f64, left.asF64toI32() ^ @floatToInt(i32, right.toF64()));
       return Value.initF64(f);
    } else {
        log.debug("unsupported", .{});
        unreachable;
    }
}

fn evalBitwiseAnd(left: Value, right: Value) linksection(cy.HotSection) Value {
    @setCold(true);
    if (left.isNumber()) {
       const f = @intToFloat(f64, left.asF64toI32() & @floatToInt(i32, right.toF64()));
       return Value.initF64(f);
    } else {
        log.debug("unsupported", .{});
        unreachable;
    }
}

fn evalBitwiseLeftShift(left: Value, right: Value) linksection(cy.HotSection) Value {
    @setCold(true);
    if (left.isNumber()) {
       const f = @intToFloat(f64, left.asF64toI32() << @floatToInt(u5, right.toF64()));
       return Value.initF64(f);
    } else {
        log.debug("unsupported", .{});
        unreachable;
    }
}

fn evalBitwiseRightShift(left: Value, right: Value) linksection(cy.HotSection) Value {
    @setCold(true);
    if (left.isNumber()) {
       const f = @intToFloat(f64, left.asF64toI32() >> @floatToInt(u5, right.toF64()));
       return Value.initF64(f);
    } else {
        log.debug("unsupported", .{});
        unreachable;
    }
}

fn evalBitwiseNot(val: Value) linksection(cy.HotSection) Value {
    @setCold(true);
    if (val.isNumber()) {
       const f = @intToFloat(f64, ~val.asF64toI32());
       return Value.initF64(f);
    } else {
        log.debug("unsupported", .{});
        unreachable;
    }
}

fn evalGreaterOrEqual(left: cy.Value, right: cy.Value) cy.Value {
    return Value.initBool(left.toF64() >= right.toF64());
}

fn evalGreater(left: cy.Value, right: cy.Value) cy.Value {
    return Value.initBool(left.toF64() > right.toF64());
}

fn evalLessOrEqual(left: cy.Value, right: cy.Value) cy.Value {
    return Value.initBool(left.toF64() <= right.toF64());
}

fn evalLessFallback(left: cy.Value, right: cy.Value) linksection(cy.HotSection) cy.Value {
    @setCold(true);
    return Value.initBool(left.toF64() < right.toF64());
}

pub const StringType = enum {
    staticAstring,
    staticUstring,
    astring,
    ustring,
    slice,
    rawstring,
    rawSlice,
};

fn getComparableStringType(val: Value) ?StringType {
    if (val.isPointer()) {
        const obj = stdx.ptrAlignCast(*HeapObject, val.asPointer().?);
        if (obj.common.structId == AstringT) {
            return .astring;
        } else if (obj.common.structId == UstringT) {
            return .ustring;
        } else if (obj.common.structId == StringSliceT) {
            return .slice;
        } else if (obj.common.structId == RawStringT) {
            return .rawstring;
        } else if (obj.common.structId == RawStringSliceT) {
            return .rawSlice;
        }
        return null;
    } else {
        if (val.isNumber()) {
            return null;
        }
        switch (val.getTag()) {
            cy.StaticUstringT => {
                return .staticUstring;
            },
            cy.StaticAstringT => {
                return .staticAstring;
            },
            else => return null,
        }
    }
}

fn evalCompareNot(vm: *const VM, left: cy.Value, right: cy.Value) linksection(cy.HotSection) cy.Value {
    if (getComparableStringType(left)) |lstrT| {
        if (getComparableStringType(right)) |rstrT| {
            const lstr = vm.valueAsStringType(left, lstrT);
            const rstr = vm.valueAsStringType(right, rstrT);
            return Value.initBool(!std.mem.eql(u8, lstr, rstr));
        }
    }
    return Value.True;
}

fn evalCompareBool(vm: *const VM, left: Value, right: Value) linksection(cy.HotSection) bool {
    if (getComparableStringType(left)) |lstrT| {
        if (getComparableStringType(right)) |rstrT| {
            const lstr = vm.valueAsStringType(left, lstrT);
            const rstr = vm.valueAsStringType(right, rstrT);
            return std.mem.eql(u8, lstr, rstr);
        }
    }
    return false;
}

fn evalCompare(vm: *const VM, left: Value, right: Value) linksection(cy.HotSection) Value {
    if (getComparableStringType(left)) |lstrT| {
        if (getComparableStringType(right)) |rstrT| {
            const lstr = vm.valueAsStringType(left, lstrT);
            const rstr = vm.valueAsStringType(right, rstrT);
            return Value.initBool(std.mem.eql(u8, lstr, rstr));
        }
    }
    return Value.False;
}

fn evalMinusFallback(left: Value, right: Value) linksection(cy.HotSection) Value {
    @setCold(true);
    if (left.isPointer()) {
        return Value.initF64(left.toF64() - right.toF64());
    } else {
        switch (left.getTag()) {
            cy.BooleanT => {
                if (left.asBool()) {
                    return Value.initF64(1 - right.toF64());
                } else {
                    return Value.initF64(-right.toF64());
                }
            },
            cy.NoneT => return Value.initF64(-right.toF64()),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalPower(left: cy.Value, right: cy.Value) cy.Value {
    if (left.isNumber()) {
        return Value.initF64(std.math.pow(f64, left.asF64(), right.toF64()));
    } else {
        switch (left.getTag()) {
            cy.BooleanT => {
                if (left.asBool()) {
                    return Value.initF64(1);
                } else {
                    return Value.initF64(0);
                }
            },
            cy.NoneT => return Value.initF64(0),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalDivide(left: cy.Value, right: cy.Value) cy.Value {
    if (left.isNumber()) {
        return Value.initF64(left.asF64() / right.toF64());
    } else {
        switch (left.getTag()) {
            cy.BooleanT => {
                if (left.asBool()) {
                    return Value.initF64(1.0 / right.toF64());
                } else {
                    return Value.initF64(0);
                }
            },
            cy.NoneT => return Value.initF64(0),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalMod(left: cy.Value, right: cy.Value) cy.Value {
    if (left.isNumber()) {
        return Value.initF64(std.math.mod(f64, left.asF64(), right.toF64()) catch std.math.nan_f64);
    } else {
        switch (left.getTag()) {
            cy.BooleanT => {
                if (left.asBool()) {
                    const rightf = right.toF64();
                    if (rightf > 0) {
                        return Value.initF64(1);
                    } else if (rightf == 0) {
                        return Value.initF64(std.math.nan_f64);
                    } else {
                        return Value.initF64(rightf + 1);
                    }
                } else {
                    if (right.toF64() != 0) {
                        return Value.initF64(0);
                    } else {
                        return Value.initF64(std.math.nan_f64);
                    }
                }
            },
            cy.NoneT => {
                if (right.toF64() != 0) {
                    return Value.initF64(0);
                } else {
                    return Value.initF64(std.math.nan_f64);
                }
            },
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalMultiply(left: cy.Value, right: cy.Value) cy.Value {
    if (left.isNumber()) {
        return Value.initF64(left.asF64() * right.toF64());
    } else {
        switch (left.getTag()) {
            cy.BooleanT => {
                if (left.asBool()) {
                    return Value.initF64(right.toF64());
                } else {
                    return Value.initF64(0);
                }
            },
            cy.NoneT => return Value.initF64(0),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalAddFallback(left: cy.Value, right: cy.Value) linksection(cy.HotSection) !cy.Value {
    @setCold(true);
    return Value.initF64(try toF64OrPanic(left) + try toF64OrPanic(right));
}

fn toF64OrPanic(val: Value) linksection(cy.HotSection) !f64 {
    if (val.isNumber()) {
        return val.asF64();
    } else {
        return try @call(.never_inline, convToF64OrPanic, .{val});
    }
}

fn convToF64OrPanic(val: Value) linksection(cy.HotSection) !f64 {
    if (val.isPointer()) {
        const obj = stdx.ptrAlignCast(*cy.HeapObject, val.asPointer().?);
        if (obj.common.structId == cy.AstringT) {
            const str = obj.astring.getConstSlice();
            return std.fmt.parseFloat(f64, str) catch 0;
        } else if (obj.common.structId == cy.UstringT) {
            const str = obj.ustring.getConstSlice();
            return std.fmt.parseFloat(f64, str) catch 0;
        } else if (obj.common.structId == cy.RawStringT) {
            const str = obj.rawstring.getConstSlice();
            return std.fmt.parseFloat(f64, str) catch 0;
        } else return gvm.panic("Cannot convert struct to number");
    } else {
        switch (val.getTag()) {
            cy.NoneT => return 0,
            cy.BooleanT => return if (val.asBool()) 1 else 0,
            cy.IntegerT => return @intToFloat(f64, val.asI32()),
            cy.ErrorT => stdx.fatal(),
            cy.StaticAstringT => {
                const slice = val.asStaticStringSlice();
                const str = gvm.strBuf[slice.start..slice.end];
                return std.fmt.parseFloat(f64, str) catch 0;
            },
            cy.StaticUstringT => {
                const slice = val.asStaticStringSlice();
                const str = gvm.strBuf[slice.start..slice.end];
                return std.fmt.parseFloat(f64, str) catch 0;
            },
            else => stdx.panicFmt("unexpected tag {}", .{val.getTag()}),
        }
    }
}

fn evalNeg(val: Value) Value {
    // @setCold(true);
    if (val.isNumber()) {
        return Value.initF64(-val.asF64());
    } else {
        switch (val.getTag()) {
            cy.NoneT => return Value.initF64(0),
            cy.BooleanT => {
                if (val.asBool()) {
                    return Value.initF64(-1);
                } else {
                    return Value.initF64(0);
                }
            },
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalNot(val: cy.Value) cy.Value {
    if (val.isNumber()) {
        return Value.False;
    } else {
        switch (val.getTag()) {
            cy.NoneT => return Value.True,
            cy.BooleanT => return Value.initBool(!val.asBool()),
            else => stdx.panic("unexpected tag"),
        }
    }
}

const NullByteId = std.math.maxInt(u8);
const NullIdU16 = std.math.maxInt(u16);
const NullId = std.math.maxInt(u32);

pub const OpaquePtr = extern struct {
    structId: StructId,
    rc: u32,
    ptr: ?*anyopaque,
};

pub const DirIterator = extern struct {
    structId: StructId,
    rc: u32,
    dir: *Dir,
    inner: extern union {
        iter: if (cy.hasStdFiles) [@sizeOf(std.fs.IterableDir.Iterator)]u8 else void,
        walker: if (cy.hasStdFiles) [@sizeOf(std.fs.IterableDir.Walker)]u8 else void,
    },
    /// If `recursive` is true, `walker` is used.
    recursive: bool,
};

pub const Dir = extern struct {
    structId: StructId align(8),
    rc: u32,
    fd: if (cy.hasStdFiles) std.os.fd_t else u32,
    iterable: bool,

    pub fn getStdDir(self: *const Dir) std.fs.Dir {
        return std.fs.Dir{
            .fd = self.fd,
        };
    }

    pub fn getStdIterableDir(self: *const Dir) std.fs.IterableDir {
        return std.fs.IterableDir{
            .dir = std.fs.Dir{
                .fd = self.fd,
            },
        };
    }
};

const File = extern struct {
    structId: StructId,
    rc: u32,
    fd: std.os.fd_t,
    curPos: u32,
    readBuf: [*]u8,
    readBufCap: u32,
    readBufEnd: u32,
    iterLines: bool,
    hasReadBuf: bool,
    closed: bool,

    pub fn getStdFile(self: *const File) std.fs.File {
        return std.fs.File{
            .handle = @bitCast(i32, self.fd),
            .capable_io_mode = .blocking,
            .intended_io_mode = .blocking,
        };
    }

    pub fn close(self: *File) void {
        if (!self.closed) {
            const file = self.getStdFile();
            file.close();
            self.closed = true;
        }
    }
};

const TccState = extern struct {
    structId: StructId,
    rc: u32,
    state: *tcc.TCCState,
    lib: *std.DynLib,
};

const NativeFunc1 = extern struct {
    structId: StructId,
    rc: u32,
    func: *const fn (*UserVM, [*]Value, u8) Value,
    numParams: u32,
    tccState: Value,
    hasTccState: bool,
};

const Lambda = extern struct {
    structId: StructId,
    rc: u32,
    funcPc: u32, 
    numParams: u8,
    /// Includes locals and return info. Does not include params.
    numLocals: u8,
};

pub const Closure = extern struct {
    structId: StructId,
    rc: u32,
    funcPc: u32, 
    numParams: u8,
    numCaptured: u8,
    /// Includes locals, captured vars, and return info. Does not include params.
    numLocals: u8,
    padding: u8,
    firstCapturedVal: Value,

    inline fn getCapturedValuesPtr(self: *Closure) [*]Value {
        return @ptrCast([*]Value, &self.firstCapturedVal);
    }
};

pub const MapIterator = extern struct {
    structId: StructId,
    rc: u32,
    map: *Map,
    nextIdx: u32,
};

pub const MapInner = cy.ValueMap;
const Map = extern struct {
    structId: StructId,
    rc: u32,
    inner: extern struct {
        metadata: ?[*]u64,
        entries: ?[*]cy.ValueMapEntry,
        size: u32,
        cap: u32,
        available: u32,
        /// This prevents `inner` from having offset=0 in Map.
        /// Although @offsetOf(Map, "inner") returns 8 in that case &map.inner returns the same address as &map.
        padding: u32 = 0,
    },
};

const Box = extern struct {
    structId: StructId,
    rc: u32,
    val: Value,
};

pub const Fiber = extern struct {
    structId: StructId,
    rc: u32,
    prevFiber: ?*Fiber,
    stackPtr: [*]Value,
    stackLen: u32,
    /// If pc == NullId, the fiber is done.
    pc: u32,

    /// Contains framePtr in the lower 48 bits and adjacent 8 bit parentDstLocal.
    /// parentDstLocal:
    ///   Where coyield and coreturn should copy the return value to.
    ///   If this is the NullByteId, no value is copied and instead released.
    extra: u64,

    inline fn setFramePtr(self: *Fiber, ptr: [*]Value) void {
        self.extra = (self.extra & 0xff000000000000) | @ptrToInt(ptr);
    }

    inline fn getFramePtr(self: *const Fiber) [*]Value {
        return @intToPtr([*]Value, @intCast(usize, self.extra & 0xffffffffffff));
    }

    inline fn setParentDstLocal(self: *Fiber, parentDstLocal: u8) void {
        self.extra = (self.extra & 0xffffffffffff) | (@as(u64, parentDstLocal) << 48);
    }

    inline fn getParentDstLocal(self: *const Fiber) u8 {
        return @intCast(u8, (self.extra & 0xff000000000000) >> 48);
    }
};

const RawStringSlice = extern struct {
    structId: StructId,
    rc: u32,
    buf: [*]const u8,
    len: u32,
    padding: u32 = 0,
    parent: *RawString,

    pub inline fn getConstSlice(self: *const RawStringSlice) []const u8 {
        return self.buf[0..self.len];
    }
};

const StringSlice = extern struct {
    structId: StructId,
    rc: u32,
    buf: [*]const u8,
    len: u32,

    uCharLen: u32,
    uMruIdx: u32,
    uMruCharIdx: u32,

    /// A Ustring slice may have a null or 0 parentPtr if it's sliced from StaticUstring.
    /// The lower 63 bits contains the parentPtr.
    /// The last bit contains an isAscii flag.
    extra: u64,

    pub inline fn getParentPtr(self: *const StringSlice) ?*cy.HeapObject {
        return @intToPtr(?*cy.HeapObject, @intCast(usize, self.extra & 0x7fffffffffffffff));
    }

    pub inline fn isAstring(self: *const StringSlice) bool {
        return self.extra & (1 << 63) > 0;
    }

    pub inline fn getConstSlice(self: *const StringSlice) []const u8 {
        return self.buf[0..self.len];
    }
};

/// 28 byte length can fit inside a Heap pool object.
pub const MaxPoolObjectAstringByteLen = 28;

pub const Astring = extern struct {
    structId: StructId,
    rc: u32,
    len: u32,
    bufStart: u8,

    const BufOffset = @offsetOf(Astring, "bufStart");

    pub inline fn getSlice(self: *Astring) []u8 {
        return @ptrCast([*]u8, &self.bufStart)[0..self.len];
    }

    pub inline fn getConstSlice(self: *const Astring) []const u8 {
        return @ptrCast([*]const u8, &self.bufStart)[0..self.len];
    }
};

/// 16 byte length can fit inside a Heap pool object.
pub const MaxPoolObjectUstringByteLen = 16;

const Ustring = extern struct {
    structId: StructId,
    rc: u32,
    len: u32,
    charLen: u32,
    mruIdx: u32,
    mruCharIdx: u32,
    bufStart: u8,

    const BufOffset = @offsetOf(Ustring, "bufStart");

    pub inline fn getSlice(self: *Ustring) []u8 {
        return @ptrCast([*]u8, &self.bufStart)[0..self.len];
    }

    pub inline fn getConstSlice(self: *const Ustring) []const u8 {
        return @ptrCast([*]const u8, &self.bufStart)[0..self.len];
    }
};

pub const MaxPoolObjectRawStringByteLen = 28;

pub const RawString = extern struct {
    structId: if (cy.isWasm) StructId else StructId align(8),
    rc: u32,
    len: u32,
    bufStart: u8,

    pub const BufOffset = @offsetOf(RawString, "bufStart");

    pub inline fn getSlice(self: *RawString) []u8 {
        return @ptrCast([*]u8, &self.bufStart)[0..self.len];
    }

    pub inline fn getConstSlice(self: *const RawString) []const u8 {
        return @ptrCast([*]const u8, &self.bufStart)[0..self.len];
    }
};

pub const ListIterator = extern struct {
    structId: StructId,
    rc: u32,
    list: *List,
    nextIdx: u32,
};

pub const List = extern struct {
    structId: StructId,
    rc: u32,
    list: extern struct {
        ptr: [*]Value,
        cap: usize,
        len: usize,
    },

    pub inline fn items(self: *const List) []Value {
        return self.list.ptr[0..self.list.len];
    }

    /// Assumes `val` is retained.
    pub fn append(self: *List, alloc: std.mem.Allocator, val: Value) linksection(cy.Section) void {
        const list = stdx.ptrAlignCast(*cy.List(Value), &self.list);
        if (list.len == list.buf.len) {
            // After reaching a certain size, use power of two ceil.
            // This reduces allocations for big lists while not over allocating for smaller lists.
            if (list.len > 512) {
                const newCap = std.math.ceilPowerOfTwo(u32, @intCast(u32, list.len) + 1) catch stdx.fatal();
                list.growTotalCapacityPrecise(alloc, newCap) catch stdx.fatal();
            } else {
                list.growTotalCapacity(alloc, list.len + 1) catch stdx.fatal();
            }
        }
        list.appendAssumeCapacity(val);
    }
};

const Object = extern struct {
    structId: StructId,
    rc: u32,
    firstValue: Value,

    pub inline fn getValuesConstPtr(self: *const Object) [*]const Value {
        return @ptrCast([*]const Value, &self.firstValue);
    }

    pub inline fn getValuesPtr(self: *Object) [*]Value {
        return @ptrCast([*]Value, &self.firstValue);
    }

    pub inline fn getValuePtr(self: *Object, idx: u32) *Value {
        return @ptrCast(*Value, @ptrCast([*]Value, &self.firstValue) + idx);
    }

    pub inline fn getValue(self: *const Object, idx: u32) Value {
        return @ptrCast([*]const Value, &self.firstValue)[idx];
    }
};

// Keep it just under 4kb page.
const HeapPage = struct {
    objects: [102]HeapObject,
};

const HeapObjectId = u32;

/// Total of 40 bytes per object. If objects are bigger, they are allocated on the gpa.
pub const HeapObject = extern union {
    common: extern struct {
        structId: StructId,
    },
    freeSpan: extern struct {
        structId: StructId,
        len: u32,
        start: *HeapObject,
        next: ?*HeapObject,
    },
    retainedCommon: extern struct {
        structId: StructId,
        rc: u32,
    },
    list: List,
    listIter: ListIterator,
    fiber: Fiber,
    map: Map,
    mapIter: MapIterator,
    closure: Closure,
    lambda: Lambda,
    astring: Astring,
    ustring: Ustring,
    stringSlice: StringSlice,
    rawstring: RawString,
    rawstringSlice: RawStringSlice,
    object: Object,
    box: Box,
    nativeFunc1: NativeFunc1,
    tccState: if (cy.hasJit) TccState else void,
    file: if (cy.hasStdFiles) File else void,
    dir: if (cy.hasStdFiles) Dir else void,
    opaquePtr: OpaquePtr,

    pub fn getUserTag(self: *const HeapObject) cy.ValueUserTag {
        switch (self.common.structId) {
            cy.ListS => return .list,
            cy.MapS => return .map,
            cy.AstringT => return .string,
            cy.UstringT => return .string,
            cy.RawStringT => return .rawstring,
            cy.ClosureS => return .closure,
            cy.LambdaS => return .lambda,
            cy.FiberS => return .fiber,
            cy.NativeFunc1S => return .nativeFunc,
            cy.TccStateS => return .tccState,
            cy.OpaquePtrS => return .opaquePtr,
            cy.FileT => return .file,
            cy.DirT => return .dir,
            cy.DirIteratorT => return .dirIter,
            cy.BoxS => return .box,
            else => {
                return .object;
            },
        }
    }
};

const SymbolMapType = enum {
    one,
    many,
    empty,
};

const TagLitSym = struct {
    symT: SymbolMapType,
    inner: union {
        one: struct {
            id: TagTypeId,
            val: u32,
        },
    },
    name: []const u8,
};

const FieldSymbolMap = struct {
    mruStructId: StructId,
    mruOffset: u16,
    name: []const u8,
};

test "Internals." {
    try t.eq(@alignOf(UserVM), UserVMAlign);
    try t.eq(@alignOf(VM), 8);
    try t.eq(@alignOf(MethodSym), 8);
    try t.eq(@sizeOf(MethodSym), 16);
    try t.eq(@sizeOf(MapInner), 32);
    try t.eq(@sizeOf(HeapObject), 40);
    try t.eq(@alignOf(HeapObject), 8);
    try t.eq(@sizeOf(HeapPage), 40 * 102);
    try t.eq(@alignOf(HeapPage), 8);

    try t.eq(@sizeOf(FuncSymbolEntry), 16);
    var funcSymEntry: FuncSymbolEntry = undefined;
    try t.eq(@ptrToInt(&funcSymEntry.entryT), @ptrToInt(&funcSymEntry));
    try t.eq(@ptrToInt(&funcSymEntry.innerExtra), @ptrToInt(&funcSymEntry) + 4);
    try t.eq(@ptrToInt(&funcSymEntry.inner), @ptrToInt(&funcSymEntry) + 8);

    try t.eq(@sizeOf(AbsFuncSigKey), 16);
    try t.eq(@sizeOf(RelFuncSigKey), 8);

    try t.eq(@sizeOf(Struct), 24);
    try t.eq(@sizeOf(FieldSymbolMap), 24);

    try t.eq(@alignOf(List), 8);
    var list: List = undefined;
    try t.eq(@ptrToInt(&list.list.ptr), @ptrToInt(&list) + 8);
    try t.eq(@alignOf(ListIterator), 8);

    try t.eq(@alignOf(Dir), 8);
    var dir: Dir = undefined;
    try t.eq(@ptrToInt(&dir.structId), @ptrToInt(&dir));
    try t.eq(@ptrToInt(&dir.rc), @ptrToInt(&dir) + 4);

    try t.eq(@alignOf(DirIterator), 8);
    var dirIter: DirIterator = undefined;
    try t.eq(@ptrToInt(&dirIter.structId), @ptrToInt(&dirIter));
    try t.eq(@ptrToInt(&dirIter.rc), @ptrToInt(&dirIter) + 4);

    const rstr = RawString{
        .structId = RawStringT,
        .rc = 1,
        .len = 1,
        .bufStart = undefined,
    };
    try t.eq(@ptrToInt(&rstr.structId), @ptrToInt(&rstr));
    try t.eq(@ptrToInt(&rstr.rc), @ptrToInt(&rstr) + 4);
    try t.eq(@ptrToInt(&rstr.len), @ptrToInt(&rstr) + 8);
    try t.eq(RawString.BufOffset, 12);
    try t.eq(@ptrToInt(&rstr.bufStart), @ptrToInt(&rstr) + RawString.BufOffset);

    const astr = Astring{
        .structId = AstringT,
        .rc = 1,
        .len = 1,
        .bufStart = undefined,
    };
    try t.eq(@ptrToInt(&astr.structId), @ptrToInt(&astr));
    try t.eq(@ptrToInt(&astr.rc), @ptrToInt(&astr) + 4);
    try t.eq(@ptrToInt(&astr.len), @ptrToInt(&astr) + 8);
    try t.eq(Astring.BufOffset, 12);
    try t.eq(@ptrToInt(&astr.bufStart), @ptrToInt(&astr) + Astring.BufOffset);

    const ustr = Ustring{
        .structId = UstringT,
        .rc = 1,
        .len = 1,
        .charLen = 1,
        .mruIdx = 0,
        .mruCharIdx = 0,
        .bufStart = undefined,
    };
    try t.eq(@ptrToInt(&ustr.structId), @ptrToInt(&ustr));
    try t.eq(@ptrToInt(&ustr.rc), @ptrToInt(&ustr) + 4);
    try t.eq(@ptrToInt(&ustr.len), @ptrToInt(&ustr) + 8);
    try t.eq(@ptrToInt(&ustr.charLen), @ptrToInt(&ustr) + 12);
    try t.eq(@ptrToInt(&ustr.mruIdx), @ptrToInt(&ustr) + 16);
    try t.eq(@ptrToInt(&ustr.mruCharIdx), @ptrToInt(&ustr) + 20);
    try t.eq(Ustring.BufOffset, 24);
    try t.eq(@ptrToInt(&ustr.bufStart), @ptrToInt(&ustr) + Ustring.BufOffset);

    const slice = StringSlice{
        .structId = StringSliceT,
        .rc = 1,
        .buf = undefined,
        .len = 1,
        .uCharLen = undefined,
        .uMruIdx = undefined,
        .uMruCharIdx = undefined,
        .extra = undefined,
    };
    try t.eq(@ptrToInt(&slice.structId), @ptrToInt(&slice));
    try t.eq(@ptrToInt(&slice.rc), @ptrToInt(&slice) + 4);
    try t.eq(@ptrToInt(&slice.buf), @ptrToInt(&slice) + 8);
    try t.eq(@ptrToInt(&slice.len), @ptrToInt(&slice) + 16);
    try t.eq(@ptrToInt(&slice.uCharLen), @ptrToInt(&slice) + 20);
    try t.eq(@ptrToInt(&slice.uMruIdx), @ptrToInt(&slice) + 24);
    try t.eq(@ptrToInt(&slice.uMruCharIdx), @ptrToInt(&slice) + 28);
    try t.eq(@ptrToInt(&slice.extra), @ptrToInt(&slice) + 32);

    const rslice = RawStringSlice{
        .structId = RawStringSliceT,
        .rc = 1,
        .buf = undefined,
        .len = 1,
        .parent = undefined,
    };
    try t.eq(@ptrToInt(&rslice.structId), @ptrToInt(&rslice));
    try t.eq(@ptrToInt(&rslice.rc), @ptrToInt(&rslice) + 4);
    try t.eq(@ptrToInt(&rslice.buf), @ptrToInt(&rslice) + 8);
    try t.eq(@ptrToInt(&rslice.len), @ptrToInt(&rslice) + 16);
    try t.eq(@ptrToInt(&rslice.parent), @ptrToInt(&rslice) + 24);

    try t.eq(@sizeOf(KeyU64), 8);
}

const MethodSymType = enum {
    func,
    nativeFunc1,
    nativeFunc2,
};

const NativeObjFuncPtr = *const fn (*UserVM, *anyopaque, [*]const Value, u8) Value;
const NativeObjFunc2Ptr = *const fn (*UserVM, *anyopaque, [*]const Value, u8) cy.ValuePair;
const NativeFuncPtr = *const fn (*UserVM, [*]const Value, u8) Value;

/// Keeping this small is better for function calls.
/// Secondary symbol data should be moved to `methodSymExtras`.
pub const MethodSym = struct {
    entryT: MethodSymType,
    /// Most recent sym used is cached avoid hashmap lookup. 
    mruStructId: StructId,
    inner: packed union {
        nativeFunc1: NativeObjFuncPtr,
        nativeFunc2: *const fn (*UserVM, *anyopaque, [*]const Value, u8) cy.ValuePair,
        func: packed struct {
            // pc: packed union {
            //     ptr: [*]const cy.OpData,
            //     offset: usize,
            // },
            pc: u32,
            /// Includes function params, locals, and return info slot.
            numLocals: u32,
        },
    },

    pub fn initFuncOffset(pc: usize, numLocals: u32) MethodSym {
        return .{
            .entryT = .func,
            .mruStructId = undefined,
            .inner = .{
                .func = .{
                    .pc = @intCast(u32, pc),
                    .numLocals = numLocals,
                },
            },
        };
    }

    pub fn initNativeFunc1(func: NativeObjFuncPtr) MethodSym {
        return .{
            .entryT = .nativeFunc1,
            .mruStructId = undefined,
            .inner = .{
                .nativeFunc1 = func,
            },
        };
    }

    pub fn initNativeFunc2(func: NativeObjFunc2Ptr) MethodSym {
        return .{
            .entryT = .nativeFunc2,
            .mruStructId = undefined,
            .inner = .{
                .nativeFunc2 = func,
            },
        };
    }
};

pub const VarSym = struct {
    value: Value,

    pub fn init(val: Value) VarSym {
        return .{
            .value = val,
        };
    }
};

const FuncSymbolEntryType = enum {
    nativeFunc1,
    func,
    closure,
    none,
};

pub const FuncSymDetail = struct {
    name: []const u8,
};

/// TODO: Rename to FuncSymbol.
pub const FuncSymbolEntry = extern struct {
    entryT: u32,
    innerExtra: extern union {
        nativeFunc1: extern struct {
            /// Used to wrap a native func as a function value.
            numParams: u32,
        },
    } = undefined,
    inner: extern union {
        nativeFunc1: *const fn (*UserVM, [*]const Value, u8) Value,
        func: packed struct {
            pc: u32,
            /// Includes locals, and return info slot. Does not include params.
            numLocals: u16,
            /// Num params used to wrap as function value.
            numParams: u16,
        },
        closure: *Closure,
    },

    pub fn initNativeFunc1(func: *const fn (*UserVM, [*]const Value, u8) Value, numParams: u32) FuncSymbolEntry {
        return .{
            .entryT = @enumToInt(FuncSymbolEntryType.nativeFunc1),
            .innerExtra = .{
                .nativeFunc1 = .{
                    .numParams = numParams,
                }
            },
            .inner = .{
                .nativeFunc1 = func,
            },
        };
    }

    pub fn initFunc(pc: usize, numLocals: u16, numParams: u16) FuncSymbolEntry {
        return .{
            .entryT = @enumToInt(FuncSymbolEntryType.func),
            .inner = .{
                .func = .{
                    .pc = @intCast(u32, pc),
                    .numLocals = numLocals,
                    .numParams = numParams,
                },
            },
        };
    }

    pub fn initClosure(closure: *Closure) FuncSymbolEntry {
        return .{
            .entryT = @enumToInt(FuncSymbolEntryType.closure),
            .inner = .{
                .closure = closure,
            },
        };
    }
};

const TagTypeId = u32;
const TagType = struct {
    name: []const u8,
    numMembers: u32,
};

const StructKey = KeyU64;

pub const StructId = u32;

const Struct = struct {
    name: []const u8,
    numFields: u32,
};

// const StructSymbol = struct {
//     name: []const u8,
// };

const SymbolId = u32;

pub const TraceInfo = struct {
    opCounts: []OpCount = &.{},
    totalOpCounts: u32,
    numRetains: u32,
    numRetainAttempts: u32,
    numReleases: u32,
    numReleaseAttempts: u32,
    numForceReleases: u32,
    numRetainCycles: u32,
    numRetainCycleRoots: u32,
};

pub const OpCount = struct {
    code: u32,
    count: u32,
};

const RcNode = struct {
    visited: bool,
    entered: bool,
};

const Root = @This();

const UserVMAlign = 8;

/// A simplified VM handle.
pub const UserVM = struct {
    dummy: u64 align(UserVMAlign) = undefined,

    pub fn init(self: *UserVM, alloc: std.mem.Allocator) !void {
        try @ptrCast(*VM, self).init(alloc);
    }

    pub fn deinit(self: *UserVM) void {
        @ptrCast(*VM, self).deinit();
    }

    pub fn setTrace(self: *UserVM, trace: *TraceInfo) void {
        if (!TraceEnabled) {
            return;
        }
        @ptrCast(*VM, self).trace = trace;
    }

    pub fn getStackTrace(self: *UserVM) *const StackTrace {
        return @ptrCast(*const VM, self).getStackTrace();
    }

    pub fn getParserErrorMsg(self: *const UserVM) []const u8 {
        return @ptrCast(*const VM, self).parser.last_err;
    }

    pub fn getCompileErrorMsg(self: *const UserVM) []const u8 {
        return @ptrCast(*const VM, self).compiler.lastErr;
    }

    pub fn allocPanicMsg(self: *const UserVM) ![]const u8 {
        return debug.allocPanicMsg(@ptrCast(*const VM, self));
    }

    pub fn dumpPanicStackTrace(self: *UserVM) !void {
        @setCold(true);
        const vm = @ptrCast(*VM, self);
        const msg = try self.allocPanicMsg();
        defer vm.alloc.free(msg);
        fmt.printStderr("panic: {}\n\n", &.{v(msg)});
        const trace = vm.getStackTrace();
        try trace.dump(vm);
    }

    pub fn dumpInfo(self: *UserVM) void {
        @ptrCast(*VM, self).dumpInfo();
    }

    pub fn dumpStats(self: *UserVM) void {
        @ptrCast(*VM, self).dumpStats();
    }

    pub fn fillUndefinedStackSpace(_: UserVM, val: Value) void {
        std.mem.set(Value, gvm.stack, val);
    }

    pub inline fn releaseObject(self: *UserVM, obj: *HeapObject) void {
        Root.releaseObject(@ptrCast(*VM, self), obj);
    }

    pub inline fn release(self: *UserVM, val: Value) void {
        Root.release(@ptrCast(*VM, self), val);
    }

    pub inline fn retain(self: *UserVM, val: Value) void {
        @ptrCast(*VM, self).retain(val);
    }

    pub inline fn retainObject(self: *UserVM, obj: *HeapObject) void {
        @ptrCast(*VM, self).retainObject(obj);
    }

    pub inline fn getGlobalRC(self: *const UserVM) usize {
        return @ptrCast(*const VM, self).getGlobalRC();
    }

    pub inline fn checkMemory(self: *UserVM) !bool {
        return @ptrCast(*VM, self).checkMemory();
    }

    pub inline fn compile(self: *UserVM, srcUri: []const u8, src: []const u8) !cy.ByteCodeBuffer {
        return @ptrCast(*VM, self).compile(srcUri, src);
    }

    pub inline fn eval(self: *UserVM, srcUri: []const u8, src: []const u8, config: EvalConfig) !Value {
        return @ptrCast(*VM, self).eval(srcUri, src, config);
    }

    pub inline fn allocator(self: *const UserVM) std.mem.Allocator {
        return @ptrCast(*const VM, self).alloc;
    }

    pub inline fn allocEmptyList(self: *UserVM) !Value {
        return @ptrCast(*VM, self).allocEmptyList();
    }

    pub inline fn allocEmptyMap(self: *UserVM) !Value {
        return @ptrCast(*VM, self).allocEmptyMap();
    }

    pub inline fn allocList(self: *UserVM, elems: []const Value) !Value {
        return @ptrCast(*VM, self).allocList(elems);
    }

    pub inline fn allocListFill(self: *UserVM, val: Value, n: u32) !Value {
        return @ptrCast(*VM, self).allocListFill(val, n);
    }

    pub inline fn allocUnsetUstringObject(self: *UserVM, len: usize, charLen: u32) !*HeapObject {
        return @ptrCast(*VM, self).allocUnsetUstringObject(len, charLen);
    }

    pub inline fn allocUnsetAstringObject(self: *UserVM, len: usize) !*HeapObject {
        return @ptrCast(*VM, self).allocUnsetAstringObject(len);
    }

    pub inline fn allocUnsetRawStringObject(self: *UserVM, len: usize) !*HeapObject {
        return @ptrCast(*VM, self).allocUnsetRawStringObject(len);
    }

    pub inline fn allocRawString(self: *UserVM, str: []const u8) !Value {
        return @ptrCast(*VM, self).allocRawString(str);
    }

    pub inline fn allocAstring(self: *UserVM, str: []const u8) !Value {
        return @ptrCast(*VM, self).getOrAllocAstring(str);
    }

    pub inline fn allocUstring(self: *UserVM, str: []const u8, charLen: u32) !Value {
        return @ptrCast(*VM, self).getOrAllocUstring(str, charLen);
    }

    pub inline fn allocStringNoIntern(self: *UserVM, str: []const u8, utf8: bool) !Value {
        return @ptrCast(*VM, self).allocString(str, utf8);
    }

    pub inline fn allocStringInfer(self: *UserVM, str: []const u8) !Value {
        return @ptrCast(*VM, self).getOrAllocStringInfer(str);
    }

    pub inline fn allocRawStringSlice(self: *UserVM, slice: []const u8, parent: *HeapObject) !Value {
        return @ptrCast(*VM, self).allocRawStringSlice(slice, parent);
    }

    pub inline fn allocAstringSlice(self: *UserVM, slice: []const u8, parent: *HeapObject) !Value {
        return @ptrCast(*VM, self).allocAstringSlice(slice, parent);
    }

    pub inline fn allocUstringSlice(self: *UserVM, slice: []const u8, charLen: u32, parent: ?*HeapObject) !Value {
        return @ptrCast(*VM, self).allocUstringSlice(slice, charLen, parent);
    }

    pub inline fn allocOwnedAstring(self: *UserVM, str: *HeapObject) !Value {
        return @ptrCast(*VM, self).getOrAllocOwnedAstring(str);
    }

    pub inline fn allocOwnedUstring(self: *UserVM, str: *HeapObject) !Value {
        return @ptrCast(*VM, self).getOrAllocOwnedUstring(str);
    }

    pub inline fn allocRawStringConcat(self: *UserVM, left: []const u8, right: []const u8) !Value {
        return @ptrCast(*VM, self).allocRawStringConcat(left, right);
    }

    pub inline fn allocAstringConcat3(self: *UserVM, str1: []const u8, str2: []const u8, str3: []const u8) !Value {
        return @ptrCast(*VM, self).getOrAllocAstringConcat3(str1, str2, str3);
    }

    pub inline fn allocUstringConcat3(self: *UserVM, str1: []const u8, str2: []const u8, str3: []const u8, charLen: u32) !Value {
        return @ptrCast(*VM, self).getOrAllocUstringConcat3(str1, str2, str3, charLen);
    }

    pub inline fn allocAstringConcat(self: *UserVM, left: []const u8, right: []const u8) !Value {
        return @ptrCast(*VM, self).getOrAllocAstringConcat(left, right);
    }

    pub inline fn allocUstringConcat(self: *UserVM, left: []const u8, right: []const u8, charLen: u32) !Value {
        return @ptrCast(*VM, self).getOrAllocUstringConcat(left, right, charLen);
    }

    pub inline fn allocObjectSmall(self: *UserVM, sid: StructId, fields: []const Value) !Value {
        return @ptrCast(*VM, self).allocObjectSmall(sid, fields);
    }

    pub inline fn allocObject(self: *UserVM, sid: StructId, fields: []const Value) !Value {
        return @ptrCast(*VM, self).allocObject(sid, fields);
    }

    pub inline fn allocListIterator(self: *UserVM, list: *List) !Value {
        return @ptrCast(*VM, self).allocListIterator(list);
    }

    pub inline fn allocMapIterator(self: *UserVM, map: *Map) !Value {
        return @ptrCast(*VM, self).allocMapIterator(map);
    }

    pub inline fn allocDir(self: *UserVM, fd: std.os.fd_t, iterable: bool) !Value {
        return @ptrCast(*VM, self).allocDir(fd, iterable);
    }

    pub inline fn allocDirIterator(self: *UserVM, dir: *Dir, recursive: bool) !Value {
        return @ptrCast(*VM, self).allocDirIterator(dir, recursive);
    }

    pub inline fn allocFile(self: *UserVM, fd: std.os.fd_t) !Value {
        return @ptrCast(*VM, self).allocFile(fd);
    }

    pub inline fn valueAsString(self: *UserVM, val: Value) []const u8 {
        return @ptrCast(*const VM, self).valueAsString(val);
    }

    pub inline fn getOrWriteValueString(self: *UserVM, writer: anytype, val: Value, charLen: *u32) []const u8 {
        return @ptrCast(*const VM, self).getOrWriteValueString(writer, val, charLen, true);
    }

    pub inline fn valueToTempString(self: *UserVM, val: Value) []const u8 {
        return @ptrCast(*const VM, self).valueToTempString(val);
    }

    pub inline fn valueToTempString2(self: *UserVM, val: Value, outCharLen: *u32) []const u8 {
        return @ptrCast(*const VM, self).valueToTempString2(val, outCharLen);
    }

    pub inline fn valueToNextTempString(self: *UserVM, val: Value) []const u8 {
        return @ptrCast(*const VM, self).valueToNextTempString(val);
    }

    pub inline fn valueToNextTempString2(self: *UserVM, val: Value, outCharLen: *u32) []const u8 {
        return @ptrCast(*const VM, self).valueToNextTempString2(val, outCharLen);
    }

    pub inline fn valueToString(self: *UserVM, val: Value) ![]const u8 {
        return @ptrCast(*const VM, self).valueToString(val);
    }

    /// Used to return a panic from a native function body.
    pub fn returnPanic(self: *UserVM, msg: []const u8) Value {
        @setCold(true);
        const vm = @ptrCast(*VM, self);
        const dupe = vm.alloc.dupe(u8, msg) catch stdx.fatal();
        vm.panicPayload = @intCast(u64, @ptrToInt(dupe.ptr)) | (@as(u64, dupe.len) << 48);
        vm.panicType = .msg;
        return Value.Panic;
    }

    pub inline fn getStaticUstringHeader(self: *UserVM, start: u32) *align (1) cy.StaticUstringHeader {
        return Root.getStaticUstringHeader(@ptrCast(*VM, self), start);
    }

    pub inline fn getStaticString(self: *UserVM, start: u32, end: u32) []const u8 {
        return @ptrCast(*VM, self).strBuf[start..end];
    }

    pub inline fn getStaticStringChar(self: *UserVM, idx: u32) u8 {
        return @ptrCast(*VM, self).strBuf[idx];
    }

    pub fn getNewFramePtrOffset(self: *UserVM, args: [*]const Value) u32 {
        const vm = @ptrCast(*const VM, self);
        return @intCast(u32, framePtrOffsetFrom(vm.stack.ptr, args));
    }

    pub fn callFunc(self: *UserVM, framePtr: u32, func: Value, args: []const Value) !Value {
        const vm = @ptrCast(*VM, self);

        try ensureTotalStackCapacity(vm, framePtr + args.len + 1 + 4);
        const saveFramePtrOffset = framePtrOffsetFrom(vm.stack.ptr, vm.framePtr);
        vm.framePtr = vm.stack.ptr + framePtr;

        self.retain(func);
        defer self.release(func);
        vm.framePtr[4 + args.len] = func;
        for (args) |arg, i| {
            self.retain(arg);
            vm.framePtr[4 + i] = arg;
        }
        const retInfo = buildReturnInfo(1, false);
        try callNoInline(vm, &vm.pc, &vm.framePtr, func, 0, @intCast(u8, args.len), retInfo);
        try @call(.never_inline, evalLoopGrowStack, .{vm});

        const res = vm.framePtr[0];

        // Restore framePtr.
        vm.framePtr = vm.stack.ptr + saveFramePtrOffset;

        return res;
    }
};

/// To reduce the amount of code inlined in the hot loop, handle StackOverflow at the top and resume execution.
/// This is also the entry way for native code to call into the VM, assuming pc, framePtr, and virtual registers are already set.
pub fn evalLoopGrowStack(vm: *VM) linksection(cy.HotSection) error{StackOverflow, OutOfMemory, Panic, OutOfBounds, NoDebugSym, End}!void {
    while (true) {
        @call(.always_inline, evalLoop, .{vm}) catch |err| {
            if (err == error.StackOverflow) {
                log.debug("grow stack", .{});
                try @call(.never_inline, growStackAuto, .{ vm });
                continue;
            } else if (err == error.End) {
                return;
            } else if (err == error.Panic) {
                try @call(.never_inline, gvm.buildStackTrace, .{true});
                return error.Panic;
            } else return err;
        };
        return;
    }
}

fn evalLoop(vm: *VM) linksection(cy.HotSection) error{StackOverflow, OutOfMemory, Panic, OutOfBounds, NoDebugSym, End}!void {
    var pc = vm.pc;
    var framePtr = vm.framePtr;
    defer {
        vm.pc = pc;
        vm.framePtr = framePtr;
    }

    while (true) {
        if (TraceEnabled) {
            const op = pc[0].code;
            vm.trace.opCounts[@enumToInt(op)].count += 1;
            vm.trace.totalOpCounts += 1;
        }
        if (builtin.mode == .Debug) {
            dumpEvalOp(vm, pc);
        }
        switch (pc[0].code) {
            .none => {
                framePtr[pc[1].arg] = Value.None;
                pc += 2;
                continue;
            },
            .constOp => {
                framePtr[pc[2].arg] = Value.initRaw(vm.consts[pc[1].arg].val);
                pc += 3;
                continue;
            },
            .constI8 => {
                framePtr[pc[2].arg] = Value.initF64(@intToFloat(f64, @bitCast(i8, pc[1].arg)));
                pc += 3;
                continue;
            },
            .constI8Int => {
                framePtr[pc[2].arg] = Value.initI32(@intCast(i32, @bitCast(i8, pc[1].arg)));
                pc += 3;
                continue;
            },
            .release => {
                release(vm, framePtr[pc[1].arg]);
                pc += 2;
                continue;
            },
            .releaseN => {
                const numLocals = pc[1].arg;
                for (pc[2..2+numLocals]) |local| {
                    release(vm, framePtr[local.arg]);
                }
                pc += 2 + numLocals;
                continue;
            },
            .fieldIC => {
                const recv = framePtr[pc[1].arg];
                const dst = pc[2].arg;
                if (recv.isPointer()) {
                    const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer());
                    if (obj.common.structId == @ptrCast(*align (1) u16, pc + 4).*) {
                        framePtr[dst] = obj.object.getValue(pc[6].arg);
                        pc += 7;
                        continue;
                    }
                } else {
                    return vm.getFieldMissingSymbolError();
                }
                // Deoptimize.
                pc[0] = cy.OpData{ .code = .field };
                // framePtr[dst] = try gvm.getField(recv, pc[3].arg);
                framePtr[dst] = try @call(.never_inline, gvm.getField, .{ recv, pc[3].arg });
                pc += 7;
                continue;
            },
            .copyRetainSrc => {
                const val = framePtr[pc[1].arg];
                framePtr[pc[2].arg] = val;
                vm.retain(val);
                pc += 3;
                continue;
            },
            .jumpNotCond => {
                const jump = @ptrCast(*const align(1) u16, pc + 1).*;
                const cond = framePtr[pc[3].arg];
                const condVal = if (cond.isBool()) b: {
                    break :b cond.asBool();
                } else b: {
                    break :b @call(.never_inline, cond.toBool, .{});
                };
                if (!condVal) {
                    pc += jump;
                } else {
                    pc += 4;
                }
                continue;
            },
            .neg => {
                const val = framePtr[pc[1].arg];
                // gvm.stack[gvm.framePtr + pc[2].arg] = if (val.isNumber())
                //     Value.initF64(-val.asF64())
                // else 
                    // @call(.never_inline, evalNegFallback, .{val});
                framePtr[pc[2].arg] = evalNeg(val);
                pc += 3;
                continue;
            },
            .compare => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                // Can immediately match numbers, objects, primitives.
                framePtr[pc[3].arg] = if (left.val == right.val) Value.True else 
                    @call(.never_inline, evalCompare, .{vm, left, right});
                pc += 4;
                continue;
            },
            .compareNot => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                // Can immediately match numbers, objects, primitives.
                framePtr[pc[3].arg] = if (left.val == right.val) Value.False else 
                    @call(.never_inline, evalCompareNot, .{vm, left, right});
                pc += 4;
                continue;
            },
            // .lessNumber => {
            //     @setRuntimeSafety(debug);
            //     const left = gvm.stack[gvm.framePtr + pc[1].arg];
            //     const right = gvm.stack[gvm.framePtr + pc[2].arg];
            //     const dst = pc[3].arg;
            //     pc += 4;
            //     gvm.stack[gvm.framePtr + dst] = Value.initBool(left.asF64() < right.asF64());
            //     continue;
            // },
            .add => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                if (Value.bothNumbers(left, right)) {
                    framePtr[pc[3].arg] = Value.initF64(left.asF64() + right.asF64());
                } else {
                    framePtr[pc[3].arg] = try @call(.never_inline, evalAddFallback, .{ left, right });
                }
                pc += 4;
                continue;
            },
            .addInt => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = Value.initI32(left.asI32() + right.asI32());
                pc += 4;
                continue;
            },
            .minus => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = if (Value.bothNumbers(left, right))
                    Value.initF64(left.asF64() - right.asF64())
                else @call(.never_inline, evalMinusFallback, .{left, right});
                pc += 4;
                continue;
            },
            .minusInt => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = Value.initI32(left.asI32() - right.asI32());
                pc += 4;
                continue;
            },
            .less => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = if (Value.bothNumbers(left, right))
                    Value.initBool(left.asF64() < right.asF64())
                else
                    @call(.never_inline, evalLessFallback, .{left, right});
                pc += 4;
                continue;
            },
            .lessInt => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = Value.initBool(left.asI32() < right.asI32());
                pc += 4;
                continue;
            },
            .greater => {
                const srcLeft = framePtr[pc[1].arg];
                const srcRight = framePtr[pc[2].arg];
                const dstLocal = pc[3].arg;
                pc += 4;
                framePtr[dstLocal] = evalGreater(srcLeft, srcRight);
                continue;
            },
            .lessEqual => {
                const srcLeft = framePtr[pc[1].arg];
                const srcRight = framePtr[pc[2].arg];
                const dstLocal = pc[3].arg;
                pc += 4;
                framePtr[dstLocal] = evalLessOrEqual(srcLeft, srcRight);
                continue;
            },
            .greaterEqual => {
                const srcLeft = framePtr[pc[1].arg];
                const srcRight = framePtr[pc[2].arg];
                const dstLocal = pc[3].arg;
                pc += 4;
                framePtr[dstLocal] = evalGreaterOrEqual(srcLeft, srcRight);
                continue;
            },
            .true => {
                framePtr[pc[1].arg] = Value.True;
                pc += 2;
                continue;
            },
            .false => {
                framePtr[pc[1].arg] = Value.False;
                pc += 2;
                continue;
            },
            .not => {
                const val = framePtr[pc[1].arg];
                framePtr[pc[2].arg] = evalNot(val);
                pc += 3;
                continue;
            },
            .stringTemplate => {
                const startLocal = pc[1].arg;
                const exprCount = pc[2].arg;
                const dst = pc[3].arg;
                const strCount = exprCount + 1;
                const strs = pc[4 .. 4 + strCount];
                pc += 4 + strCount;
                const vals = framePtr[startLocal .. startLocal + exprCount];
                const res = try @call(.never_inline, vm.allocStringTemplate, .{strs, vals});
                framePtr[dst] = res;
                continue;
            },
            .list => {
                const startLocal = pc[1].arg;
                const numElems = pc[2].arg;
                const dst = pc[3].arg;
                pc += 4;
                const elems = framePtr[startLocal..startLocal + numElems];
                const list = try vm.allocList(elems);
                framePtr[dst] = list;
                continue;
            },
            .mapEmpty => {
                const dst = pc[1].arg;
                pc += 2;
                framePtr[dst] = try vm.allocEmptyMap();
                continue;
            },
            .objectSmall => {
                const sid = pc[1].arg;
                const startLocal = pc[2].arg;
                const numFields = pc[3].arg;
                const fields = framePtr[startLocal .. startLocal + numFields];
                framePtr[pc[4].arg] = try vm.allocObjectSmall(sid, fields);
                if (builtin.mode == .Debug) {
                    vm.objectTraceMap.put(vm.alloc, framePtr[pc[4].arg].asHeapObject(*HeapObject), pcOffset(pc)) catch stdx.fatal();
                }
                pc += 5;
                continue;
            },
            .object => {
                const sid = pc[1].arg;
                const startLocal = pc[2].arg;
                const numFields = pc[3].arg;
                const fields = framePtr[startLocal .. startLocal + numFields];
                framePtr[pc[4].arg] = try vm.allocObject(sid, fields);
                pc += 5;
                continue;
            },
            .map => {
                const startLocal = pc[1].arg;
                const numEntries = pc[2].arg;
                const dst = pc[3].arg;
                const keyIdxes = pc[4..4+numEntries];
                pc += 4 + numEntries;
                const vals = framePtr[startLocal .. startLocal + numEntries];
                framePtr[dst] = try vm.allocMap(keyIdxes, vals);
                continue;
            },
            .slice => {
                const slice = &framePtr[pc[1].arg];
                const start = framePtr[pc[2].arg];
                const end = framePtr[pc[3].arg];
                framePtr[pc[4].arg] = try @call(.never_inline, vm.sliceOp, .{slice, start, end});
                pc += 5;
                continue;
            },
            .setInitN => {
                const numLocals = pc[1].arg;
                const locals = pc[2..2+numLocals];
                pc += 2 + numLocals;
                for (locals) |local| {
                    framePtr[local.arg] = Value.None;
                }
                continue;
            },
            .setIndex => {
                const leftv = framePtr[pc[1].arg];
                const indexv = framePtr[pc[2].arg];
                const rightv = framePtr[pc[3].arg];
                try @call(.never_inline, vm.setIndex, .{leftv, indexv, rightv});
                pc += 4;
                continue;
            },
            .setIndexRelease => {
                const leftv = framePtr[pc[1].arg];
                const indexv = framePtr[pc[2].arg];
                const rightv = framePtr[pc[3].arg];
                try @call(.never_inline, vm.setIndexRelease, .{leftv, indexv, rightv});
                pc += 4;
                continue;
            },
            .copy => {
                framePtr[pc[2].arg] = framePtr[pc[1].arg];
                pc += 3;
                continue;
            },
            .copyRetainRelease => {
                const src = pc[1].arg;
                const dst = pc[2].arg;
                pc += 3;
                vm.retain(framePtr[src]);
                release(vm, framePtr[dst]);
                framePtr[dst] = framePtr[src];
                continue;
            },
            .copyReleaseDst => {
                const dst = pc[2].arg;
                release(vm, framePtr[dst]);
                framePtr[dst] = framePtr[pc[1].arg];
                pc += 3;
                continue;
            },
            .retain => {
                vm.retain(framePtr[pc[1].arg]);
                pc += 2;
                continue;
            },
            .index => {
                const recv = &framePtr[pc[1].arg];
                const indexv = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = try @call(.never_inline, vm.getIndex, .{recv, indexv});
                pc += 4;
                continue;
            },
            .reverseIndex => {
                const recv = &framePtr[pc[1].arg];
                const indexv = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = try @call(.never_inline, vm.getReverseIndex, .{recv, indexv});
                pc += 4;
                continue;
            },
            .jump => {
                @setRuntimeSafety(false);
                pc += @intCast(usize, @ptrCast(*const align(1) i16, &pc[1]).*);
                continue;
            },
            .jumpCond => {
                const jump = @ptrCast(*const align(1) i16, pc + 1).*;
                const cond = framePtr[pc[3].arg];
                const condVal = if (cond.isBool()) b: {
                    break :b cond.asBool();
                } else b: {
                    break :b @call(.never_inline, cond.toBool, .{});
                };
                if (condVal) {
                    @setRuntimeSafety(false);
                    pc += @intCast(usize, jump);
                } else {
                    pc += 4;
                }
                continue;
            },
            .call0 => {
                const startLocal = pc[1].arg;
                const numArgs = pc[2].arg;
                pc += 3;

                const callee = framePtr[startLocal + numArgs + 4];
                const retInfo = buildReturnInfo(0, true);
                // const retInfo = buildReturnInfo(pcOffset(pc), framePtrOffset(framePtr), 0, true);
                // try @call(.never_inline, gvm.call, .{&pc, callee, numArgs, retInfo});
                try @call(.always_inline, call, .{vm, &pc, &framePtr, callee, startLocal, numArgs, retInfo});
                continue;
            },
            .call1 => {
                const startLocal = pc[1].arg;
                const numArgs = pc[2].arg;
                pc += 3;

                const callee = framePtr[startLocal + numArgs + 4];
                const retInfo = buildReturnInfo(1, true);
                // const retInfo = buildReturnInfo(pcOffset(pc), framePtrOffset(framePtr), 1, true);
                // try @call(.never_inline, gvm.call, .{&pc, callee, numArgs, retInfo});
                try @call(.always_inline, call, .{vm, &pc, &framePtr, callee, startLocal, numArgs, retInfo});
                continue;
            },
            .callObjFuncIC => {
                const startLocal = pc[1].arg;
                const numArgs = pc[2].arg;
                const recv = framePtr[startLocal + numArgs + 4 - 1];
                const typeId: u32 = if (recv.isPointer())
                    recv.asHeapObject(*HeapObject).common.structId
                else recv.getPrimitiveTypeId();

                const cachedStruct = @ptrCast(*align (1) u16, pc + 12).*;
                if (typeId == cachedStruct) {
                    const numLocals = pc[5].arg;
                    if (@ptrToInt(framePtr + startLocal + numLocals) >= @ptrToInt(vm.stackEndPtr)) {
                        return error.StackOverflow;
                    }
                    const retFramePtr = Value{ .retFramePtr = framePtr };
                    framePtr += startLocal;
                    @ptrCast([*]u8, framePtr + 1)[0] = pc[3].arg;
                    @ptrCast([*]u8, framePtr + 1)[1] = 0;
                    framePtr[2] = Value{ .retPcPtr = pc + 14 };
                    framePtr[3] = retFramePtr;
                    pc = @intToPtr([*]cy.OpData, @intCast(usize, @ptrCast(*align(1) u48, pc + 6).*));
                    continue;
                }

                // Deoptimize.
                pc[0] = cy.OpData{ .code = .callObjSym };
                continue;
            },
            .callObjNativeFuncIC => {
                const startLocal = pc[1].arg;
                const numArgs = pc[2].arg;
                const recv = &framePtr[startLocal + numArgs + 4 - 1];
                var obj: *HeapObject = undefined;
                var typeId: u32 = undefined;
                if (recv.isPointer()) {
                    obj = recv.asHeapObject(*HeapObject);
                    typeId = obj.common.structId;
                } else {
                    obj = @ptrCast(*HeapObject, recv);
                    typeId = recv.getPrimitiveTypeId();
                }

                const cachedStruct = @ptrCast(*align (1) u16, pc + 12).*;
                if (typeId == cachedStruct) {
                    // const newFramePtr = framePtr + startLocal;
                    vm.framePtr = framePtr;
                    const func = @intToPtr(NativeObjFuncPtr, @intCast(usize, @ptrCast(*align (1) u48, pc + 6).*));
                    const res = func(@ptrCast(*UserVM, vm), obj, @ptrCast([*]const Value, framePtr + startLocal + 4), numArgs);
                    if (res.isPanic()) {
                        return error.Panic;
                    }
                    const numRet = pc[3].arg;
                    if (numRet == 1) {
                        framePtr[startLocal] = res;
                    } else {
                        switch (numRet) {
                            0 => {
                                // Nop.
                            },
                            1 => stdx.panic("not possible"),
                            else => {
                                stdx.panic("unsupported numret");
                            },
                        }
                    }
                    pc += 14;
                    // In the future, we might allow native functions to change the pc and framePtr.
                    // pc = vm.pc;
                    // framePtr = vm.framePtr;
                    continue;
                }

                // Deoptimize.
                pc[0] = cy.OpData{ .code = .callObjSym };
                continue;
            },
            .callFuncIC => {
                const startLocal = pc[1].arg;
                const numLocals = pc[4].arg;
                if (@ptrToInt(framePtr + startLocal + numLocals) >= @ptrToInt(vm.stackEndPtr)) {
                    return error.StackOverflow;
                }

                const retFramePtr = Value{ .retFramePtr = framePtr };
                framePtr += startLocal;
                @ptrCast([*]u8, framePtr + 1)[0] = pc[3].arg;
                @ptrCast([*]u8, framePtr + 1)[1] = 0;
                framePtr[2] = Value{ .retPcPtr = pc + 11 };
                framePtr[3] = retFramePtr;

                pc = @intToPtr([*]cy.OpData, @intCast(usize, @ptrCast(*align(1) u48, pc + 5).*));
                continue;
            },
            .callNativeFuncIC => {
                const startLocal = pc[1].arg;
                const numArgs = pc[2].arg;

                const newFramePtr = framePtr + startLocal;
                vm.framePtr = newFramePtr;
                const func = @intToPtr(NativeFuncPtr, @intCast(usize, @ptrCast(*align (1) u48, pc + 5).*));
                const res = func(@ptrCast(*UserVM, vm), @ptrCast([*]const Value, newFramePtr + 4), numArgs);
                if (res.isPanic()) {
                    return error.Panic;
                }
                const numRet = pc[3].arg;
                if (numRet == 1) {
                    newFramePtr[0] = res;
                } else {
                    switch (numRet) {
                        0 => {
                            // Nop.
                        },
                        1 => stdx.panic("not possible"),
                        else => stdx.panic("unsupported"),
                    }
                }
                pc += 11;
                continue;
            },
            .ret1 => {
                if (@call(.always_inline, popStackFrameLocal1, .{vm, &pc, &framePtr})) {
                    continue;
                } else {
                    return;
                }
            },
            .ret0 => {
                if (@call(.always_inline, popStackFrameLocal0, .{&pc, &framePtr})) {
                    continue;
                } else {
                    return;
                }
            },
            .setFieldReleaseIC => {
                const recv = framePtr[pc[1].arg];
                if (recv.isPointer()) {
                    const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer());
                    if (obj.common.structId == @ptrCast(*align (1) u16, pc + 4).*) {
                        const lastValue = obj.object.getValuePtr(pc[6].arg);
                        release(vm, lastValue.*);
                        lastValue.* = framePtr[pc[2].arg];
                        pc += 7;
                        continue;
                    }
                } else {
                    return vm.getFieldMissingSymbolError();
                }
                // Deoptimize.
                pc[0] = cy.OpData{ .code = .setFieldRelease };
                // framePtr[dst] = try gvm.getField(recv, pc[3].arg);
                try @call(.never_inline, gvm.setFieldRelease, .{ recv, pc[3].arg, framePtr[pc[2].arg] });
                pc += 7;
                continue;
            },
            .fieldRetainIC => {
                const recv = framePtr[pc[1].arg];
                const dst = pc[2].arg;
                if (recv.isPointer()) {
                    const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer());
                    if (obj.common.structId == @ptrCast(*align (1) u16, pc + 4).*) {
                        framePtr[dst] = obj.object.getValue(pc[6].arg);
                        vm.retain(framePtr[dst]);
                        pc += 7;
                        continue;
                    }
                } else {
                    return vm.getFieldMissingSymbolError();
                }
                // Deoptimize.
                pc[0] = cy.OpData{ .code = .fieldRetain };
                // framePtr[dst] = try gvm.getField(recv, pc[3].arg);
                framePtr[dst] = try @call(.never_inline, gvm.getField, .{ recv, pc[3].arg });
                vm.retain(framePtr[dst]);
                pc += 7;
                continue;
            },
            .forRangeInit => {
                const start = framePtr[pc[1].arg].toF64();
                const end = framePtr[pc[2].arg].toF64();
                framePtr[pc[2].arg] = Value.initF64(end);
                var step = framePtr[pc[3].arg].toF64();
                if (step < 0) {
                    step = -step;
                }
                framePtr[pc[3].arg] = Value.initF64(step);
                if (start == end) {
                    pc += @ptrCast(*const align(1) u16, pc + 6).* + 7;
                } else {
                    framePtr[pc[4].arg] = Value.initF64(start);
                    framePtr[pc[5].arg] = Value.initF64(start);
                    const offset = @ptrCast(*const align(1) u16, pc + 6).*;
                    pc[offset] = if (start < end)
                        cy.OpData{ .code = .forRange }
                    else
                        cy.OpData{ .code = .forRangeReverse };
                    pc += 8;
                }
            },
            .forRange => {
                const counter = framePtr[pc[1].arg].asF64() + framePtr[pc[2].arg].asF64();
                if (counter < framePtr[pc[3].arg].asF64()) {
                    framePtr[pc[1].arg] = Value.initF64(counter);
                    framePtr[pc[4].arg] = Value.initF64(counter);
                    pc -= @ptrCast(*const align(1) u16, pc + 5).*;
                } else {
                    pc += 7;
                }
            },
            .forRangeReverse => {
                const counter = framePtr[pc[1].arg].asF64() - framePtr[pc[2].arg].asF64();
                if (counter > framePtr[pc[3].arg].asF64()) {
                    framePtr[pc[1].arg] = Value.initF64(counter);
                    framePtr[pc[4].arg] = Value.initF64(counter);
                    pc -= @ptrCast(*const align(1) u16, pc + 5).*;
                } else {
                    pc += 7;
                }
            },
            .jumpNotNone => {
                const offset = @ptrCast(*const align(1) i16, &pc[1]).*;
                if (!framePtr[pc[3].arg].isNone()) {
                    @setRuntimeSafety(false);
                    pc += @intCast(usize, offset);
                } else {
                    pc += 4;
                }
                continue;
            },
            .setField => {
                const fieldId = pc[1].arg;
                const left = pc[2].arg;
                const right = pc[3].arg;
                pc += 4;

                const recv = framePtr[left];
                const val = framePtr[right];
                try gvm.setField(recv, fieldId, val);
                // try @call(.never_inline, gvm.setField, .{recv, fieldId, val});
                continue;
            },
            .fieldRelease => {
                const fieldId = pc[1].arg;
                const left = pc[2].arg;
                const dst = pc[3].arg;
                pc += 4;
                const recv = framePtr[left];
                framePtr[dst] = try @call(.never_inline, gvm.getField, .{recv, fieldId});
                release(vm, recv);
                continue;
            },
            .field => {
                const left = pc[1].arg;
                const dst = pc[2].arg;
                const symId = pc[3].arg;
                const recv = framePtr[left];
                if (recv.isPointer()) {
                    const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer());
                    // const offset = @call(.never_inline, gvm.getFieldOffset, .{obj, symId });
                    const offset = gvm.getFieldOffset(obj, symId);
                    if (offset != NullByteId) {
                        framePtr[dst] = obj.object.getValue(offset);
                        // Inline cache.
                        pc[0] = cy.OpData{ .code = .fieldIC };
                        @ptrCast(*align (1) u16, pc + 4).* = @intCast(u16, obj.common.structId);
                        pc[6] = cy.OpData { .arg = offset };
                    } else {
                        framePtr[dst] = @call(.never_inline, gvm.getFieldFallback, .{obj, gvm.fieldSyms.buf[symId].name});
                    }
                } else {
                    return vm.getFieldMissingSymbolError();
                }
                pc += 7;
                continue;
            },
            .fieldRetain => {
                const recv = framePtr[pc[1].arg];
                const dst = pc[2].arg;
                const symId = pc[3].arg;
                if (recv.isPointer()) {
                    const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer());
                    // const offset = @call(.never_inline, gvm.getFieldOffset, .{obj, symId });
                    const offset = gvm.getFieldOffset(obj, symId);
                    if (offset != NullByteId) {
                        framePtr[dst] = obj.object.getValue(offset);
                        // Inline cache.
                        pc[0] = cy.OpData{ .code = .fieldRetainIC };
                        @ptrCast(*align (1) u16, pc + 4).* = @intCast(u16, obj.common.structId);
                        pc[6] = cy.OpData { .arg = offset };
                    } else {
                        framePtr[dst] = @call(.never_inline, gvm.getFieldFallback, .{obj, gvm.fieldSyms.buf[symId].name});
                    }
                    vm.retain(framePtr[dst]);
                } else {
                    return vm.getFieldMissingSymbolError();
                }
                pc += 7;
                continue;
            },
            .setFieldRelease => {
                const recv = framePtr[pc[1].arg];
                const val = framePtr[pc[2].arg];
                const symId = pc[3].arg;
                if (recv.isPointer()) {
                    const obj = stdx.ptrAlignCast(*HeapObject, recv.asPointer());
                    // const offset = @call(.never_inline, gvm.getFieldOffset, .{obj, symId });
                    const offset = gvm.getFieldOffset(obj, symId);
                    if (offset != NullByteId) {
                        const lastValue = obj.object.getValuePtr(offset);
                        release(vm, lastValue.*);
                        lastValue.* = val;

                        // Inline cache.
                        pc[0] = cy.OpData{ .code = .setFieldReleaseIC };
                        @ptrCast(*align (1) u16, pc + 4).* = @intCast(u16, obj.common.structId);
                        pc[6] = cy.OpData { .arg = offset };
                        pc += 7;
                        continue;
                    } else {
                        return vm.getFieldMissingSymbolError();
                    }
                } else {
                    return vm.setFieldNotObjectError();
                }
                pc += 7;
                continue;
            },
            .lambda => {
                const funcPc = pcOffset(pc) - pc[1].arg;
                const numParams = pc[2].arg;
                const numLocals = pc[3].arg;
                const dst = pc[4].arg;
                pc += 5;
                framePtr[dst] = try @call(.never_inline, vm.allocLambda, .{funcPc, numParams, numLocals});
                continue;
            },
            .closure => {
                const funcPc = pcOffset(pc) - pc[1].arg;
                const numParams = pc[2].arg;
                const numCaptured = pc[3].arg;
                const numLocals = pc[4].arg;
                const dst = pc[5].arg;
                const capturedVals = pc[6..6+numCaptured];
                pc += 6 + numCaptured;

                framePtr[dst] = try @call(.never_inline, vm.allocClosure, .{framePtr, funcPc, numParams, numLocals, capturedVals});
                continue;
            },
            .staticVar => {
                const symId = pc[1].arg;
                const sym = vm.varSyms.buf[symId];
                framePtr[pc[2].arg] = sym.value;
                pc += 3;
                continue;
            },
            .setStaticVar => {
                const symId = pc[1].arg;
                vm.varSyms.buf[symId].value = framePtr[pc[2].arg];
                pc += 3;
                continue;
            },
            .staticFunc => {
                const symId = pc[1].arg;
                framePtr[pc[2].arg] = try vm.allocFuncFromSym(symId);
                pc += 3;
                continue;
            },
            .coreturn => {
                pc += 1;
                if (vm.curFiber != &vm.mainFiber) {
                    const res = popFiber(vm, NullId, framePtr, framePtr[1]);
                    pc = res.pc;
                    framePtr = res.framePtr;
                }
                continue;
            },
            .coresume => {
                const fiber = framePtr[pc[1].arg];
                if (fiber.isPointer()) {
                    const obj = stdx.ptrAlignCast(*HeapObject, fiber.asPointer().?);
                    if (obj.common.structId == FiberS) {
                        if (&obj.fiber != vm.curFiber) {
                            // Only resume fiber if it's not done.
                            if (obj.fiber.pc != NullId) {
                                const res = pushFiber(vm, pcOffset(pc + 3), framePtr, &obj.fiber, pc[2].arg);
                                pc = res.pc;
                                framePtr = res.framePtr;
                                continue;
                            }
                        }
                    }
                    releaseObject(vm, obj);
                }
                pc += 3;
                continue;
            },
            .coyield => {
                if (vm.curFiber != &vm.mainFiber) {
                    // Only yield on user fiber.
                    const res = popFiber(vm, pcOffset(pc), framePtr, Value.None);
                    pc = res.pc;
                    framePtr = res.framePtr;
                } else {
                    pc += 3;
                }
                continue;
            },
            .coinit => {
                const startArgsLocal = pc[1].arg;
                const numArgs = pc[2].arg;
                const jump = pc[3].arg;
                const initialStackSize = pc[4].arg;
                const dst = pc[5].arg;

                const args = framePtr[startArgsLocal..startArgsLocal + numArgs];
                const fiber = try @call(.never_inline, allocFiber, .{pcOffset(pc + 6), args, initialStackSize});
                framePtr[dst] = fiber;
                pc += jump;
                continue;
            },
            .mul => {
                const srcLeft = framePtr[pc[1].arg];
                const srcRight = framePtr[pc[2].arg];
                const dstLocal = pc[3].arg;
                pc += 4;
                framePtr[dstLocal] = @call(.never_inline, evalMultiply, .{srcLeft, srcRight});
                continue;
            },
            .div => {
                const srcLeft = framePtr[pc[1].arg];
                const srcRight = framePtr[pc[2].arg];
                const dstLocal = pc[3].arg;
                pc += 4;
                framePtr[dstLocal] = @call(.never_inline, evalDivide, .{srcLeft, srcRight});
                continue;
            },
            .mod => {
                const srcLeft = framePtr[pc[1].arg];
                const srcRight = framePtr[pc[2].arg];
                const dstLocal = pc[3].arg;
                pc += 4;
                framePtr[dstLocal] = @call(.never_inline, evalMod, .{srcLeft, srcRight});
                continue;
            },
            .pow => {
                const srcLeft = framePtr[pc[1].arg];
                const srcRight = framePtr[pc[2].arg];
                const dstLocal = pc[3].arg;
                pc += 4;
                framePtr[dstLocal] = @call(.never_inline, evalPower, .{srcLeft, srcRight});
                continue;
            },
            .box => {
                const value = framePtr[pc[1].arg];
                vm.retain(value);
                framePtr[pc[2].arg] = try allocBox(vm, value);
                pc += 3;
                continue;
            },
            .setBoxValue => {
                const box = framePtr[pc[1].arg];
                const rval = framePtr[pc[2].arg];
                pc += 3;
                if (builtin.mode == .Debug) {
                    std.debug.assert(box.isPointer());
                }
                const obj = stdx.ptrAlignCast(*HeapObject, box.asPointer().?);
                if (builtin.mode == .Debug) {
                    std.debug.assert(obj.common.structId == BoxS);
                }
                obj.box.val = rval;
                continue;
            },
            .setBoxValueRelease => {
                const box = framePtr[pc[1].arg];
                const rval = framePtr[pc[2].arg];
                pc += 3;
                if (builtin.mode == .Debug) {
                    std.debug.assert(box.isPointer());
                }
                const obj = stdx.ptrAlignCast(*HeapObject, box.asPointer().?);
                if (builtin.mode == .Debug) {
                    std.debug.assert(obj.common.structId == BoxS);
                }
                @call(.never_inline, release, .{vm, obj.box.val});
                obj.box.val = rval;
                continue;
            },
            .boxValue => {
                const box = framePtr[pc[1].arg];
                if (box.isPointer()) {
                    const obj = stdx.ptrAlignCast(*HeapObject, box.asPointer().?);
                    if (builtin.mode == .Debug) {
                        std.debug.assert(obj.common.structId == BoxS);
                    }
                    framePtr[pc[2].arg] = obj.box.val;
                } else {
                    if (builtin.mode == .Debug) {
                        std.debug.assert(box.isNone());
                    }
                    framePtr[pc[2].arg] = Value.None;
                }
                pc += 3;
                continue;
            },
            .boxValueRetain => {
                const box = framePtr[pc[1].arg];
                // if (builtin.mode == .Debug) {
                //     std.debug.assert(box.isPointer());
                // }
                // const obj = stdx.ptrAlignCast(*HeapObject, box.asPointer().?);
                // if (builtin.mode == .Debug) {
                //     // const obj = stdx.ptrAlignCast(*HeapObject, box.asPointer().?);
                //     std.debug.assert(obj.common.structId == BoxS);
                // }
                // gvm.stack[gvm.framePtr + pc[2].arg] = obj.box.val;
                // vm.retain(obj.box.val);
                // pc += 3;
                framePtr[pc[2].arg] = @call(.never_inline, boxValueRetain, .{box});
                pc += 3;
                continue;
            },
            .tag => {
                const tagId = pc[1].arg;
                const val = pc[2].arg;
                framePtr[pc[3].arg] = Value.initTag(tagId, val);
                pc += 4;
                continue;
            },
            .tagLiteral => {
                const symId = pc[1].arg;
                framePtr[pc[2].arg] = Value.initTagLiteral(symId);
                pc += 3;
                continue;
            },
            .tryValue => {
                const val = framePtr[pc[1].arg];
                if (!val.isError()) {
                    framePtr[pc[2].arg] = val;
                    pc += 5;
                    continue;
                } else {
                    if (framePtr != vm.stack.ptr) {
                        framePtr[0] = val;
                        pc += @ptrCast(*const align(1) u16, pc + 3).*;
                    } else {
                        // Panic on root block.
                        vm.panicType = .err;
                        vm.panicPayload = val.val;
                        return error.Panic;
                    }
                }
            },
            .bitwiseAnd => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = @call(.never_inline, evalBitwiseAnd, .{left, right});
                pc += 4;
                continue;
            },
            .bitwiseOr => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = @call(.never_inline, evalBitwiseOr, .{left, right});
                pc += 4;
                continue;
            },
            .bitwiseXor => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = @call(.never_inline, evalBitwiseXor, .{left, right});
                pc += 4;
                continue;
            },
            .bitwiseNot => {
                const val = framePtr[pc[1].arg];
                framePtr[pc[2].arg] = @call(.never_inline, evalBitwiseNot, .{val});
                pc += 3;
                continue;
            },
            .bitwiseLeftShift => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = @call(.never_inline, evalBitwiseLeftShift, .{left, right});
                pc += 4;
                continue;
            },
            .bitwiseRightShift => {
                const left = framePtr[pc[1].arg];
                const right = framePtr[pc[2].arg];
                framePtr[pc[3].arg] = @call(.never_inline, evalBitwiseRightShift, .{left, right});
                pc += 4;
                continue;
            },
            .setCapValToFuncSyms => {
                const capVal = framePtr[pc[1].arg];
                const numSyms = pc[2].arg;
                const syms = pc[3..3+numSyms*2];
                @call(.never_inline, setCapValToFuncSyms, .{ vm, capVal, numSyms, syms });
                pc += 3 + numSyms*2;
                continue;
            },
            .callObjSym => {
                const startLocal = pc[1].arg;
                const numArgs = pc[2].arg;
                const numRet = pc[3].arg;
                const symId = pc[4].arg;

                const recv = &framePtr[startLocal + numArgs + 4 - 1];
                var obj: *HeapObject = undefined;
                var typeId: u32 = undefined;
                if (recv.isPointer()) {
                    obj = recv.asHeapObject(*HeapObject);
                    typeId = obj.common.structId;
                } else {
                    obj = @ptrCast(*HeapObject, recv);
                    typeId = recv.getPrimitiveTypeId();
                }

                if (vm.getCallObjSym(typeId, symId)) |sym| {
                    const res = try @call(.never_inline, vm.callSymEntry, .{pc, framePtr, sym, obj, typeId, startLocal, numArgs, numRet });
                    pc = res.pc;
                    framePtr = res.framePtr;
                } else {
                    const res = try @call(.never_inline, callObjSymFallback, .{vm, pc, framePtr, obj, typeId, symId, startLocal, numArgs, numRet});
                    pc = res.pc;
                    framePtr = res.framePtr;
                }
                continue;
            },
            .callSym => {
                const startLocal = pc[1].arg;
                const numArgs = pc[2].arg;
                const numRet = pc[3].arg;
                const symId = pc[4].arg;
                const res = try @call(.never_inline, vm.callSym, .{pc, framePtr, symId, startLocal, numArgs, @intCast(u2, numRet)});
                pc = res.pc;
                framePtr = res.framePtr;
                continue;
            },
            .match => {
                const expr = framePtr[pc[1].arg];
                const numCases = pc[2].arg;
                var i: u32 = 0;
                while (i < numCases) : (i += 1) {
                    const right = framePtr[pc[3 + i * 3].arg];
                    // Can immediately match numbers, objects, primitives.
                    const cond = if (expr.val == right.val) true else 
                        @call(.never_inline, evalCompareBool, .{vm, expr, right});
                    if (cond) {
                        // Jump.
                        pc += @ptrCast(*align (1) u16, pc + 4 + i * 3).*;
                        break;
                    }
                }
                // else case
                if (i == numCases) {
                    pc += @ptrCast(*align (1) u16, pc + 4 + i * 3 - 1).*;
                }
                continue;
            },
            .end => {
                vm.endLocal = pc[1].arg;
                pc += 2;
                vm.curFiber.pc = @intCast(u32, pcOffset(pc));
                return error.End;
            },
        }
    }
}

fn popStackFrameLocal0(pc: *[*]const cy.OpData, framePtr: *[*]Value) linksection(cy.HotSection) bool {
    const retFlag = framePtr.*[1].retInfo.retFlag;
    const reqNumArgs = framePtr.*[1].retInfo.numRetVals;
    if (reqNumArgs == 0) {
        pc.* = framePtr.*[2].retPcPtr;
        framePtr.* = framePtr.*[3].retFramePtr;
        // return retFlag == 0;
        return !retFlag;
    } else {
        switch (reqNumArgs) {
            0 => unreachable,
            1 => {
                framePtr.*[0] = Value.None;
            },
            // 2 => {
            //     framePtr.*[0] = Value.None;
            //     framePtr.*[1] = Value.None;
            // },
            // 3 => {
            //     framePtr.*[0] = Value.None;
            //     framePtr.*[1] = Value.None;
            //     framePtr.*[2] = Value.None;
            // },
            else => unreachable,
        }
        pc.* = framePtr.*[2].retPcPtr;
        framePtr.* = framePtr.*[3].retFramePtr;
        // return retFlag == 0;
        return !retFlag;
    }
}

fn popStackFrameLocal1(vm: *VM, pc: *[*]const cy.OpData, framePtr: *[*]Value) linksection(cy.HotSection) bool {
    const retFlag = framePtr.*[1].retInfo.retFlag;
    const reqNumArgs = framePtr.*[1].retInfo.numRetVals;
    if (reqNumArgs == 1) {
        pc.* = framePtr.*[2].retPcPtr;
        framePtr.* = framePtr.*[3].retFramePtr;
        // return retFlag == 0;
        return !retFlag;
    } else {
        switch (reqNumArgs) {
            0 => {
                release(vm, framePtr.*[0]);
            },
            1 => unreachable,
            // 2 => {
            //     framePtr.*[1] = Value.None;
            // },
            // 3 => {
            //     framePtr.*[1] = Value.None;
            //     framePtr.*[2] = Value.None;
            // },
            else => unreachable,
        }
        pc.* = framePtr.*[2].retPcPtr;
        framePtr.* = framePtr.*[3].retFramePtr;
        // return retFlag == 0;
        return !retFlag;
    }
}

fn dumpEvalOp(vm: *const VM, pc: [*]const cy.OpData) void {
    const offset = pcOffset(pc);
    switch (pc[0].code) {
        .callObjSym => {
            log.debug("{} op: {s} {any}", .{offset, @tagName(pc[0].code), std.mem.sliceAsBytes(pc[1..14])});
        },
        .callSym => {
            log.debug("{} op: {s} {any}", .{offset, @tagName(pc[0].code), std.mem.sliceAsBytes(pc[1..11])});
        },
        .release => {
            const local = pc[1].arg;
            log.debug("{} op: {s} {}", .{offset, @tagName(pc[0].code), local});
        },
        .copy => {
            const local = pc[1].arg;
            const dst = pc[2].arg;
            log.debug("{} op: {s} {} {}", .{offset, @tagName(pc[0].code), local, dst});
        },
        .copyRetainSrc => {
            const src = pc[1].arg;
            const dst = pc[2].arg;
            log.debug("{} op: {s} {} {}", .{offset, @tagName(pc[0].code), src, dst});
        },
        .map => {
            const startLocal = pc[1].arg;
            const numEntries = pc[2].arg;
            const startConst = pc[3].arg;
            log.debug("{} op: {s} {} {} {}", .{offset, @tagName(pc[0].code), startLocal, numEntries, startConst});
        },
        .constI8 => {
            const val = pc[1].arg;
            const dst = pc[2].arg;
            log.debug("{} op: {s} [{}] -> %{}", .{offset, @tagName(pc[0].code), @bitCast(i8, val), dst});
        },
        .add => {
            const left = pc[1].arg;
            const right = pc[2].arg;
            const dst = pc[3].arg;
            log.debug("{} op: {s} {} {} -> %{}", .{offset, @tagName(pc[0].code), left, right, dst});
        },
        .constOp => {
            const idx = pc[1].arg;
            const dst = pc[2].arg;
            const val = Value{ .val = vm.consts[idx].val };
            log.debug("{} op: {s} [{s}] -> %{}", .{offset, @tagName(pc[0].code), vm.valueToTempString(val), dst});
        },
        .end => {
            const endLocal = pc[1].arg;
            log.debug("{} op: {s} {}", .{offset, @tagName(pc[0].code), endLocal});
        },
        .setInitN => {
            const numLocals = pc[1].arg;
            const locals = pc[2..2+numLocals];
            log.debug("{} op: {s} {}", .{offset, @tagName(pc[0].code), numLocals});
            for (locals) |local| {
                log.debug("{}", .{local.arg});
            }
        },
        else => {
            const len = cy.getInstLenAt(pc);
            log.debug("{} op: {s} {any}", .{offset, @tagName(pc[0].code), std.mem.sliceAsBytes(pc[1..len])});
        },
    }
}

pub const EvalError = error{
    Panic,
    ParseError,
    CompileError,
    OutOfMemory,
    NoEndOp,
    End,
    OutOfBounds,
    StackOverflow,
    NoDebugSym,
};

pub const StackTrace = struct {
    frames: []const StackFrame = &.{},

    fn deinit(self: *StackTrace, alloc: std.mem.Allocator) void {
        alloc.free(self.frames);
    }

    pub fn dump(self: *const StackTrace, vm: *const VM) !void {
        @setCold(true);
        var arrowBuf: std.ArrayListUnmanaged(u8) = .{};
        var w = arrowBuf.writer(vm.alloc);
        defer arrowBuf.deinit(vm.alloc);

        for (self.frames) |frame| {
            const lineEnd = std.mem.indexOfScalarPos(u8, vm.compiler.src, frame.lineStartPos, '\n') orelse vm.compiler.src.len;
            arrowBuf.clearRetainingCapacity();
            try w.writeByteNTimes(' ', frame.col);
            try w.writeByte('^');
            fmt.printStderr(
                \\{}:{}:{} {}:
                \\{}
                \\{}
                \\
            , &.{
                fmt.v(frame.uri), fmt.v(frame.line+1), fmt.v(frame.col+1), fmt.v(frame.name),
                fmt.v(vm.compiler.src[frame.lineStartPos..lineEnd]), fmt.v(arrowBuf.items),
            });
        }
    }
};

pub const StackFrame = struct {
    /// Name identifier (eg. function name)
    name: []const u8,
    /// Source location.
    uri: []const u8,
    /// Starts at 0.
    line: u32,
    /// Starts at 0.
    col: u32,
    /// Where the line starts in the source file.
    lineStartPos: u32,
};

const ObjectSymKey = struct {
    structId: StructId,
    symId: SymbolId,
};

/// See `reserveFuncParams` for stack layout.
/// numArgs does not include the callee.
pub fn call(vm: *VM, pc: *[*]cy.OpData, framePtr: *[*]Value, callee: Value, startLocal: u8, numArgs: u8, retInfo: Value) !void {
    if (callee.isPointer()) {
        const obj = stdx.ptrAlignCast(*HeapObject, callee.asPointer().?);
        switch (obj.common.structId) {
            ClosureS => {
                if (numArgs != obj.closure.numParams) {
                    log.debug("params/args mismatch {} {}", .{numArgs, obj.lambda.numParams});
                    // Release func and args.
                    for (framePtr.*[startLocal + 4..startLocal + 4 + numArgs]) |val| {
                        release(vm, val);
                    }
                    framePtr.*[startLocal] = Value.initErrorTagLit(@enumToInt(bindings.TagLit.InvalidSignature));
                    return;
                }

                if (@ptrToInt(framePtr.* + startLocal + obj.closure.numLocals) >= @ptrToInt(vm.stackEndPtr)) {
                    return error.StackOverflow;
                }

                const retFramePtr = Value{ .retFramePtr = framePtr.* };
                framePtr.* += startLocal;
                framePtr.*[1] = retInfo;
                framePtr.*[2] = Value{ .retPcPtr = pc.* };
                framePtr.*[3] = retFramePtr;
                pc.* = toPc(obj.closure.funcPc);

                // Copy over captured vars to new call stack locals.
                const src = obj.closure.getCapturedValuesPtr()[0..obj.closure.numCaptured];
                std.mem.copy(Value, framePtr.*[numArgs + 4 + 1..numArgs + 4 + 1 + obj.closure.numCaptured], src);
            },
            LambdaS => {
                if (numArgs != obj.lambda.numParams) {
                    log.debug("params/args mismatch {} {}", .{numArgs, obj.lambda.numParams});
                    // Release func and args.
                    for (framePtr.*[startLocal + 4..startLocal + 4 + numArgs]) |val| {
                        release(vm, val);
                    }
                    framePtr.*[startLocal] = Value.initErrorTagLit(@enumToInt(bindings.TagLit.InvalidSignature));
                    return;
                }

                if (@ptrToInt(framePtr.* + startLocal + obj.lambda.numLocals) >= @ptrToInt(vm.stackEndPtr)) {
                    return error.StackOverflow;
                }

                const retFramePtr = Value{ .retFramePtr = framePtr.* };
                framePtr.* += startLocal;
                framePtr.*[1] = retInfo;
                framePtr.*[2] = Value{ .retPcPtr = pc.* };
                framePtr.*[3] = retFramePtr;
                pc.* = toPc(obj.lambda.funcPc);
            },
            NativeFunc1S => {
                if (numArgs != obj.nativeFunc1.numParams) {
                    log.debug("params/args mismatch {} {}", .{numArgs, obj.lambda.numParams});
                    for (framePtr.*[startLocal + 4..startLocal + 4 + numArgs]) |val| {
                        release(vm, val);
                    }
                    framePtr.*[startLocal] = Value.initErrorTagLit(@enumToInt(bindings.TagLit.InvalidSignature));
                    return;
                }

                vm.pc = pc.*;
                const newFramePtr = framePtr.* + startLocal;
                vm.framePtr = newFramePtr;
                const res = obj.nativeFunc1.func(@ptrCast(*UserVM, vm), newFramePtr + 4, numArgs);
                newFramePtr[0] = res;
            },
            else => {},
        }
    } else {
        stdx.panic("not a function");
    }
}

pub fn callNoInline(vm: *VM, pc: *[*]cy.OpData, framePtr: *[*]Value, callee: Value, startLocal: u8, numArgs: u8, retInfo: Value) !void {
    if (callee.isPointer()) {
        const obj = stdx.ptrAlignCast(*HeapObject, callee.asPointer().?);
        switch (obj.common.structId) {
            ClosureS => {
                if (numArgs != obj.closure.numParams) {
                    stdx.panic("params/args mismatch");
                }

                if (@ptrToInt(framePtr.* + startLocal + obj.closure.numLocals) >= @ptrToInt(vm.stack.ptr) + (vm.stack.len << 3)) {
                    return error.StackOverflow;
                }

                pc.* = toPc(obj.closure.funcPc);
                framePtr.* += startLocal;
                framePtr.*[1] = retInfo;

                // Copy over captured vars to new call stack locals.
                const src = obj.closure.getCapturedValuesPtr()[0..obj.closure.numCaptured];
                std.mem.copy(Value, framePtr.*[numArgs + 4 + 1..numArgs + 4 + 1 + obj.closure.numCaptured], src);
            },
            LambdaS => {
                if (numArgs != obj.lambda.numParams) {
                    log.debug("params/args mismatch {} {}", .{numArgs, obj.lambda.numParams});
                    stdx.fatal();
                }

                if (@ptrToInt(framePtr.* + startLocal + obj.lambda.numLocals) >= @ptrToInt(vm.stack.ptr) + (vm.stack.len << 3)) {
                    return error.StackOverflow;
                }

                const retFramePtr = Value{ .retFramePtr = framePtr.* };
                framePtr.* += startLocal;
                framePtr.*[1] = retInfo;
                framePtr.*[2] = Value{ .retPcPtr = pc.* + 14 };
                framePtr.*[3] = retFramePtr;
                pc.* = toPc(obj.lambda.funcPc);
            },
            NativeFunc1S => {
                vm.pc = pc.*;
                const newFramePtr = framePtr.* + startLocal;
                vm.framePtr = newFramePtr;
                const res = obj.nativeFunc1.func(@ptrCast(*UserVM, vm), newFramePtr + 4, numArgs);
                newFramePtr[0] = res;
                releaseObject(vm, obj);
                pc.* += 14;
            },
            else => {},
        }
    } else {
        stdx.panic("not a function");
    }
}

fn getObjectFunctionFallback(vm: *VM, obj: *const HeapObject, typeId: u32, symId: SymbolId) !Value {
    @setCold(true);
    _ = obj;
    // Map fallback is no longer supported since cleanup of recv is not auto generated by the compiler.
    // In the future, this may invoke the exact method signature or call a custom overloaded function.
    // if (typeId == MapS) {
    //     const name = vm.methodSymExtras.buf[symId];
    //     const heapMap = stdx.ptrAlignCast(*const MapInner, &obj.map.inner);
    //     if (heapMap.getByString(vm, name)) |val| {
    //         return val;
    //     }
    // }

    return vm.panicFmt("Missing method symbol `{}` from receiver of type `{}`.", &.{
        v(vm.methodSymExtras.buf[symId]), v(vm.structs.buf[typeId].name),
    });
}

/// Use new pc local to avoid deoptimization.
fn callObjSymFallback(vm: *VM, pc: [*]cy.OpData, framePtr: [*]Value, obj: *HeapObject, typeId: u32, symId: SymbolId, startLocal: u8, numArgs: u8, reqNumRetVals: u8) linksection(cy.Section) !PcFramePtr {
    @setCold(true);
    // const func = try @call(.never_inline, getObjectFunctionFallback, .{obj, symId});
    const func = try getObjectFunctionFallback(vm, obj, typeId, symId);

    vm.retain(func);
    releaseObject(vm, obj);

    // Replace receiver with function.
    framePtr[startLocal + 4 + numArgs - 1] = func;
    // const retInfo = buildReturnInfo(pc, framePtrOffset(framePtr), reqNumRetVals, true);
    const retInfo = buildReturnInfo2(reqNumRetVals, true);
    var newPc = pc;
    var newFramePtr = framePtr;
    try @call(.always_inline, callNoInline, .{vm, &newPc, &newFramePtr, func, startLocal, numArgs-1, retInfo});
    return PcFramePtr{
        .pc = newPc,
        .framePtr = newFramePtr,
    };
}

fn callSymEntryNoInline(pc: [*]const cy.OpData, framePtr: [*]Value, sym: MethodSym, obj: *HeapObject, startLocal: u8, numArgs: u8, comptime reqNumRetVals: u2) linksection(cy.HotSection) !PcFramePtr {
    switch (sym.entryT) {
        .func => {
            if (@ptrToInt(framePtr + startLocal + sym.inner.func.numLocals) >= @ptrToInt(gvm.stack.ptr) + 8 * gvm.stack.len) {
                return error.StackOverflow;
            }

            // const retInfo = buildReturnInfo(pc, framePtrOffset(framePtr), reqNumRetVals, true);
            const retInfo = buildReturnInfo(reqNumRetVals, true);
            const newFramePtr = framePtr + startLocal;
            newFramePtr[1] = retInfo;
            return PcFramePtr{
                .pc = toPc(sym.inner.func.pc),
                .framePtr = newFramePtr,
            };
        },
        .nativeFunc1 => {
            // gvm.pc += 3;
            const newFramePtr = framePtr + startLocal;
            gvm.pc = pc;
            gvm.framePtr = framePtr;
            const res = sym.inner.nativeFunc1(@ptrCast(*UserVM, &gvm), obj, newFramePtr+4, numArgs);
            if (reqNumRetVals == 1) {
                newFramePtr[0] = res;
            } else {
                switch (reqNumRetVals) {
                    0 => {
                        // Nop.
                    },
                    1 => stdx.panic("not possible"),
                    2 => {
                        stdx.panic("unsupported require 2 ret vals");
                    },
                    3 => {
                        stdx.panic("unsupported require 3 ret vals");
                    },
                }
            }
            return PcFramePtr{
                .pc = gvm.pc,
                .framePtr = framePtr,
            };
        },
        .nativeFunc2 => {
            // gvm.pc += 3;
            const newFramePtr = gvm.framePtr + startLocal;
            gvm.pc = pc;
            const res = sym.inner.nativeFunc2(@ptrCast(*UserVM, &gvm), obj, @ptrCast([*]const Value, newFramePtr+4), numArgs);
            if (reqNumRetVals == 2) {
                gvm.stack[newFramePtr] = res.left;
                gvm.stack[newFramePtr+1] = res.right;
            } else {
                switch (reqNumRetVals) {
                    0 => {
                        // Nop.
                    },
                    1 => unreachable,
                    2 => {
                        unreachable;
                    },
                    3 => {
                        unreachable;
                    },
                }
            }
        },
        // else => {
        //     // stdx.panicFmt("unsupported {}", .{sym.entryT});
        //     unreachable;
        // },
    }
    return pc;
}

fn popFiber(vm: *VM, curFiberEndPc: usize, curFramePtr: [*]Value, retValue: Value) PcFramePtr {
    vm.curFiber.stackPtr = vm.stack.ptr;
    vm.curFiber.stackLen = @intCast(u32, vm.stack.len);
    vm.curFiber.pc = @intCast(u32, curFiberEndPc);
    vm.curFiber.setFramePtr(curFramePtr);
    const dstLocal = vm.curFiber.getParentDstLocal();

    // Release current fiber.
    const nextFiber = vm.curFiber.prevFiber.?;
    releaseObject(vm, @ptrCast(*HeapObject, vm.curFiber));

    // Set to next fiber.
    vm.curFiber = nextFiber;

    // Copy return value to parent local.
    if (dstLocal != NullByteId) {
        vm.curFiber.getFramePtr()[dstLocal] = retValue;
    } else {
        release(vm, retValue);
    }

    vm.stack = vm.curFiber.stackPtr[0..vm.curFiber.stackLen];
    vm.stackEndPtr = vm.stack.ptr + vm.curFiber.stackLen;
    log.debug("fiber set to {} {*}", .{vm.curFiber.pc, vm.framePtr});
    return PcFramePtr{
        .pc = toPc(vm.curFiber.pc),
        .framePtr = vm.curFiber.getFramePtr(),
    };
}

/// Since this is called from a coresume expression, the fiber should already be retained.
fn pushFiber(vm: *VM, curFiberEndPc: usize, curFramePtr: [*]Value, fiber: *Fiber, parentDstLocal: u8) PcFramePtr {
    // Save current fiber.
    vm.curFiber.stackPtr = vm.stack.ptr;
    vm.curFiber.stackLen = @intCast(u32, vm.stack.len);
    vm.curFiber.pc = @intCast(u32, curFiberEndPc);
    vm.curFiber.setFramePtr(curFramePtr);

    // Push new fiber.
    fiber.prevFiber = vm.curFiber;
    fiber.setParentDstLocal(parentDstLocal);
    vm.curFiber = fiber;
    vm.stack = fiber.stackPtr[0..fiber.stackLen];
    vm.stackEndPtr = vm.stack.ptr + fiber.stackLen;
    // Check if fiber was previously yielded.
    if (vm.ops[fiber.pc].code == .coyield) {
        log.debug("fiber set to {} {*}", .{fiber.pc + 3, vm.framePtr});
        return .{
            .pc = toPc(fiber.pc + 3),
            .framePtr = fiber.getFramePtr(),
        };
    } else {
        log.debug("fiber set to {} {*}", .{fiber.pc, vm.framePtr});
        return .{
            .pc = toPc(fiber.pc),
            .framePtr = fiber.getFramePtr(),
        };
    }
}

fn allocFiber(pc: usize, args: []const Value, initialStackSize: u32) linksection(cy.HotSection) !Value {
    // Args are copied over to the new stack.
    var stack = try gvm.alloc.alloc(Value, initialStackSize);
    // Assumes initial stack size generated by compiler is enough to hold captured args.
    // Assumes call start local is at 1.
    std.mem.copy(Value, stack[5..5+args.len], args);

    const obj = try gvm.allocPoolObject();
    const parentDstLocal = NullByteId;
    obj.fiber = .{
        .structId = FiberS,
        .rc = 1,
        .stackPtr = stack.ptr,
        .stackLen = @intCast(u32, stack.len),
        .pc = @intCast(u32, pc),
        .extra = @as(u64, @ptrToInt(stack.ptr)) | (parentDstLocal << 48),
        .prevFiber = undefined,
    };
    if (TraceEnabled) {
        gvm.trace.numRetainAttempts += 1;
        gvm.trace.numRetains += 1;
    }
    if (TrackGlobalRC) {
        gvm.refCounts += 1;
    }

    return Value.initPtr(obj);
}

fn runReleaseOps(vm: *VM, stack: []const Value, framePtr: usize, startPc: usize) void {
    var pc = startPc;
    while (vm.ops[pc].code == .release) {
        const local = vm.ops[pc+1].arg;
        // stack[framePtr + local].dump();
        release(vm, stack[framePtr + local]);
        pc += 2;
    }
}

/// Unwinds the stack and releases the locals.
/// This also releases the initial captured vars since it's on the stack.
fn releaseFiberStack(vm: *VM, fiber: *Fiber) void {
    log.debug("release fiber stack", .{});
    var stack = fiber.stackPtr[0..fiber.stackLen];
    var framePtr = (@ptrToInt(fiber.getFramePtr()) - @ptrToInt(stack.ptr)) >> 3;
    var pc = fiber.pc;

    if (pc != NullId) {

        // Check if fiber is still in init state.
        switch (vm.ops[pc].code) {
            .callFuncIC,
            .callSym => {
                if (vm.ops[pc + 11].code == .coreturn) {
                    const numArgs = vm.ops[pc - 4].arg;
                    for (fiber.getFramePtr()[5..5 + numArgs]) |arg| {
                        release(vm, arg);
                    }
                }
            },
            else => {},
        }

        // Check if fiber was previously on a yield op.
        if (vm.ops[pc].code == .coyield) {
            const jump = @ptrCast(*const align(1) u16, &vm.ops[pc+1]).*;
            log.debug("release on frame {} {} {}", .{framePtr, pc, pc + jump});
            // The yield statement already contains the end locals pc.
            runReleaseOps(vm, stack, framePtr, pc + jump);
        }
        // Unwind stack and release all locals.
        while (framePtr > 0) {
            pc = pcOffset(stack[framePtr + 2].retPcPtr);
            framePtr = (@ptrToInt(stack[framePtr + 3].retFramePtr) - @ptrToInt(stack.ptr)) >> 3;
            const endLocalsPc = pcToEndLocalsPc(vm, pc);
            log.debug("release on frame {} {} {}", .{framePtr, pc, endLocalsPc});
            if (endLocalsPc != NullId) {
                runReleaseOps(vm, stack, framePtr, endLocalsPc);
            }
        }
    }
    // Finally free stack.
    vm.alloc.free(stack);
}

/// Given pc position, return the end locals pc in the same frame.
/// TODO: Memoize this function.
fn pcToEndLocalsPc(vm: *const VM, pc: usize) u32 {
    const idx = debug.indexOfDebugSym(vm, pc) orelse {
        stdx.panic("Missing debug symbol.");
    };
    const sym = vm.debugTable[idx];
    if (sym.frameLoc != NullId) {
        const node = vm.compiler.nodes[sym.frameLoc];
        return node.head.func.genEndLocalsPc;
    } else return NullId;
}

pub inline fn buildReturnInfo2(numRetVals: u8, comptime cont: bool) linksection(cy.HotSection) Value {
    return Value{
        .retInfo = .{
            .numRetVals = numRetVals,
            // .retFlag = if (cont) 0 else 1,
            .retFlag = !cont,
        },
    };
}

pub inline fn buildReturnInfo(comptime numRetVals: u2, comptime cont: bool) linksection(cy.HotSection) Value {
    return Value{
        .retInfo = .{
            .numRetVals = numRetVals,
            // .retFlag = if (cont) 0 else 1,
            .retFlag = !cont,
        },
    };
}

pub inline fn pcOffset(pc: [*]const cy.OpData) u32 {
    return @intCast(u32, @ptrToInt(pc) - @ptrToInt(gvm.ops.ptr));
}

pub inline fn toPc(offset: usize) [*]cy.OpData {
    return @ptrCast([*]cy.OpData, &gvm.ops.ptr[offset]);
}

inline fn framePtrOffsetFrom(stackPtr: [*]const Value, framePtr: [*]const Value) usize {
    // Divide by eight.
    return (@ptrToInt(framePtr) - @ptrToInt(stackPtr)) >> 3;
}

pub inline fn framePtrOffset(framePtr: [*]const Value) usize {
    // Divide by eight.
    return (@ptrToInt(framePtr) - @ptrToInt(gvm.stack.ptr)) >> 3;
}

pub inline fn toFramePtr(offset: usize) [*]Value {
    return @ptrCast([*]Value, &gvm.stack[offset]);
}

const PcFramePtr = struct {
    pc: [*]cy.OpData,
    framePtr: [*]Value,
};

fn boxValueRetain(box: Value) linksection(cy.HotSection) Value {
    @setCold(true);
    if (box.isPointer()) {
        const obj = stdx.ptrAlignCast(*HeapObject, box.asPointer().?);
        if (builtin.mode == .Debug) {
            std.debug.assert(obj.common.structId == BoxS);
        }
        gvm.retain(obj.box.val);
        return obj.box.val;
    } else {
        // Box can be none if used before captured var was initialized.
        if (builtin.mode == .Debug) {
            std.debug.assert(box.isNone());
        }
        return Value.None;
    }
}

fn allocBox(vm: *VM, val: Value) !Value {
    const obj = try vm.allocPoolObject();
    obj.box = .{
        .structId = BoxS,
        .rc = 1,
        .val = val,
    };
    if (TraceEnabled) {
        vm.trace.numRetainAttempts += 1;
        vm.trace.numRetains += 1;
    }
    if (TrackGlobalRC) {
        vm.refCounts += 1;
    }
    return Value.initPtr(obj);
}

fn setCapValToFuncSyms(vm: *VM, capVal: Value, numSyms: u8, syms: []const cy.OpData) void {
    @setCold(true);
    var i: u32 = 0;
    while (i < numSyms) : (i += 1) {
        const capVarIdx = syms[i * 2 + 1].arg;
        const sym = vm.funcSyms.buf[syms[i*2].arg];
        const ptr = sym.inner.closure.getCapturedValuesPtr();
        ptr[capVarIdx] = capVal;
    }
    vm.retainInc(capVal, numSyms);
}

// Performs stackGrowTotalCapacityPrecise in addition to patching the frame pointers.
fn growStackAuto(vm: *VM) !void {
    @setCold(true);
    // Grow by 50% with minimum of 16.
    var growSize = vm.stack.len / 2;
    if (growSize < 16) {
        growSize = 16;
    }
    try growStackPrecise(vm, vm.stack.len + growSize);
}

fn ensureTotalStackCapacity(vm: *VM, newCap: usize) !void {
    if (newCap > vm.stack.len) {
        var betterCap = vm.stack.len;
        while (true) {
            betterCap +|= betterCap / 2 + 8;
            if (betterCap >= newCap) {
                break;
            }
        }
        try growStackPrecise(vm, betterCap);
    }
}

fn growStackPrecise(vm: *VM, newCap: usize) !void {
    if (vm.alloc.resize(vm.stack, newCap)) {
        vm.stack.len = newCap;
        vm.stackEndPtr = vm.stack.ptr + newCap;
    } else {
        const newStack = try vm.alloc.alloc(Value, newCap);

        // Copy to new stack.
        std.mem.copy(Value, newStack[0..vm.stack.len], vm.stack);

        // Patch frame ptrs. 
        var curFpOffset = framePtrOffsetFrom(vm.stack.ptr, vm.framePtr);
        while (curFpOffset != 0) {
            const prevFpOffset = framePtrOffsetFrom(vm.stack.ptr, newStack[curFpOffset + 3].retFramePtr);
            newStack[curFpOffset + 3].retFramePtr = newStack.ptr + prevFpOffset;
            curFpOffset = prevFpOffset;
        }

        // Free old stack.
        vm.alloc.free(vm.stack);

        // Update to new frame ptr.
        vm.framePtr = newStack.ptr + framePtrOffsetFrom(vm.stack.ptr, vm.framePtr);
        vm.stack = newStack;
        vm.stackEndPtr = vm.stack.ptr + newCap;
    }
}

/// Like Value.dump but shows heap values.
pub fn dumpValue(vm: *const VM, val: Value) void {
    if (val.isNumber()) {
        fmt.printStdout("Number {}\n", &.{ v(val.asF64()) });
    } else {
        if (val.isPointer()) {
            const obj = stdx.ptrAlignCast(*cy.HeapObject, val.asPointer().?);
            switch (obj.common.structId) {
                cy.ListS => fmt.printStdout("List {} len={}\n", &.{v(obj), v(obj.list.list.len)}),
                cy.MapS => fmt.printStdout("Map {} size={}\n", &.{v(obj), v(obj.map.inner.size)}),
                cy.AstringT => {
                    const str = obj.astring.getConstSlice();
                    if (str.len > 20) {
                        fmt.printStdout("String {} len={} str=\"{}\"...\n", &.{v(obj), v(str.len), v(str[0..20])});
                    } else {
                        fmt.printStdout("String {} len={} str=\"{}\"\n", &.{v(obj), v(str.len), v(str)});
                    }
                },
                cy.UstringT => {
                    const str = obj.ustring.getConstSlice();
                    if (str.len > 20) {
                        fmt.printStdout("String {} len={} str=\"{}\"...\n", &.{v(obj), v(str.len), v(str[0..20])});
                    } else {
                        fmt.printStdout("String {} len={} str=\"{}\"\n", &.{v(obj), v(str.len), v(str)});
                    }
                },
                cy.LambdaS => fmt.printStdout("Lambda {}\n", &.{v(obj)}),
                cy.ClosureS => fmt.printStdout("Closure {}\n", &.{v(obj)}),
                cy.FiberS => fmt.printStdout("Fiber {}\n", &.{v(obj)}),
                cy.NativeFunc1S => fmt.printStdout("NativeFunc {}\n", &.{v(obj)}),
                else => {
                    fmt.printStdout("HeapObject {} {} {}\n", &.{v(obj), v(obj.common.structId), v(vm.structs.buf[obj.common.structId].name)});
                },
            }
        } else {
            switch (val.getTag()) {
                cy.NoneT => {
                    fmt.printStdout("None\n", &.{});
                },
                cy.StaticUstringT,
                cy.StaticAstringT => {
                    const slice = val.asStaticStringSlice();
                    if (slice.len() > 20) {
                        fmt.printStdout("Const String len={} str=\"{s}\"...\n", &.{v(slice.len()), v(vm.strBuf[slice.start..20])});
                    } else {
                        fmt.printStdout("Const String len={} str=\"{}\"\n", &.{v(slice.len()), v(vm.strBuf[slice.start..slice.end])});
                    }
                },
                else => {
                    fmt.printStdout("{}\n", &.{v(val.val)});
                },
            }
        }
    }
}

pub fn shallowCopy(vm: *cy.VM, val: Value) linksection(StdSection) Value {
    if (val.isPointer()) {
        const obj = val.asHeapObject(*cy.HeapObject);
        switch (obj.common.structId) {
            cy.ListS => {
                const list = stdx.ptrAlignCast(*cy.List(Value), &obj.list.list);
                const new = vm.allocList(list.items()) catch stdx.fatal();
                for (list.items()) |item| {
                    vm.retain(item);
                }
                return new;
            },
            cy.MapS => {
                const new = vm.allocEmptyMap() catch stdx.fatal();
                const newMap = stdx.ptrAlignCast(*cy.MapInner, &(new.asHeapObject(*cy.HeapObject)).map.inner);

                const map = stdx.ptrAlignCast(*cy.MapInner, &obj.map.inner);
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    vm.retain(entry.key);
                    vm.retain(entry.value);
                    newMap.put(vm.alloc, @ptrCast(*const cy.VM, vm), entry.key, entry.value) catch stdx.fatal();
                }
                return new;
            },
            cy.ClosureS => {
                fmt.panic("Unsupported copy closure.", &.{});
            },
            cy.LambdaS => {
                fmt.panic("Unsupported copy closure.", &.{});
            },
            cy.AstringT => {
                vm.retainObject(obj);
                return val;
            },
            cy.UstringT => {
                vm.retainObject(obj);
                return val;
            },
            cy.RawStringT => {
                vm.retainObject(obj);
                return val;
            },
            cy.FiberS => {
                fmt.panic("Unsupported copy fiber.", &.{});
            },
            cy.BoxS => {
                fmt.panic("Unsupported copy box.", &.{});
            },
            cy.NativeFunc1S => {
                fmt.panic("Unsupported copy native func.", &.{});
            },
            cy.TccStateS => {
                fmt.panic("Unsupported copy tcc state.", &.{});
            },
            cy.OpaquePtrS => {
                fmt.panic("Unsupported copy opaque ptr.", &.{});
            },
            else => {
                const numFields = @ptrCast(*const cy.VM, vm).structs.buf[obj.common.structId].numFields;
                const fields = obj.object.getValuesConstPtr()[0..numFields];
                var new: Value = undefined;
                if (numFields <= 4) {
                    new = vm.allocObjectSmall(obj.common.structId, fields) catch stdx.fatal();
                } else {
                    new = vm.allocObject(obj.common.structId, fields) catch stdx.fatal();
                }
                for (fields) |field| {
                    vm.retain(field);
                }
                return new;
            },
        }
    } else {
        return val;
    }
}

const RelFuncSigKey = KeyU64;

pub const KeyU96 = extern union {
    val: extern struct {
        a: u64,
        b: u32,
    },
    absLocalSymKey: extern struct {
        localParentSymId: u32,
        nameId: u32,
        numParams: u32,
    },
    rtFuncSymKey: extern struct {
        // TODO: Is it enough to just use the final resolved func sym id?
        resolvedParentSymId: u32,
        nameId: u32,
        numParams: u32,
    },
};

pub const KeyU96Context = struct {
    pub fn hash(_: @This(), key: KeyU96) u64 {
        var hasher = std.hash.Wyhash.init(0);
        @call(.always_inline, hasher.update, .{std.mem.asBytes(&key.val.a)});
        @call(.always_inline, hasher.update, .{std.mem.asBytes(&key.val.b)});
        return hasher.final();
    }
    pub fn eql(_: @This(), a: KeyU96, b: KeyU96) bool {
        return a.val.a == b.val.a and a.val.b == b.val.b;
    }
};

pub const KeyU64 = extern union {
    val: u64,
    absResolvedSymKey: extern struct {
        resolvedParentSymId: u32,
        nameId: u32,
    },
    absResolvedFuncSymKey: extern struct {
        resolvedSymId: sema.ResolvedSymId,
        numParams: u32,
    },
    relModuleSymKey: extern struct {
        nameId: u32,
        numParams: u32,
    },
    rtVarSymKey: extern struct {
        resolvedParentSymId: u32,
        nameId: u32,
    },
    relFuncSigKey: extern struct {
        nameId: u32,
        numParams: u32,
    },
    structKey: extern struct {
        nameId: u32,
        uniqId: u32,
    },
};

pub const KeyU64Context = struct {
    pub fn hash(_: @This(), key: KeyU64) linksection(cy.Section) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&key.val));
    }
    pub fn eql(_: @This(), a: KeyU64, b: KeyU64) linksection(cy.Section) bool {
        return a.val == b.val;
    }
};

/// Absolute func symbol signature key.
pub const AbsFuncSigKey = KeyU96;

/// Absolute var signature key.
const AbsVarSigKey = KeyU64;

const StringConcat = struct {
    left: []const u8,
    right: []const u8,
};

pub const StringConcatContext = struct {
    pub fn hash(_: StringConcatContext, concat: StringConcat) u64 {
        return @call(.always_inline, computeStringConcatHash, .{concat.left, concat.right});
    }

    pub fn eql(_: StringConcatContext, a: StringConcat, b: []const u8) bool {
        if (a.left.len + a.right.len != b.len) {
            return false;
        }
        return std.mem.eql(u8, a.left, b[0..a.left.len]) and 
            std.mem.eql(u8, a.right, b[a.left.len..]);
    }
};

const StringConcat3 = struct {
    str1: []const u8,
    str2: []const u8,
    str3: []const u8,
};

pub const StringConcat3Context = struct {
    pub fn hash(_: StringConcat3Context, concat: StringConcat3) u64 {
        return @call(.always_inline, computeStringConcat3Hash, .{concat.str1, concat.str2, concat.str3});
    }

    pub fn eql(_: StringConcat3Context, a: StringConcat3, b: []const u8) bool {
        if (a.str1.len + a.str2.len + a.str3.len != b.len) {
            return false;
        }
        return std.mem.eql(u8, a.str1, b[0..a.str1.len]) and 
            std.mem.eql(u8, a.str2, b[a.str1.len..a.str1.len+a.str2.len]) and
            std.mem.eql(u8, a.str3, b[a.str1.len+a.str2.len..]);
    }
};

fn computeStringConcat3Hash(str1: []const u8, str2: []const u8, str3: []const u8) u64 {
    var c = std.hash.Wyhash.init(0);
    @call(.always_inline, c.update, .{str1});
    @call(.always_inline, c.update, .{str2});
    @call(.always_inline, c.update, .{str3});
    return @call(.always_inline, c.final, .{});
}

fn computeStringConcatHash(left: []const u8, right: []const u8) u64 {
    var c = std.hash.Wyhash.init(0);
    @call(.always_inline, c.update, .{left});
    @call(.always_inline, c.update, .{right});
    return @call(.always_inline, c.final, .{});
}

test "computeStringConcatHash() matches the concated string hash." {
    const exp = std.hash.Wyhash.hash(0, "foobar");
    try t.eq(computeStringConcatHash("foo", "bar"), exp);
    try t.eq(computeStringConcat3Hash("fo", "ob", "ar"), exp);
}

fn getStaticUstringHeader(vm: *const VM, start: usize) *align(1) cy.StaticUstringHeader {
    return @ptrCast(*align (1) cy.StaticUstringHeader, vm.strBuf.ptr + start - 12);
}

const SliceWriter = struct {
    buf: []u8,
    idx: *u32,

    pub const Error = error{OutOfMemory};

    fn reset(self: *SliceWriter) void {
        self.idx.* = 0;
    }

    inline fn pos(self: *const SliceWriter) u32 {
        return self.idx.*;
    }

    inline fn sliceFrom(self: *const SliceWriter, start: u32) []const u8 {
        return self.buf[start..self.idx.*];
    }

    pub fn write(self: SliceWriter, data: []const u8) linksection(cy.Section) Error!usize {
        if (builtin.mode != .ReleaseFast) {
            if (self.idx.* + data.len > self.buf.len) {
                return Error.OutOfMemory;
            }
        }
        std.mem.copy(u8, self.buf[self.idx.*..self.idx.*+data.len], data);
        self.idx.* += @intCast(u32, data.len);
        return data.len;
    }

    pub fn writeAll(self: SliceWriter, data: []const u8) linksection(cy.Section) Error!void {
        _ = try self.write(data);
    }

    pub fn writeByteNTimes(self: SliceWriter, byte: u8, n: usize) linksection(cy.Section) Error!void {
        if (builtin.mode != .ReleaseFast) {
            if (self.idx.* + n > self.buf.len) {
                return Error.OutOfMemory;
            }
        }
        std.mem.set(u8, self.buf[self.idx.*..self.idx.*+n], byte);
        self.idx.* += @intCast(u32, n);
    }
};

const EvalConfig = struct {
    /// Whether this process intends to perform eval once and exit.
    /// In that scenario, the compiler can skip generating the final release ops for the main block.
    singleRun: bool = false,
};