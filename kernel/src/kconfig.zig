//! Kconfig as data: .config files and fragments, the Kconfig tree (symbols, prompts,
//! dependencies), an evaluator that says which dependency of a symbol is unmet, and the
//! Kbuild rules that tie a module name to its CONFIG symbol. Not a solver: the kernel's own
//! conf (olddefconfig) decides; this reads what it decided and explains why.
const std = @import("std");
const vh = @import("vh");
const mem = std.mem;

// ---------------------------------------------------------------- .config

/// A .config or a fragment: "CONFIG_X=value" and "# CONFIG_X is not set" (value "n"), in
/// file order. Values keep their spelling: y, m, n, "text", 0x10, 12.
pub const DotConfig = struct {
    map: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub const Kv = struct { name: []const u8, value: []const u8 };

    pub fn parse(self: *DotConfig, text: []const u8) void {
        var lines = mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            if (parseLine(vh.strip(raw))) |kv| self.set(kv.name, kv.value);
        }
    }

    /// one line -> (name without CONFIG_, value), or null for anything else
    pub fn parseLine(line: []const u8) ?Kv {
        if (vh.startsWith(line, "CONFIG_")) {
            const eq = mem.indexOfScalar(u8, line, '=') orelse return null;
            if (eq <= 7) return null;
            return .{ .name = line[7..eq], .value = line[eq + 1 ..] };
        }
        if (vh.startsWith(line, "# CONFIG_") and vh.endsWith(line, " is not set") and line.len > 20)
            return .{ .name = line[9 .. line.len - 11], .value = "n" };
        return null;
    }

    pub fn set(self: *DotConfig, name: []const u8, value: []const u8) void {
        self.map.put(vh.gpa, vh.dupe(name), vh.dupe(value)) catch vh.oom();
    }

    /// set and move to the end, as merge_config.sh does: for a choice (PREEMPT, LTO, the
    /// lockdown mode) conf takes the member that is =y last in the file, so a fragment's
    /// pick must come after the base's
    pub fn setLast(self: *DotConfig, name: []const u8, value: []const u8) void {
        _ = self.map.orderedRemove(name);
        self.set(name, value);
    }

    pub fn get(self: *const DotConfig, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    /// y = 2, m = 1, n or absent = 0 (a string or a number is neither)
    pub fn tri(self: *const DotConfig, name: []const u8) u2 {
        const v = self.map.get(name) orelse return 0;
        if (vh.eql(v, "y")) return 2;
        if (vh.eql(v, "m")) return 1;
        return 0;
    }

    pub fn count(self: *const DotConfig) usize {
        return self.map.count();
    }

    pub fn render(self: *const DotConfig) []u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.map.keys(), self.map.values()) |k, v| {
            if (vh.eql(v, "n")) out.print(vh.gpa, "# CONFIG_{s} is not set\n", .{k}) catch vh.oom() else out.print(vh.gpa, "CONFIG_{s}={s}\n", .{ k, v }) catch vh.oom();
        }
        return out.items;
    }
};

/// a value for messages: the spelling, or "n" when absent
pub fn show(v: ?[]const u8) []const u8 {
    return v orelse "n";
}

// ---------------------------------------------------------------- the Kconfig tree

/// one "config NAME" block
pub const Def = struct {
    where: []const u8,
    prompt: bool = false,
    /// the "if EXPR" of the prompt: while it is n the option keeps its default, whatever
    /// the .config says
    prompt_cond: ?[]const u8 = null,
    /// AND-ed conditions, as written: the block's own "depends on" lines and those of the
    /// enclosing if, menu and choice blocks
    depends: std.ArrayList([]const u8) = .empty,
};

pub const Sym = struct {
    name: []const u8,
    /// bool, tristate, string, int, hex; "" when the tree never says
    kind: []const u8 = "",
    /// a member of a choice block: only one of them can be y
    choice: bool = false,
    defs: std.ArrayList(Def) = .empty,
    /// "TARGET" or "TARGET if EXPR", as written
    selects: std.ArrayList([]const u8) = .empty,

    pub fn hasPrompt(self: *const Sym) bool {
        for (self.defs.items) |d| if (d.prompt) return true;
        return false;
    }
};

const Frame = struct {
    kind: enum { block_if, menu, choice },
    conds: std.ArrayList([]const u8) = .empty,
};

