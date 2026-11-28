//! Offline, bounded Draft 2020-12 evaluation. Compile schema documents once;
//! validate independent owning JSON instances with separate allocators.
const std = @import("std");
const core = @import("core.zig");
const json = @import("json.zig");
const numbers = @import("decimal.zig");
const patterns = @import("patterns.zig");
const V = std.json.Value;
const Allocator = std.mem.Allocator;
pub const regex_enabled = patterns.enabled;
pub const RegistryEntry = struct { uri: []const u8, schema: []const u8 };
pub const CompileOptions = struct {
    json: json.Options = .{},
    base_uri: []const u8 = "https://zigil.invalid/root.json",
    max_schema_nodes: usize = 10_000,
    max_work: usize = 10_000_000,
    max_registry_bytes: usize = 4_194_304,
    max_registry_entries: usize = 128,
};
pub const Options = struct { json: json.Options = .{}, max_work: usize = 1_000_000, max_depth: usize = 64 };
pub const Finding = struct { issue: core.Issue, keyword: []const u8, schema_location: []const u8 };
pub const Result = struct {
    state: *json.State,
    outcome: union(enum) { valid, invalid: Finding, malformed: json.Syntax },
    pub fn deinit(self: *Result) void {
        self.state.destroy();
        self.* = undefined;
    }
};
const Vocabulary = struct { validation: bool = true, applicator: bool = true, unevaluated: bool = true };
const Node = struct {
    vocabulary: Vocabulary = .{},
    value: *const V,
    base: []const u8,
    location: []const u8,
    resource: *Node,
    dynamic_anchor: ?[]const u8 = null,
    reference: ?*Node = null,
    dynamic_reference: ?*Node = null,
    dynamic_name: ?[]const u8 = null,
    pattern: ?patterns.Program = null,
    property_patterns: std.array_hash_map.String(patterns.Program) = .empty,
};