pub const Tree = struct {
    root: []const u8,
    arch: []const u8 = "x86",
    syms: std.StringHashMapUnmanaged(*Sym) = .empty,
    files: usize = 0,
    frames: std.ArrayList(Frame) = .empty,

    /// parse ROOT/Kconfig and everything it sources (for arch x86)
    pub fn load(root: []const u8) Tree {
        var t: Tree = .{ .root = root };
        t.parseFile("Kconfig", 0);
        return t;
    }

    pub fn get(self: *const Tree, name: []const u8) ?*Sym {
        return self.syms.get(name);
    }

    fn sym(self: *Tree, name: []const u8) *Sym {
        if (self.syms.get(name)) |s| return s;
        const s = vh.gpa.create(Sym) catch vh.oom();
        s.* = .{ .name = vh.dupe(name) };
        self.syms.put(vh.gpa, s.name, s) catch vh.oom();
        return s;
    }

    fn parseFile(self: *Tree, rel: []const u8, depth: usize) void {
        if (depth > 32) vh.die("Kconfig: source nesting too deep at {s}", .{rel});
        const text = vh.readFile(vh.fmt("{s}/{s}", .{ self.root, rel })) catch {
            vh.warn("Kconfig: {s}: {s} (skipped)", .{ rel, vh.serr() });
            return;
        };
        self.files += 1;
        self.parseText(text, rel, depth);
    }

    /// one Kconfig file; `rel` names it in "where" strings
    pub fn parseText(self: *Tree, text: []const u8, rel: []const u8, depth: usize) void {
        var lines: Lines = .{ .text = text };
        var cur: ?*Sym = null;
        while (lines.next()) |l| {
            const trimmed = vh.strip(stripComment(l.text));
            if (trimmed.len == 0) continue;
            var it = mem.tokenizeAny(u8, trimmed, " \t");
            const kw = it.next() orelse continue;
            const rest = vh.strip(trimmed[kw.len..]);
            if (vh.eql(kw, "config") or vh.eql(kw, "menuconfig")) {
                const s = self.sym(rest);
                var d: Def = .{ .where = vh.fmt("{s}:{d}", .{ rel, l.no }) };
                for (self.frames.items) |f| {
                    for (f.conds.items) |c| d.depends.append(vh.gpa, c) catch vh.oom();
                    if (f.kind == .choice) s.choice = true;
                }
                s.defs.append(vh.gpa, d) catch vh.oom();
                cur = s;
            } else if (vh.eql(kw, "choice")) {
                self.frames.append(vh.gpa, .{ .kind = .choice }) catch vh.oom();
                cur = null;
            } else if (vh.eql(kw, "menu")) {
                self.frames.append(vh.gpa, .{ .kind = .menu }) catch vh.oom();
                cur = null;
            } else if (vh.eql(kw, "if")) {
                var f: Frame = .{ .kind = .block_if };
                f.conds.append(vh.gpa, vh.dupe(rest)) catch vh.oom();
                self.frames.append(vh.gpa, f) catch vh.oom();
                cur = null;
            } else if (vh.eql(kw, "endchoice") or vh.eql(kw, "endmenu") or vh.eql(kw, "endif")) {
                if (self.frames.items.len > 0) _ = self.frames.pop();
                cur = null;
            } else if (vh.eql(kw, "source")) {
                self.parseFile(self.subst(unquote(rest)), depth + 1);
                cur = null;
            } else if (vh.eql(kw, "comment") or vh.eql(kw, "mainmenu")) {
                cur = null;
            } else if (vh.eql(kw, "help") or vh.eql(kw, "---help---")) {
                lines.skipHelp();
            } else if (vh.eql(kw, "depends")) {
                const expr = vh.dupe(vh.strip(if (vh.startsWith(rest, "on ")) rest[3..] else rest));
                if (cur) |s| {
                    s.defs.items[s.defs.items.len - 1].depends.append(vh.gpa, expr) catch vh.oom();
                } else if (self.frames.items.len > 0) {
                    const f = &self.frames.items[self.frames.items.len - 1];
                    if (f.kind != .block_if) f.conds.append(vh.gpa, expr) catch vh.oom();
                }
            } else if (vh.eql(kw, "visible")) {
                // "visible if EXPR" of a menu: without it nothing inside can be set by hand
                const expr = vh.dupe(vh.strip(if (vh.startsWith(rest, "if ")) rest[3..] else rest));
                if (cur == null and self.frames.items.len > 0) {
                    const f = &self.frames.items[self.frames.items.len - 1];
                    if (f.kind == .menu) f.conds.append(vh.gpa, expr) catch vh.oom();
                }
            } else if (cur) |s| {
                const d = &s.defs.items[s.defs.items.len - 1];
                if (vh.eql(kw, "bool") or vh.eql(kw, "tristate") or vh.eql(kw, "string") or vh.eql(kw, "int") or vh.eql(kw, "hex")) {
                    s.kind = vh.dupe(kw);
                    if (rest.len > 0 and (rest[0] == '"' or rest[0] == '\'')) {
                        d.prompt = true;
                        d.prompt_cond = promptCond(rest);
                    }
                } else if (vh.eql(kw, "def_bool") or vh.eql(kw, "def_tristate")) {
                    s.kind = vh.dupe(kw[4..]);
                } else if (vh.eql(kw, "prompt")) {
                    d.prompt = true;
                    d.prompt_cond = promptCond(rest);
                } else if (vh.eql(kw, "select")) {
                    s.selects.append(vh.gpa, vh.dupe(rest)) catch vh.oom();
                }
                // default, imply, range, option, modules: not needed here
            }
        }
    }

    fn subst(self: *const Tree, path: []const u8) []const u8 {
        var p = path;
        if (vh.startsWith(p, "$(srctree)/")) p = p[11..];
        p = replaceAll(p, "$(SRCARCH)", self.arch);
        return replaceAll(p, "$(ARCH)", self.arch);
    }
};