pub const Compiled = struct {
    state: *json.State,
    root: *Node,
    nodes: std.array_list.Managed(*Node),
    by_pointer: std.AutoHashMapUnmanaged(usize, *Node) = .empty,
    resources: std.array_hash_map.String(*Node) = .empty,
    anchors: std.array_hash_map.String(*Node) = .empty,
    options: CompileOptions,
    work: usize = 0,
    raw_documents: std.array_hash_map.String(*const V) = .empty,
    metaschemas: std.array_hash_map.String(void) = .empty,

    pub fn deinit(self: *Compiled) void {
        self.state.destroy();
        self.* = undefined;
    }
    pub fn validate(self: *const Compiled, allocator: Allocator, input: []const u8, options: Options) !Result {
        if (options.max_depth > 256) return error.DepthLimitExceeded;
        const document = try json.parse(allocator, input, options.json);
        errdefer document.state.destroy();
        const state = document.state;
        switch (document.outcome) {
            .malformed => |syntax| return .{ .state = state, .outcome = .{ .malformed = syntax } },
            .duplicate => return .{ .state = state, .outcome = .{ .invalid = .{ .issue = .{ .code = .duplicate_field, .path = &.{}, .message = "duplicate JSON object member" }, .keyword = "", .schema_location = "" } } },
            .value => |value| {
                const path = state.allocator().alloc(core.Segment, options.max_depth) catch return state.allocationFailure();
                var ctx: Context = .{ .compiled = self, .state = state, .options = options, .path = path };
                const evaluation = ctx.evaluate(self.root, value) catch |err| switch (err) {
                    error.OutOfMemory => return state.allocationFailure(),
                    else => return err,
                };
                return .{ .state = state, .outcome = if (evaluation.valid) .valid else .{ .invalid = ctx.finding.? } };
            },
        }
    }

    fn charge(self: *Compiled, amount: usize) !void {
        if (amount > self.options.max_work - self.work) return error.WorkLimitExceeded;
        self.work += amount;
    }
    fn child(self: *const Compiled, value: *const V) *Node {
        return self.by_pointer.get(@intFromPtr(value)).?;
    }
    fn addResource(self: *Compiled, uri: []const u8, node: *Node) !void {
        if (self.resources.get(uri)) |old| {
            if (old != node) return error.DuplicateSchemaIdentifier;
            return;
        }
        try self.resources.put(self.state.allocator(), uri, node);
    }
    fn indexNode(self: *Compiled, value: *const V, inherited_base: []const u8, inherited_resource: ?*Node, pointer: []const u8, depth: usize, inherited_vocabulary: Vocabulary) anyerror!*Node {
        try self.charge(1);
        try self.charge(pointer.len);
        try self.charge(inherited_base.len);
        if (self.by_pointer.get(@intFromPtr(value))) |known| return known;
        if (depth >= self.options.json.max_depth) return error.DepthLimitExceeded;
        if (self.nodes.items.len == self.options.max_schema_nodes) return error.SchemaNodeLimitExceeded;
        if (value.* != .bool and value.* != .object) return error.InvalidSchema;
        const allocator = self.state.allocator();
        const node = try allocator.create(Node);
        node.* = .{ .value = value, .base = inherited_base, .location = pointer, .resource = inherited_resource orelse node, .vocabulary = inherited_vocabulary };
        try self.nodes.append(node);
        try self.by_pointer.put(allocator, @intFromPtr(value), node);
        if (value.* == .bool) return node;
        const object = value.object;
        if (object.get("$schema")) |dialect| {
            if (dialect != .string) return error.InvalidSchema;
            if (std.mem.eql(u8, dialect.string, @import("schema.zig").dialect)) {
                node.vocabulary = .{};
            } else {
                const meta = self.raw_documents.get(dialect.string) orelse return error.UnsupportedDialect;
                if (meta.* != .object) return error.InvalidSchema;
                const vocab = meta.object.get("$vocabulary") orelse return error.UnsupportedDialect;
                if (vocab != .object) return error.InvalidSchema;
                node.vocabulary = .{ .validation = false, .applicator = false, .unevaluated = false };
                for (vocab.object.keys(), vocab.object.values()) |name, required| {
                    if (required != .bool) return error.InvalidSchema;
                    if (required.bool and !knownVocabulary(name)) return error.UnsupportedVocabulary;
                    if (std.mem.eql(u8, name, "https://json-schema.org/draft/2020-12/vocab/validation")) node.vocabulary.validation = true;
                    if (std.mem.eql(u8, name, "https://json-schema.org/draft/2020-12/vocab/applicator")) node.vocabulary.applicator = true;
                    if (std.mem.eql(u8, name, "https://json-schema.org/draft/2020-12/vocab/unevaluated")) node.vocabulary.unevaluated = true;
                }
                try self.metaschemas.put(allocator, dialect.string, {});
            }
        }
        if (object.get("$id")) |id| {
            if (id != .string) return error.InvalidSchema;
            const base = try resolveUri(allocator, inherited_base, id.string);
            if (std.mem.indexOfScalar(u8, base, '#')) |hash| {
                if (hash + 1 != base.len) return error.InvalidSchema;
            }
            node.base = withoutFragment(base);
            node.resource = node;
            node.location = try std.fmt.allocPrint(allocator, "{s}#", .{node.base});
            try self.addResource(node.base, node);
        }
        inline for (.{ "$anchor", "$dynamicAnchor" }) |keyword| if (object.get(keyword)) |anchor| {
            if (anchor != .string or !validAnchor(anchor.string)) return error.InvalidSchema;
            const uri = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ node.base, anchor.string });
            if (self.anchors.contains(uri)) return error.DuplicateSchemaIdentifier;
            try self.anchors.put(allocator, uri, node);
            if (comptime std.mem.eql(u8, keyword, "$dynamicAnchor")) node.dynamic_anchor = anchor.string;
        };
        if (object.get("$vocabulary")) |vocabulary| {
            if (vocabulary != .object) return error.InvalidSchema;
            for (vocabulary.object.keys(), vocabulary.object.values()) |name, required| {
                if (required != .bool) return error.InvalidSchema;
                if (required.bool and !knownVocabulary(name)) return error.UnsupportedVocabulary;
            }
        }
        try self.checkForm(node);
        inline for (.{ "$defs", "properties", "patternProperties", "dependentSchemas" }) |keyword| {
            if (node.vocabulary.applicator or comptime std.mem.eql(u8, keyword, "$defs")) {
                if (object.getPtr(keyword)) |map| {
                    if (map.* != .object) return error.InvalidSchema;
                    for (map.object.keys(), map.object.values()) |key, *schema| {
                        _ = try self.indexNode(schema, node.base, node.resource, try appendLocation(allocator, node.location, keyword, key), depth + 1, node.vocabulary);
                        if (comptime std.mem.eql(u8, keyword, "patternProperties")) try node.property_patterns.put(allocator, key, try patterns.Program.compile(allocator, key));
                    }
                }
            }
        }
        if (node.vocabulary.applicator) {
            inline for (.{ "allOf", "anyOf", "oneOf", "prefixItems" }) |keyword| if (object.getPtr(keyword)) |array| {
                if (array.* != .array or array.array.items.len == 0) return error.InvalidSchema;
                for (array.array.items, 0..) |*schema, index| {
                    const position = try std.fmt.allocPrint(allocator, "{d}", .{index});
                    _ = try self.indexNode(schema, node.base, node.resource, try appendLocation(allocator, node.location, keyword, position), depth + 1, node.vocabulary);
                }
            };
        }
        inline for (.{ "additionalProperties", "propertyNames", "contains", "not", "if", "then", "else", "items", "unevaluatedProperties", "unevaluatedItems", "contentSchema" }) |keyword| {
            const active = if (comptime std.mem.startsWith(u8, keyword, "unevaluated")) node.vocabulary.unevaluated else if (comptime std.mem.eql(u8, keyword, "contentSchema")) true else node.vocabulary.applicator;
            if (active) if (object.getPtr(keyword)) |schema| {
                _ = try self.indexNode(schema, node.base, node.resource, try appendLocation(allocator, node.location, keyword, null), depth + 1, node.vocabulary);
            };
        }
        return node;
    }

    fn checkForm(self: *Compiled, node: *Node) !void {
        const o = node.value.object;
        const allocator = self.state.allocator();
        for (o.keys()) |key| {
            try self.charge(1);
            try self.charge(key.len);
        }

        if (node.vocabulary.validation) {
            if (o.get("type")) |kind| switch (kind) {
                .string => |name| if (!knownType(name)) {
                    return error.InvalidSchema;
                },
                .array => |array| {
                    if (array.items.len == 0) return error.InvalidSchema;
                    for (array.items, 0..) |item, index| {
                        if (item != .string or !knownType(item.string)) return error.InvalidSchema;
                        for (array.items[0..index]) |prior| if (std.mem.eql(u8, prior.string, item.string)) {
                            return error.InvalidSchema;
                        };
                    }
                },
                else => return error.InvalidSchema,
            };
            inline for (.{ "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf" }) |keyword| if (o.get(keyword)) |value| {
                if (value != .number_string) return error.InvalidSchema;
                try self.charge(value.number_string.len);
                const decimal = try numbers.Decimal.parse(allocator, value.number_string, self.options.json.numbers);
                if (comptime std.mem.eql(u8, keyword, "multipleOf")) {
                    if (decimal.negative or decimal.zero()) return error.InvalidSchema;
                }
            };
            inline for (.{ "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties", "minContains", "maxContains" }) |keyword| if (o.get(keyword)) |value| {
                if (value != .number_string) return error.InvalidSchema;
                try self.charge(value.number_string.len);
                const decimal = try numbers.Decimal.parse(allocator, value.number_string, self.options.json.numbers);
                if (decimal.negative or !decimal.integer()) return error.InvalidSchema;
            };
            inline for (.{"uniqueItems"}) |keyword| if (o.get(keyword)) |value| {
                if (value != .bool) return error.InvalidSchema;
            };
            if (o.get("pattern")) |pattern| {
                if (pattern != .string) return error.InvalidSchema;
                node.pattern = try patterns.Program.compile(allocator, pattern.string);
            }
            if (o.get("enum")) |values| {
                if (values != .array) return error.InvalidSchema;
            }
            if (o.get("required")) |names| try checkNames(allocator, names);
            if (o.get("dependentRequired")) |dependencies| {
                if (dependencies != .object) return error.InvalidSchema;
                for (dependencies.object.values()) |names| try checkNames(allocator, names);
            }
        }
        inline for (.{ "readOnly", "writeOnly", "deprecated" }) |keyword| if (o.get(keyword)) |value| {
            if (value != .bool) return error.InvalidSchema;
        };
        inline for (.{ "$ref", "$dynamicRef", "title", "description", "$comment", "format", "contentEncoding", "contentMediaType" }) |keyword| if (o.get(keyword)) |value| {
            if (value != .string) return error.InvalidSchema;
        };
        if (o.get("examples")) |examples| {
            if (examples != .array) return error.InvalidSchema;
        }
    }

    fn resolve(self: *Compiled, node: *Node, reference: []const u8) !*Node {
        const allocator = self.state.allocator();
        try self.charge(reference.len);
        try self.charge(node.base.len);
        const uri = try resolveUri(allocator, node.base, reference);
        if (self.anchors.get(uri)) |anchor| return anchor;
        const base = withoutFragment(uri);
        if (self.metaschemas.contains(base)) return error.UnsupportedMetaSchemaReference;
        const resource = self.resources.get(base) orelse return error.UnresolvedReference;
        const hash = std.mem.indexOfScalar(u8, uri, '#') orelse return resource;
        if (hash + 1 == uri.len) return resource;
        const fragment = try decodeFragment(allocator, uri[hash + 1 ..]);
        if (fragment.len == 0) return resource;
        if (fragment[0] != '/') return error.UnresolvedReference;
        const target = try pointerGet(allocator, resource.value, fragment);
        return self.by_pointer.get(@intFromPtr(target)) orelse try self.indexNode(target, resource.base, resource, try std.fmt.allocPrint(allocator, "{s}#{s}", .{ resource.base, fragment }), 0, resource.vocabulary);
    }
};