/// lines with "\" continuations joined; a help block is skipped by its indentation
const Lines = struct {
    text: []const u8,
    pos: usize = 0,
    no: usize = 0,

    const Line = struct { text: []const u8, no: usize };

    fn rawNext(self: *Lines) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const end = mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
        const line = self.text[self.pos..end];
        self.pos = if (end < self.text.len) end + 1 else end;
        self.no += 1;
        return line;
    }

    fn next(self: *Lines) ?Line {
        const first = self.rawNext() orelse return null;
        const no = self.no;
        if (!vh.endsWith(first, "\\")) return .{ .text = first, .no = no };
        // "a \" + "   b" -> "a b": the pieces are joined by one space
        var joined: std.ArrayList(u8) = .empty;
        var cur = first;
        while (vh.endsWith(cur, "\\")) {
            joined.appendSlice(vh.gpa, mem.trimEnd(u8, cur[0 .. cur.len - 1], " \t")) catch vh.oom();
            joined.append(vh.gpa, ' ') catch vh.oom();
            cur = mem.trimStart(u8, self.rawNext() orelse "", " \t");
        }
        joined.appendSlice(vh.gpa, cur) catch vh.oom();
        return .{ .text = joined.items, .no = no };
    }

    /// after "help": the first non-blank line sets the indentation; the block ends at the
    /// first non-blank line indented less than that
    fn skipHelp(self: *Lines) void {
        var first: ?usize = null;
        while (self.pos < self.text.len) {
            const end = mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
            const line = self.text[self.pos..end];
            const blank = vh.strip(line).len == 0;
            if (!blank) {
                const ind = indent(line);
                if (first == null) {
                    if (ind == 0) return;
                    first = ind;
                } else if (ind < first.?) return;
            }
            self.pos = if (end < self.text.len) end + 1 else end;
            self.no += 1;
        }
    }
};

/// leading whitespace as columns, a tab reaching the next multiple of 8 (as Kconfig counts)
fn indent(line: []const u8) usize {
    var col: usize = 0;
    for (line) |c| {
        if (c == ' ') col += 1 else if (c == '\t') col = (col & ~@as(usize, 7)) + 8 else break;
    }
    return col;
}

/// "#" to the end of the line outside quotes is a comment
fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#') return line[0..i];
    }
    return line;
}

/// `"prompt text" if EXPR` -> EXPR; null without a condition
fn promptCond(rest: []const u8) ?[]const u8 {
    if (rest.len == 0 or (rest[0] != '"' and rest[0] != '\'')) return null;
    const end = mem.indexOfScalarPos(u8, rest, 1, rest[0]) orelse return null;
    const after = vh.strip(rest[end + 1 ..]);
    if (!vh.startsWith(after, "if ")) return null;
    return vh.dupe(vh.strip(after[3..]));
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

fn replaceAll(s: []const u8, needle: []const u8, repl: []const u8) []const u8 {
    if (mem.indexOf(u8, s, needle) == null) return s;
    return mem.replaceOwned(u8, vh.gpa, s, needle, repl) catch vh.oom();
}

// ---------------------------------------------------------------- expressions

/// Evaluates a Kconfig expression against a .config (y=2, m=1, n=0) and collects the terms
/// that make it fail: a symbol that is n, a negated symbol that is y, a comparison that
/// does not hold. "$(macro)" terms are assumed y: their value is the kernel's business.
pub const Eval = struct {
    cfg: *const DotConfig,
    s: []const u8,
    i: usize = 0,
    result: u2 = 0,
    unmet: vh.Strv = .{},

    const Val = struct { tri: u2, raw: []const u8, name: ?[]const u8 };

    pub fn run(cfg: *const DotConfig, expr: []const u8) Eval {
        var e: Eval = .{ .cfg = cfg, .s = expr };
        e.result = e.parseOr(false);
        return e;
    }

    /// the failing terms as one line, "" when none were recorded
    pub fn why(self: *const Eval) []const u8 {
        return self.unmet.join(", ");
    }

    fn skipWs(self: *Eval) void {
        while (self.i < self.s.len and vh.isSpace(self.s[self.i])) self.i += 1;
    }

    fn accept(self: *Eval, tok: []const u8) bool {
        self.skipWs();
        if (vh.startsWith(self.s[self.i..], tok)) {
            self.i += tok.len;
            return true;
        }
        return false;
    }

    fn parseOr(self: *Eval, neg: bool) u2 {
        var v = self.parseAnd(neg);
        while (self.accept("||")) v = @max(v, self.parseAnd(neg));
        return v;
    }

    fn parseAnd(self: *Eval, neg: bool) u2 {
        var v = self.parseNot(neg);
        while (self.accept("&&")) v = @min(v, self.parseNot(neg));
        return v;
    }

    fn parseNot(self: *Eval, neg: bool) u2 {
        if (self.accept("!")) {
            const v = self.parseNot(!neg);
            return @as(u2, 2) - v;
        }
        return self.parseCmp(neg);
    }

    fn parseCmp(self: *Eval, neg: bool) u2 {
        const a = self.parseAtom(neg);
        const ops = [_][]const u8{ "!=", "<=", ">=", "=", "<", ">" };
        for (ops) |op| {
            if (self.accept(op)) {
                const b = self.parseAtom(neg);
                const holds = compare(op, a.raw, b.raw);
                if (holds == neg) {
                    const an = a.name orelse a.raw;
                    const bn = b.name orelse b.raw;
                    self.unmet.add(vh.fmt("{s}{s}{s} ({s}={s}{s})", .{ an, op, bn, an, a.raw, if (neg) ", must not hold" else "" }));
                }
                return if (holds) 2 else 0;
            }
        }
        if (a.name) |n| {
            if (!neg and a.tri == 0) self.unmet.add(vh.fmt("{s}=n", .{n}));
            if (neg and a.tri != 0) self.unmet.add(vh.fmt("!{s} ({s}={s})", .{ n, n, a.raw }));
        }
        return a.tri;
    }

    fn parseAtom(self: *Eval, neg: bool) Val {
        self.skipWs();
        if (self.i >= self.s.len) return .{ .tri = 0, .raw = "n", .name = null };
        const c = self.s[self.i];
        if (c == '(') {
            self.i += 1;
            const v = self.parseOr(neg);
            _ = self.accept(")");
            return .{ .tri = v, .raw = triName(v), .name = null };
        }
        if (c == '"' or c == '\'') {
            const end = mem.indexOfScalarPos(u8, self.s, self.i + 1, c) orelse self.s.len;
            const lit = self.s[self.i + 1 .. end];
            self.i = @min(end + 1, self.s.len);
            return .{ .tri = triOf(lit), .raw = lit, .name = null };
        }
        if (vh.startsWith(self.s[self.i..], "$(")) {
            var depth: usize = 0;
            while (self.i < self.s.len) : (self.i += 1) {
                if (self.s[self.i] == '(') depth += 1;
                if (self.s[self.i] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        self.i += 1;
                        break;
                    }
                }
            }
            return .{ .tri = 2, .raw = "y", .name = null };
        }
        const start = self.i;
        while (self.i < self.s.len and (std.ascii.isAlphanumeric(self.s[self.i]) or self.s[self.i] == '_')) self.i += 1;
        const ident = self.s[start..self.i];
        if (ident.len == 0) {
            self.i += 1; // an unexpected byte: skip it rather than loop
            return .{ .tri = 0, .raw = "n", .name = null };
        }
        if (vh.eql(ident, "y") or vh.eql(ident, "m") or vh.eql(ident, "n") or std.ascii.isDigit(ident[0]))
            return .{ .tri = triOf(ident), .raw = ident, .name = null };
        const raw = unquote(self.cfg.get(ident) orelse "n");
        return .{ .tri = self.cfg.tri(ident), .raw = raw, .name = ident };
    }
};

fn triOf(s: []const u8) u2 {
    if (vh.eql(s, "y")) return 2;
    if (vh.eql(s, "m")) return 1;
    return 0;
}

fn triName(v: u2) []const u8 {
    return switch (v) {
        2 => "y",
        1 => "m",
        else => "n",
    };
}

fn compare(op: []const u8, a: []const u8, b: []const u8) bool {
    if (vh.eql(op, "=")) return vh.eql(a, b);
    if (vh.eql(op, "!=")) return !vh.eql(a, b);
    const na = std.fmt.parseInt(i64, a, 0) catch null;
    const nb = std.fmt.parseInt(i64, b, 0) catch null;
    const ord: std.math.Order = if (na != null and nb != null) std.math.order(na.?, nb.?) else mem.order(u8, a, b);
    if (vh.eql(op, "<")) return ord == .lt;
    if (vh.eql(op, ">")) return ord == .gt;
    if (vh.eql(op, "<=")) return ord != .gt;
    return ord != .lt; // ">="
}