pub fn compile(allocator: Allocator, source: []const u8, registry: []const RegistryEntry, options: CompileOptions) !Compiled {
    if (registry.len > options.max_registry_entries) return error.RegistryLimitExceeded;
    const document = try json.parse(allocator, source, options.json);
    const state = document.state;
    errdefer state.destroy();
    const root = state.allocator().create(V) catch return state.allocationFailure();
    root.* = switch (document.outcome) {
        .value => |value| value,
        .malformed => return error.MalformedSchema,
        .duplicate => return error.DuplicateSchemaKey,
    };
    var result: Compiled = .{ .state = state, .root = undefined, .nodes = .init(state.allocator()), .options = options };
    compileInto(&result, root, registry) catch |err| switch (err) {
        error.OutOfMemory => return state.allocationFailure(),
        else => return err,
    };
    return result;
}
fn compileInto(result: *Compiled, root: *const V, registry: []const RegistryEntry) !void {
    const allocator = result.state.allocator();
    const base = withoutFragment(try resolveUri(allocator, result.options.base_uri, ""));
    var registry_bytes: usize = 0;
    for (registry) |entry| {
        if (entry.schema.len > result.options.max_registry_bytes - registry_bytes) return error.RegistryLimitExceeded;
        registry_bytes += entry.schema.len;
        var document = try json.parse(result.state.parent, entry.schema, result.options.json);
        defer document.deinit();
        switch (document.outcome) {
            .value => {},
            .malformed => return error.MalformedSchema,
            .duplicate => return error.DuplicateSchemaKey,
        }
        const value = try allocator.create(V);
        value.* = try std.json.parseFromSliceLeaky(V, allocator, entry.schema, .{ .parse_numbers = false, .allocate = .alloc_always });
        const uri = withoutFragment(try resolveUri(allocator, base, entry.uri));
        if (result.raw_documents.contains(uri)) return error.DuplicateSchemaIdentifier;
        try result.raw_documents.put(allocator, uri, value);
    }
    result.root = try result.indexNode(root, base, null, try std.fmt.allocPrint(allocator, "{s}#", .{base}), 0, .{});
    try result.addResource(base, result.root);
    for (result.raw_documents.keys(), result.raw_documents.values()) |uri, value| {
        if (result.metaschemas.contains(uri)) continue;
        const resource = try result.indexNode(value, uri, null, try std.fmt.allocPrint(allocator, "{s}#", .{uri}), 0, .{});
        try result.addResource(uri, resource);
    }
    var index: usize = 0;
    while (index < result.nodes.items.len) : (index += 1) {
        const node = result.nodes.items[index];
        if (node.value.* != .object) continue;
        if (node.value.object.get("$ref")) |reference| node.reference = try result.resolve(node, reference.string);
        if (node.value.object.get("$dynamicRef")) |reference| {
            const target = try result.resolve(node, reference.string);
            node.dynamic_reference = target;
            const uri = try resolveUri(allocator, node.base, reference.string);
            if (std.mem.indexOfScalar(u8, uri, '#')) |hash| {
                const name = try decodeFragment(allocator, uri[hash + 1 ..]);
                if (target.dynamic_anchor) |anchor| {
                    if (std.mem.eql(u8, name, anchor)) node.dynamic_name = anchor;
                }
            }
        }
    }
}