/// Why `name` is not what was asked, from the tree and the final .config: one line per
/// finding, for the diff report.
pub fn explain(tree: ?*const Tree, cfg: *const DotConfig, name: []const u8) []const u8 {
    const t = tree orelse return "no kernel tree given (--kernel DIR): the reason is not known";
    const s = t.get(name) orelse return "not a symbol of this kernel tree: a typo, or removed in this version";
    var out: std.ArrayList(u8) = .empty;
    out.print(vh.gpa, "{s}", .{if (s.kind.len > 0) s.kind else "symbol"}) catch vh.oom();
    if (s.choice) out.appendSlice(vh.gpa, ", a choice member (one of the choice is y, the others n)") catch vh.oom();
    if (!s.hasPrompt()) out.appendSlice(vh.gpa, ", no prompt (its value comes from defaults and selects only, not from a fragment)") catch vh.oom();
    var satisfied: ?[]const u8 = null;
    var macro = false;
    var hidden: vh.Strv = .{};
    var visible_prompt = false;
    for (s.defs.items) |d| {
        var failed: vh.Strv = .{};
        for (d.depends.items) |expr| {
            if (mem.indexOf(u8, expr, "$(") != null) macro = true;
            const e = Eval.run(cfg, expr);
            if (e.result == 0) failed.add(vh.fmt("\"{s}\" [{s}]", .{ expr, e.why() }));
        }
        if (failed.len() == 0) {
            if (satisfied == null) satisfied = d.where;
        } else {
            out.print(vh.gpa, "; at {s} unmet: {s}", .{ d.where, failed.join("; ") }) catch vh.oom();
        }
        if (d.prompt) {
            if (d.prompt_cond) |c| {
                const e = Eval.run(cfg, c);
                if (e.result == 0) hidden.add(vh.fmt("\"{s}\" [{s}]", .{ c, e.why() })) else visible_prompt = true;
            } else visible_prompt = true;
        }
    }
    if (s.hasPrompt() and !visible_prompt and hidden.len() > 0)
        out.print(vh.gpa, "; the prompt is hidden by {s}: a hidden option keeps its default, whatever the fragment says", .{hidden.join("; ")}) catch vh.oom();
    const by = selectedBy(t, cfg, name);
    if (by.len() > 0) out.print(vh.gpa, "; selected by {s} (a select cannot be undone by a fragment)", .{by.join(", ")}) catch vh.oom();
    if (macro) out.appendSlice(vh.gpa, "; a $(...) macro in the dependencies was assumed y: the toolchain decides it (clang-only options need LLVM=1)") catch vh.oom();
    if (satisfied != null and !(s.hasPrompt() and !visible_prompt) and by.len() == 0)
        out.print(vh.gpa, "; dependencies satisfied at {s}: the value was decided elsewhere (a default, a choice, a later fragment, MODULES=n for an =m)", .{satisfied.?}) catch vh.oom();
    return out.items;
}

/// the symbols that are y or m in the final config and select `name` with their condition
/// holding; at most eight, for the report
fn selectedBy(t: *const Tree, cfg: *const DotConfig, name: []const u8) vh.Strv {
    var by: vh.Strv = .{};
    var it = t.syms.iterator();
    while (it.next()) |kv| {
        const s = kv.value_ptr.*;
        if (s.selects.items.len == 0 or cfg.tri(s.name) == 0) continue;
        for (s.selects.items) |sel| {
            var target = sel;
            var cond: ?[]const u8 = null;
            if (mem.indexOf(u8, sel, " if ")) |i| {
                target = vh.strip(sel[0..i]);
                cond = vh.strip(sel[i + 4 ..]);
            }
            if (!vh.eql(target, name)) continue;
            if (cond) |c| if (Eval.run(cfg, c).result == 0) continue;
            if (by.len() < 8 and !by.has(s.name)) by.add(s.name);
        }
    }
    by.sort();
    return by;
}

// ---------------------------------------------------------------- Kbuild: module -> symbol