fn knownType(name: []const u8) bool {
    inline for (.{ "null", "boolean", "object", "array", "number", "integer", "string" }) |kind| if (std.mem.eql(u8, name, kind)) return true;
    return false;
}
fn knownVocabulary(name: []const u8) bool {
    inline for (.{ "core", "applicator", "unevaluated", "validation", "meta-data", "format-annotation", "content" }) |vocabulary| if (std.mem.eql(u8, name, "https://json-schema.org/draft/2020-12/vocab/" ++ vocabulary)) return true;
    return false;
}
fn checkNames(allocator: Allocator, value: V) !void {
    if (value != .array) return error.InvalidSchema;
    var seen: std.array_hash_map.String(void) = .empty;
    for (value.array.items) |name| {
        if (name != .string or seen.contains(name.string)) return error.InvalidSchema;
        try seen.put(allocator, name.string, {});
    }
}
fn validAnchor(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "-._", byte) == null) return false;
    return true;
}
fn withoutFragment(uri: []const u8) []const u8 {
    return uri[0 .. std.mem.indexOfScalar(u8, uri, '#') orelse uri.len];
}
fn resolveUri(allocator: Allocator, base: []const u8, reference: []const u8) ![]const u8 {
    if (base.len > 16_384 or reference.len > 16_384) return error.UriLimitExceeded;
    const parsed = std.Uri.parse(base) catch return error.InvalidSchemaUri;
    const sum = std.math.add(usize, base.len, reference.len) catch return error.InputLimitExceeded;
    const capacity = std.math.mul(usize, sum, 2) catch return error.InputLimitExceeded;
    var buffer = try allocator.alloc(u8, std.math.add(usize, capacity, 64) catch return error.InputLimitExceeded);
    @memcpy(buffer[0..reference.len], reference);
    const resolved = std.Uri.resolveInPlace(parsed, reference.len, &buffer) catch return error.InvalidSchemaUri;
    return std.fmt.allocPrint(allocator, "{f}", .{resolved});
}
fn decodeFragment(allocator: Allocator, text: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, text.len);
    var len: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '%') {
            if (text.len - index < 3) return error.InvalidSchemaUri;
            output[len] = std.fmt.parseInt(u8, text[index + 1 ..][0..2], 16) catch return error.InvalidSchemaUri;
            index += 2;
        } else output[len] = text[index];
        len += 1;
    }
    if (!std.unicode.utf8ValidateSlice(output[0..len])) return error.InvalidSchemaUri;
    return output[0..len];
}
fn pointerToken(allocator: Allocator, token: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, token.len);
    var len: usize = 0;
    var index: usize = 0;
    while (index < token.len) : (index += 1) {
        if (token[index] == '~') {
            index += 1;
            if (index == token.len or (token[index] != '0' and token[index] != '1')) return error.UnresolvedReference;
            output[len] = if (token[index] == '0') '~' else '/';
        } else output[len] = token[index];
        len += 1;
    }
    return output[0..len];
}
fn pointerGet(allocator: Allocator, root: *const V, pointer: []const u8) !*const V {
    var current = root;
    var tokens = std.mem.splitScalar(u8, pointer[1..], '/');
    while (tokens.next()) |raw| {
        const token = try pointerToken(allocator, raw);
        current = switch (current.*) {
            .object => current.object.getPtr(token) orelse return error.UnresolvedReference,
            .array => |array| block: {
                if (token.len == 0 or (token.len > 1 and token[0] == '0')) return error.UnresolvedReference;
                for (token) |byte| if (!std.ascii.isDigit(byte)) return error.UnresolvedReference;
                const index = std.fmt.parseInt(usize, token, 10) catch return error.UnresolvedReference;
                if (index >= array.items.len) return error.UnresolvedReference;
                break :block &array.items[index];
            },
            else => return error.UnresolvedReference,
        };
    }
    return current;
}
fn escapeToken(allocator: Allocator, text: []const u8) ![]const u8 {
    var output: std.array_list.Managed(u8) = .init(allocator);
    for (text) |byte| switch (byte) {
        '~' => try output.appendSlice("~0"),
        '/' => try output.appendSlice("~1"),
        else => try output.append(byte),
    };
    return output.items;
}
fn appendLocation(allocator: Allocator, base: []const u8, keyword: []const u8, name: ?[]const u8) ![]const u8 {
    if (name) |key| return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ base, keyword, try escapeToken(allocator, key) });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, keyword });
}