/// "obj-$(CONFIG_X) += name.o" in every Makefile and Kbuild of the tree: the module name.o
/// is built when X is y or m. The same mapping streamline_config.pl makes for localyesconfig.
pub const Kbuild = struct {
    map: std.StringHashMapUnmanaged(*vh.Strv) = .empty,
    files: usize = 0,

    pub fn load(root: []const u8) Kbuild {
        var k: Kbuild = .{};
        k.walk(root, "");
        return k;
    }

    fn walk(self: *Kbuild, root: []const u8, rel: []const u8) void {
        const dir = if (rel.len == 0) root else vh.fmt("{s}/{s}", .{ root, rel });
        const names = vh.listDir(dir) catch return;
        for (names) |n| {
            const sub = if (rel.len == 0) n else vh.fmt("{s}/{s}", .{ rel, n });
            if (vh.eql(n, "Makefile") or vh.eql(n, "Kbuild")) {
                const text = vh.readFile(vh.fmt("{s}/{s}", .{ root, sub })) catch continue;
                self.files += 1;
                self.parseText(text);
                continue;
            }
            if (skipDir(sub)) continue;
            if (vh.isDir(vh.fmt("{s}/{s}", .{ root, sub }))) self.walk(root, sub);
        }
    }

    pub fn parseText(self: *Kbuild, text: []const u8) void {
        var lines: Lines = .{ .text = text };
        while (lines.next()) |l| {
            const t = vh.strip(l.text);
            if (!vh.startsWith(t, "obj-$(CONFIG_")) continue;
            const close = mem.indexOfScalar(u8, t, ')') orelse continue;
            const symname = t[13..close];
            const eq = mem.indexOfScalarPos(u8, t, close, '=') orelse continue;
            var it = mem.tokenizeAny(u8, t[eq + 1 ..], " \t");
            while (it.next()) |tok| {
                if (!vh.endsWith(tok, ".o")) continue;
                var obj = tok[0 .. tok.len - 2];
                if (mem.lastIndexOfScalar(u8, obj, '/')) |i| obj = obj[i + 1 ..];
                if (obj.len == 0) continue;
                self.add(obj, symname);
            }
        }
    }

    fn add(self: *Kbuild, obj: []const u8, symname: []const u8) void {
        const name = normalizeName(obj);
        const gop = self.map.getOrPut(vh.gpa, name) catch vh.oom();
        if (!gop.found_existing) {
            const list = vh.gpa.create(vh.Strv) catch vh.oom();
            list.* = .{};
            gop.value_ptr.* = list;
        }
        if (!gop.value_ptr.*.has(symname)) gop.value_ptr.*.add(symname);
    }

    /// the CONFIG symbols (without CONFIG_) that build module `name`; empty when unknown
    pub fn symbolsOf(self: *const Kbuild, name: []const u8) []const []const u8 {
        const list = self.map.get(normalizeName(name)) orelse return &.{};
        return list.slice();
    }
};

fn normalizeName(name: []const u8) []const u8 {
    const n = vh.dupe(name);
    for (n) |*c| {
        if (c.* == '-') c.* = '_';
    }
    return n;
}

/// directories without Kbuild rules of this machine's kernel
fn skipDir(rel: []const u8) bool {
    const skip = [_][]const u8{ ".git", "Documentation", "tools", "samples", "scripts", "usr", "LICENSES", "certs", "rust", "include" };
    for (skip) |d| if (vh.eql(rel, d)) return true;
    if (vh.startsWith(rel, "arch/") and !vh.startsWith(rel, "arch/x86")) return true;
    return false;
}

// ---------------------------------------------------------------- tests

test "DotConfig: parse, values, render" {
    var c: DotConfig = .{};
    c.parse("# comment\nCONFIG_A=y\nCONFIG_B=m\n# CONFIG_C is not set\nCONFIG_S=\"text\"\nCONFIG_N=12\nCONFIG_H=0x10\n\njunk\n");
    try std.testing.expectEqual(@as(usize, 6), c.count());
    try std.testing.expectEqual(@as(u2, 2), c.tri("A"));
    try std.testing.expectEqual(@as(u2, 1), c.tri("B"));
    try std.testing.expectEqual(@as(u2, 0), c.tri("C"));
    try std.testing.expectEqual(@as(u2, 0), c.tri("MISSING"));
    try std.testing.expectEqualStrings("\"text\"", c.get("S").?);
    try std.testing.expectEqualStrings("n", c.get("C").?);
    c.set("B", "y");
    c.set("NEW", "n");
    try std.testing.expectEqualStrings("CONFIG_A=y\nCONFIG_B=y\n# CONFIG_C is not set\nCONFIG_S=\"text\"\nCONFIG_N=12\nCONFIG_H=0x10\n# CONFIG_NEW is not set\n", c.render());
    c.setLast("A", "n");
    try std.testing.expectEqualStrings("CONFIG_B=y\n# CONFIG_C is not set\nCONFIG_S=\"text\"\nCONFIG_N=12\nCONFIG_H=0x10\n# CONFIG_NEW is not set\n# CONFIG_A is not set\n", c.render());
    try std.testing.expectEqual(@as(usize, 7), c.count());
    try std.testing.expect(DotConfig.parseLine("CONFIG_=y") == null);
    try std.testing.expect(DotConfig.parseLine("# CONFIG_X") == null);
}

test "Eval: operators and the unmet terms" {
    var c: DotConfig = .{};
    c.parse("CONFIG_A=y\nCONFIG_B=m\n# CONFIG_C is not set\nCONFIG_S=\"abc\"\nCONFIG_N=12\n");
    try std.testing.expectEqual(@as(u2, 2), Eval.run(&c, "A").result);
    try std.testing.expectEqual(@as(u2, 1), Eval.run(&c, "A && B").result);
    try std.testing.expectEqual(@as(u2, 0), Eval.run(&c, "A && C").result);
    try std.testing.expectEqual(@as(u2, 2), Eval.run(&c, "C || A").result);
    try std.testing.expectEqual(@as(u2, 2), Eval.run(&c, "!C").result);
    try std.testing.expectEqual(@as(u2, 0), Eval.run(&c, "!A").result);
    try std.testing.expectEqual(@as(u2, 1), Eval.run(&c, "!B").result);
    try std.testing.expectEqual(@as(u2, 2), Eval.run(&c, "(A || C) && !C").result);
    try std.testing.expectEqual(@as(u2, 2), Eval.run(&c, "B != n").result);
    try std.testing.expectEqual(@as(u2, 0), Eval.run(&c, "B = y").result);
    try std.testing.expectEqual(@as(u2, 2), Eval.run(&c, "S = \"abc\"").result);
    try std.testing.expectEqual(@as(u2, 2), Eval.run(&c, "N >= 10").result);
    try std.testing.expectEqual(@as(u2, 0), Eval.run(&c, "N > 0x10").result);
    try std.testing.expectEqual(@as(u2, 2), Eval.run(&c, "$(cc-option,-mfoo) && A").result);
    try std.testing.expectEqual(@as(u2, 0), Eval.run(&c, "MISSING").result);
    const e1 = Eval.run(&c, "A && C && (B || D)");
    try std.testing.expectEqual(@as(u2, 0), e1.result);
    try std.testing.expectEqualStrings("C=n, D=n", e1.why());
    const e2 = Eval.run(&c, "!A");
    try std.testing.expectEqualStrings("!A (A=y)", e2.why());
    const e3 = Eval.run(&c, "B = y");
    try std.testing.expectEqualStrings("B=y (B=m)", e3.why());
    const e4 = Eval.run(&c, "A");
    try std.testing.expectEqualStrings("", e4.why());
}