const Evaluation = struct { valid: bool = true, properties: ?[]bool = null, items: ?[]bool = null };
const Context = struct {
    compiled: *const Compiled,
    state: *json.State,
    options: Options,
    work: usize = 0,
    depth: usize = 0,
    path: []core.Segment,
    path_len: usize = 0,
    scope: [256]*Node = undefined,
    scope_len: usize = 0,
    finding: ?Finding = null,

    fn charge(self: *Context, amount: usize) !void {
        if (amount > self.options.max_work - self.work) return error.WorkLimitExceeded;
        self.work += amount;
    }
    fn push(self: *Context, segment: core.Segment) !void {
        if (self.path_len == self.path.len) return error.DepthLimitExceeded;
        self.path[self.path_len] = segment;
        self.path_len += 1;
    }
    fn mark(self: *Context, evaluation: *Evaluation, node: *Node, comptime keyword: []const u8, comptime message: []const u8) !void {
        evaluation.valid = false;
        if (self.finding == null) {
            const allocator = self.state.allocator();
            self.finding = .{ .issue = .{ .code = .schema_validation, .path = try copyPath(allocator, self.path[0..self.path_len]), .message = message }, .keyword = keyword, .schema_location = try appendLocation(allocator, node.location, keyword, null) };
        }
    }
    fn initial(self: *Context, value: V) !Evaluation {
        var result: Evaluation = .{};
        if (value == .object) {
            const flags = try self.state.allocator().alloc(bool, value.object.count());
            @memset(flags, false);
            result.properties = flags;
        }
        if (value == .array) {
            const flags = try self.state.allocator().alloc(bool, value.array.items.len);
            @memset(flags, false);
            result.items = flags;
        }
        return result;
    }
    fn merge(self: *Context, target: *Evaluation, source: Evaluation) !void {
        if (!source.valid) return;
        if (target.properties) |flags| {
            try self.charge(flags.len);
            for (flags, source.properties.?) |*flag, incoming| flag.* = flag.* or incoming;
        }
        if (target.items) |flags| {
            try self.charge(flags.len);
            for (flags, source.items.?) |*flag, incoming| flag.* = flag.* or incoming;
        }
    }
    fn testChild(self: *Context, schema: *const V, value: V, segment: core.Segment) !Evaluation {
        try self.push(segment);
        defer self.path_len -= 1;
        return self.evaluate(self.compiled.child(schema), value);
    }
    fn speculative(self: *Context, schema: *Node, value: V) !Evaluation {
        const saved = self.finding;
        defer self.finding = saved;
        return self.evaluate(schema, value);
    }
    fn numeric(self: *Context, value: V) !numbers.Decimal {
        return numbers.Decimal.parse(self.state.allocator(), value.number_string, self.options.json.numbers);
    }
    fn compareCount(self: *Context, count: usize, bound: V) !std.math.Order {
        // JSON Schema permits arbitrarily large nonnegative integer bounds.
        // Compare exact decimals rather than narrowing them to usize.
        var buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d}", .{count});
        return numbers.Decimal.order(try numbers.Decimal.parse(self.state.allocator(), text, self.options.json.numbers), try self.numeric(bound));
    }
    fn typeMatches(self: *Context, kind: []const u8, value: V) !bool {
        if (std.mem.eql(u8, kind, "integer")) return value == .number_string and (try self.numeric(value)).integer();
        const name: []const u8 = switch (value) {
            .null => "null",
            .bool => "boolean",
            .object => "object",
            .array => "array",
            .string => "string",
            .number_string => "number",
            else => unreachable,
        };
        return std.mem.eql(u8, kind, name);
    }
    fn same(self: *Context, a: V, b: V) anyerror!bool {
        try self.charge(1);
        if (@as(std.meta.Tag(V), a) != @as(std.meta.Tag(V), b)) return false;
        return switch (a) {
            .null => true,
            .bool => a.bool == b.bool,
            .number_string => numbers.Decimal.order(try self.numeric(a), try self.numeric(b)) == .eq,
            .string => block: {
                try self.charge(@min(a.string.len, b.string.len));
                break :block std.mem.eql(u8, a.string, b.string);
            },
            .array => block: {
                if (a.array.items.len != b.array.items.len) break :block false;
                if (self.depth == self.options.max_depth) return error.DepthLimitExceeded;
                self.depth += 1;
                defer self.depth -= 1;
                for (a.array.items, b.array.items) |left, right| if (!try self.same(left, right)) break :block false;
                break :block true;
            },
            .object => block: {
                if (a.object.count() != b.object.count()) break :block false;
                if (self.depth == self.options.max_depth) return error.DepthLimitExceeded;
                self.depth += 1;
                defer self.depth -= 1;
                for (a.object.keys(), a.object.values()) |key, left| {
                    try self.charge(key.len);
                    const right = b.object.get(key) orelse break :block false;
                    if (!try self.same(left, right)) break :block false;
                }
                break :block true;
            },
            else => unreachable,
        };
    }
    fn matches(self: *Context, program: *const patterns.Program, text: []const u8) !bool {
        const units = std.math.add(usize, text.len, 1) catch return error.WorkLimitExceeded;
        const cost = std.math.mul(usize, units, program.workUnits()) catch return error.WorkLimitExceeded;
        try self.charge(cost);
        return program.matches(self.state.allocator(), text);
    }

    fn evaluate(self: *Context, node: *Node, value: V) anyerror!Evaluation {
        try self.charge(1);
        if (self.depth == self.options.max_depth) return error.DepthLimitExceeded;
        self.depth += 1;
        defer self.depth -= 1;
        const old_scope = self.scope_len;
        defer self.scope_len = old_scope;
        if (self.scope_len == 0 or self.scope[self.scope_len - 1] != node.resource) {
            if (self.scope_len == self.scope.len) return error.DepthLimitExceeded;
            self.scope[self.scope_len] = node.resource;
            self.scope_len += 1;
        }
        var result = try self.initial(value);
        if (node.value.* == .bool) {
            if (!node.value.bool) try self.mark(&result, node, "false", "boolean schema rejects this value");
            return result;
        }
        const o = node.value.object;
        if (node.reference) |target| {
            const referenced = try self.evaluate(target, value);
            if (!referenced.valid) result.valid = false;
            try self.merge(&result, referenced);
        }
        if (node.dynamic_reference) |static| {
            var target = static;
            if (node.dynamic_name) |name| {
                for (self.scope[0..self.scope_len]) |resource| {
                    const uri = try std.fmt.allocPrint(self.state.allocator(), "{s}#{s}", .{ resource.base, name });
                    try self.charge(1 + uri.len);
                    if (self.compiled.anchors.get(uri)) |anchor| if (anchor.dynamic_anchor != null) {
                        target = anchor;
                        break;
                    };
                }
            }
            const referenced = try self.evaluate(target, value);
            if (!referenced.valid) result.valid = false;
            try self.merge(&result, referenced);
        }
        if (node.vocabulary.validation) {
            if (o.get("type")) |kind| {
                var valid = false;
                switch (kind) {
                    .string => valid = try self.typeMatches(kind.string, value),
                    .array => |array| for (array.items) |item| {
                        try self.charge(1);
                        if (try self.typeMatches(item.string, value)) {
                            valid = true;
                            break;
                        }
                    },
                    else => unreachable,
                }
                if (!valid) try self.mark(&result, node, "type", "JSON type is not permitted");
            }
            if (o.get("const")) |expected| if (!try self.same(value, expected)) {
                try self.mark(&result, node, "const", "value does not equal the configured constant");
            };
            if (o.get("enum")) |choices| {
                var valid = false;
                for (choices.array.items) |choice| if (try self.same(value, choice)) {
                    valid = true;
                    break;
                };
                if (!valid) try self.mark(&result, node, "enum", "value is not a permitted choice");
            }
            if (value == .number_string) {
                const number = try self.numeric(value);
                inline for (.{ "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum" }) |keyword| if (o.get(keyword)) |bound| {
                    const order = numbers.Decimal.order(number, try self.numeric(bound));
                    const invalid = if (comptime std.mem.eql(u8, keyword, "minimum")) order == .lt else if (comptime std.mem.eql(u8, keyword, "maximum")) order == .gt else if (comptime std.mem.eql(u8, keyword, "exclusiveMinimum")) order != .gt else order != .lt;
                    if (invalid) try self.mark(&result, node, keyword, "number is outside the configured bound");
                };
                if (o.get("multipleOf")) |divisor| {
                    const other = try self.numeric(divisor);
                    const cost = std.math.mul(usize, number.digits.len + other.digits.len, @as(usize, @intCast(@abs(number.exponent - other.exponent))) + 1) catch return error.WorkLimitExceeded;
                    try self.charge(cost);
                    if (!try number.multipleOf(other, self.state.allocator())) try self.mark(&result, node, "multipleOf", "number is not an exact multiple");
                }
            }
            if (value == .string) {
                try self.charge(value.string.len);
                const length = std.unicode.utf8CountCodepoints(value.string) catch unreachable;
                if (o.get("minLength")) |bound| if (try self.compareCount(length, bound) == .lt) {
                    try self.mark(&result, node, "minLength", "string has too few Unicode code points");
                };
                if (o.get("maxLength")) |bound| if (try self.compareCount(length, bound) == .gt) {
                    try self.mark(&result, node, "maxLength", "string has too many Unicode code points");
                };
                if (node.pattern) |*pattern| if (!try self.matches(pattern, value.string)) {
                    try self.mark(&result, node, "pattern", "string does not match the configured pattern");
                };
            }
        }
        // Successful applicators contribute evaluated properties/items at this
        // instance location. Failed/negated/conditional probes never leak marks.
        if (node.vocabulary.applicator) {
            if (o.get("allOf")) |branches| for (branches.array.items) |*schema| {
                const branch = try self.evaluate(self.compiled.child(schema), value);
                if (!branch.valid) result.valid = false;
                try self.merge(&result, branch);
            };
            inline for (.{ "anyOf", "oneOf" }) |keyword| if (o.get(keyword)) |branches| {
                var combined = try self.initial(value);
                var count: usize = 0;
                for (branches.array.items) |*schema| {
                    const branch = try self.speculative(self.compiled.child(schema), value);
                    if (branch.valid) {
                        count += 1;
                        try self.merge(&combined, branch);
                    }
                }
                const valid = if (comptime std.mem.eql(u8, keyword, "oneOf")) count == 1 else count > 0;
                if (valid) try self.merge(&result, combined) else try self.mark(&result, node, keyword, "applicator match count is not satisfied");
            };
            if (o.getPtr("not")) |schema| if ((try self.speculative(self.compiled.child(schema), value)).valid) {
                try self.mark(&result, node, "not", "negated schema matched");
            };
            if (o.getPtr("if")) |condition| {
                const branch = try self.speculative(self.compiled.child(condition), value);
                if (branch.valid) try self.merge(&result, branch);
                const keyword: []const u8 = if (branch.valid) "then" else "else";
                if (o.getPtr(keyword)) |schema| {
                    const selected = try self.evaluate(self.compiled.child(schema), value);
                    if (!selected.valid) result.valid = false;
                    try self.merge(&result, selected);
                }
            }
        }
        if (value == .object) try self.evaluateObject(node, value, &result);
        if (value == .array) try self.evaluateArray(node, value, &result);
        return result;
    }

    fn evaluateObject(self: *Context, node: *Node, value: V, result: *Evaluation) !void {
        const o = node.value.object;
        const object = value.object;
        if (node.vocabulary.validation) {
            if (o.get("minProperties")) |bound| if (try self.compareCount(object.count(), bound) == .lt) {
                try self.mark(result, node, "minProperties", "object has too few properties");
            };
            if (o.get("maxProperties")) |bound| if (try self.compareCount(object.count(), bound) == .gt) {
                try self.mark(result, node, "maxProperties", "object has too many properties");
            };
            if (o.get("required")) |required| for (required.array.items) |name| {
                try self.charge(name.string.len);
                if (!object.contains(name.string)) {
                    try self.push(.{ .field = name.string });
                    defer self.path_len -= 1;
                    try self.mark(result, node, "required", "required property is missing");
                }
            };
            if (o.get("dependentRequired")) |dependencies| for (dependencies.object.keys(), dependencies.object.values()) |trigger, names| {
                try self.charge(trigger.len);
                if (!object.contains(trigger)) continue;
                for (names.array.items) |name| {
                    try self.charge(name.string.len);
                    if (!object.contains(name.string)) {
                        try self.push(.{ .field = name.string });
                        defer self.path_len -= 1;
                        try self.mark(result, node, "dependentRequired", "dependent property is missing");
                    }
                }
            };
        }
        if (node.vocabulary.applicator) {
            if (o.get("dependentSchemas")) |dependencies| for (dependencies.object.keys(), dependencies.object.values()) |trigger, *schema| {
                try self.charge(trigger.len);
                if (!object.contains(trigger)) continue;
                const branch = try self.evaluate(self.compiled.child(schema), value);
                if (!branch.valid) result.valid = false;
                try self.merge(result, branch);
            };
            for (object.keys(), object.values(), 0..) |key, item, index| {
                try self.charge(1);
                try self.charge(key.len);
                var matched = false;
                if (o.get("properties")) |properties| if (properties.object.getPtr(key)) |schema| {
                    matched = true;
                    const child = try self.testChild(schema, item, .{ .field = key });
                    if (!child.valid) result.valid = false;
                    result.properties.?[index] = true;
                };
                if (o.get("patternProperties")) |properties| for (properties.object.keys(), properties.object.values()) |pattern, *schema| {
                    const program = node.property_patterns.getPtr(pattern).?;
                    if (!try self.matches(program, key)) continue;
                    matched = true;
                    const child = try self.testChild(schema, item, .{ .field = key });
                    if (!child.valid) result.valid = false;
                    result.properties.?[index] = true;
                };
                if (!matched) if (o.getPtr("additionalProperties")) |schema| {
                    const child = try self.testChild(schema, item, .{ .field = key });
                    if (!child.valid) result.valid = false;
                    result.properties.?[index] = true;
                };
                if (o.getPtr("propertyNames")) |schema| {
                    const child = try self.testChild(schema, .{ .string = key }, .{ .field = key });
                    if (!child.valid) result.valid = false;
                }
            }
        }
        if (node.vocabulary.unevaluated) {
            if (o.getPtr("unevaluatedProperties")) |schema| for (object.keys(), object.values(), 0..) |key, item, index| {
                if (result.properties.?[index]) continue;
                const child = try self.testChild(schema, item, .{ .field = key });
                if (!child.valid) result.valid = false;
                result.properties.?[index] = true;
            };
        }
    }
    fn evaluateArray(self: *Context, node: *Node, value: V, result: *Evaluation) !void {
        const o = node.value.object;
        const items = value.array.items;
        if (node.vocabulary.validation) {
            if (o.get("minItems")) |bound| if (try self.compareCount(items.len, bound) == .lt) {
                try self.mark(result, node, "minItems", "array has too few items");
            };
            if (o.get("maxItems")) |bound| if (try self.compareCount(items.len, bound) == .gt) {
                try self.mark(result, node, "maxItems", "array has too many items");
            };
            if (o.get("uniqueItems")) |unique| if (unique.bool) {
                outer: for (items, 0..) |left, index| for (items[0..index]) |right| if (try self.same(left, right)) {
                    try self.mark(result, node, "uniqueItems", "array items must be unique");
                    break :outer;
                };
            };
        }
        if (node.vocabulary.applicator) {
            var prefix: usize = 0;
            if (o.get("prefixItems")) |schemas| {
                prefix = @min(schemas.array.items.len, items.len);
                for (schemas.array.items[0..prefix], items[0..prefix], 0..) |*schema, item, index| {
                    const child = try self.testChild(schema, item, .{ .index = index });
                    if (!child.valid) result.valid = false;
                    result.items.?[index] = true;
                }
            }
            if (o.getPtr("items")) |schema| for (items[prefix..], prefix..) |item, index| {
                const child = try self.testChild(schema, item, .{ .index = index });
                if (!child.valid) result.valid = false;
                result.items.?[index] = true;
            };
            if (o.getPtr("contains")) |schema| {
                var matched = try self.state.allocator().alloc(bool, items.len);
                @memset(matched, false);
                var count: usize = 0;
                for (items, 0..) |item, index| {
                    try self.push(.{ .index = index });
                    defer self.path_len -= 1;
                    const branch = try self.speculative(self.compiled.child(schema), item);
                    if (branch.valid) {
                        count += 1;
                        matched[index] = true;
                    }
                }
                var valid = if (o.get("minContains")) |bound| try self.compareCount(count, bound) != .lt else count >= 1;
                if (o.get("maxContains")) |bound| if (try self.compareCount(count, bound) == .gt) {
                    valid = false;
                };
                if (valid) {
                    for (matched, result.items.?) |flag, *item| item.* = item.* or flag;
                } else try self.mark(result, node, "contains", "matching array item count is outside the configured bounds");
            }
        }
        if (node.vocabulary.unevaluated) {
            if (o.getPtr("unevaluatedItems")) |schema| for (items, 0..) |item, index| {
                if (result.items.?[index]) continue;
                const child = try self.testChild(schema, item, .{ .index = index });
                if (!child.valid) result.valid = false;
                result.items.?[index] = true;
            };
        }
    }
};

fn copyPath(allocator: Allocator, path: []const core.Segment) ![]const core.Segment {
    const copy = try allocator.dupe(core.Segment, path);
    for (copy) |*segment| if (segment.* == .field) {
        segment.field = try allocator.dupe(u8, segment.field);
    };
    return copy;
}