test "Tree: blocks, scopes, help, continuation, choice" {
    var t: Tree = .{ .root = "/nonexistent" };
    t.parseText("mainmenu \"test\"\n" ++
        "config A\n" ++
        "\tbool \"A prompt\" # a comment\n" ++
        "\tdepends on X && \\\n" ++
        "\t\tY\n" ++
        "\tselect B if Z\n" ++
        "\thelp\n" ++
        "\t  Some help text\n" ++
        "\t  that mentions config FAKE\n" ++
        "\n" ++
        "\t  and continues after a blank line.\n" ++
        "\n" ++
        "menu \"Menu\"\n" ++
        "\tdepends on M\n" ++
        "\n" ++
        "if I\n" ++
        "config B\n" ++
        "\ttristate\n" ++
        "\tdefault y\n" ++
        "\n" ++
        "choice\n" ++
        "\tprompt \"pick\"\n" ++
        "\tdepends on P\n" ++
        "\n" ++
        "config C1\n" ++
        "\tbool \"one\"\n" ++
        "config C2\n" ++
        "\tbool \"two\"\n" ++
        "endchoice\n" ++
        "endif\n" ++
        "endmenu\n" ++
        "\n" ++
        "config D\n" ++
        "\tdef_bool y\n" ++
        "\tdepends on A\n" ++
        "config E\n" ++
        "\tbool \"e\" if EXPERT\n" ++
        "\tdefault y\n" ++
        "config F\n" ++
        "\tbool\n" ++
        "\tprompt \"f\" if EXPERT && A\n" ++
        "\tselect B if P\n" ++
        "\tselect D\n", "t/Kconfig", 0);
    try std.testing.expectEqual(@as(usize, 8), indent("\tx"));
    try std.testing.expectEqual(@as(usize, 10), indent("\t  x"));
    try std.testing.expectEqual(@as(usize, 8), indent("   \tx"));
    const a = t.get("A").?;
    try std.testing.expectEqualStrings("bool", a.kind);
    try std.testing.expect(a.hasPrompt());
    try std.testing.expectEqual(@as(usize, 1), a.defs.items.len);
    try std.testing.expectEqualStrings("X && Y", a.defs.items[0].depends.items[0]);
    try std.testing.expectEqualStrings("t/Kconfig:2", a.defs.items[0].where);
    try std.testing.expectEqualStrings("B if Z", a.selects.items[0]);
    try std.testing.expect(t.get("FAKE") == null);
    const b = t.get("B").?;
    try std.testing.expectEqualStrings("tristate", b.kind);
    try std.testing.expect(!b.hasPrompt());
    try std.testing.expectEqual(@as(usize, 2), b.defs.items[0].depends.items.len);
    try std.testing.expectEqualStrings("M", b.defs.items[0].depends.items[0]);
    try std.testing.expectEqualStrings("I", b.defs.items[0].depends.items[1]);
    const c1 = t.get("C1").?;
    try std.testing.expect(c1.choice);
    try std.testing.expectEqual(@as(usize, 3), c1.defs.items[0].depends.items.len);
    try std.testing.expectEqualStrings("P", c1.defs.items[0].depends.items[2]);
    const d = t.get("D").?;
    try std.testing.expect(!d.choice);
    try std.testing.expectEqualStrings("bool", d.kind);
    try std.testing.expectEqual(@as(usize, 1), d.defs.items[0].depends.items.len);
    try std.testing.expectEqual(@as(usize, 0), t.frames.items.len);

    const e = t.get("E").?;
    try std.testing.expect(e.hasPrompt());
    try std.testing.expectEqualStrings("EXPERT", e.defs.items[0].prompt_cond.?);
    try std.testing.expectEqualStrings("EXPERT && A", t.get("F").?.defs.items[0].prompt_cond.?);
    try std.testing.expect(a.defs.items[0].prompt_cond == null);

    var cfg: DotConfig = .{};
    cfg.parse("CONFIG_M=y\n# CONFIG_I is not set\nCONFIG_P=y\nCONFIG_E=y\nCONFIG_F=y\nCONFIG_D=y\n# CONFIG_EXPERT is not set\n");
    const why = explain(&t, &cfg, "B");
    try std.testing.expect(mem.indexOf(u8, why, "no prompt") != null);
    try std.testing.expect(mem.indexOf(u8, why, "\"I\" [I=n]") != null);
    try std.testing.expect(mem.indexOf(u8, why, "selected by F") != null);
    try std.testing.expect(mem.indexOf(u8, explain(&t, &cfg, "NOPE"), "not a symbol") != null);
    try std.testing.expect(mem.indexOf(u8, explain(null, &cfg, "B"), "no kernel tree") != null);
    try std.testing.expect(mem.indexOf(u8, explain(&t, &cfg, "C1"), "choice member") != null);
    const why_e = explain(&t, &cfg, "E");
    try std.testing.expect(mem.indexOf(u8, why_e, "hidden by \"EXPERT\" [EXPERT=n]") != null);
    try std.testing.expect(mem.indexOf(u8, why_e, "decided elsewhere") == null);
    const why_d = explain(&t, &cfg, "D");
    try std.testing.expect(mem.indexOf(u8, why_d, "selected by F") != null);
    cfg.set("EXPERT", "y");
    try std.testing.expect(mem.indexOf(u8, explain(&t, &cfg, "E"), "hidden") == null);
    cfg.set("P", "n");
    try std.testing.expect(mem.indexOf(u8, explain(&t, &cfg, "B"), "selected by") == null);
}

test "Kbuild: obj rules" {
    var k: Kbuild = .{};
    k.parseText("# SPDX\n" ++
        "obj-$(CONFIG_SND_HDA_INTEL) += snd-hda-intel.o\n" ++
        "snd-hda-intel-y := hda_intel.o\n" ++
        "obj-$(CONFIG_IWLWIFI)\t+= iwlwifi.o \\\n" ++
        "\tother.o\n" ++
        "obj-$(CONFIG_XFS_FS) += xfs.o\n" ++
        "obj-$(CONFIG_FOO) += dir/\n" ++
        "obj-$(CONFIG_FOO) += sub/bar.o\n" ++
        "obj-y += always.o\n" ++
        "obj-$(CONFIG_ALSO_IWL) += iwlwifi.o\n");
    try std.testing.expectEqual(@as(usize, 1), k.symbolsOf("snd_hda_intel").len);
    try std.testing.expectEqualStrings("SND_HDA_INTEL", k.symbolsOf("snd-hda-intel")[0]);
    try std.testing.expectEqual(@as(usize, 2), k.symbolsOf("iwlwifi").len);
    try std.testing.expectEqualStrings("IWLWIFI", k.symbolsOf("other")[0]);
    try std.testing.expectEqualStrings("FOO", k.symbolsOf("bar")[0]);
    try std.testing.expectEqual(@as(usize, 0), k.symbolsOf("always").len);
    try std.testing.expectEqual(@as(usize, 0), k.symbolsOf("dir").len);
}
