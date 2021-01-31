const std = @import("std");
const Dependency = @import("Dependency.zig");
const Lockfile = @import("Lockfile.zig");

const Self = @This();
const Allocator = std.mem.Allocator;
const DepQueue = std.TailQueue(struct {
    from: *Node,
    dep: *Dependency,
});

arena: std.heap.ArenaAllocator,
node_pool: std.ArrayList(*Node),
root: Node,

const Node = struct {
    entry: *const Lockfile.Entry,
    depth: u32,
    edges: std.ArrayListUnmanaged(*Edge),
};

const Edge = struct {
    from: *Node,
    to: *Node,
    dep: *const Dependency,
};

pub fn generate(
    gpa: *Allocator,
    lockfile: *Lockfile,
    deps: std.ArrayList(Dependency),
) !*Self {
    var ret = try gpa.create(Self);
    ret.* = Self{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .node_pool = std.ArrayList(*Node).init(gpa),
        .root = .{
            .entry = undefined,
            .depth = 0,
            .edges = std.ArrayListUnmanaged(*Edge){},
        },
    };
    errdefer ret.destroy();

    var queue = DepQueue{};
    defer while (queue.popFirst()) |node| gpa.destroy(node);

    var init_deps = try ret.arena.allocator.dupe(Dependency, deps.items);
    for (init_deps) |*dep| {
        var node = try gpa.create(DepQueue.Node);
        node.data = .{
            .from = &ret.root,
            .dep = dep,
        };

        queue.append(node);
    }

    while (queue.popFirst()) |q_node| {
        defer gpa.destroy(q_node);

        const entry = try q_node.data.dep.resolve(&ret.arena, lockfile);
        const node = for (ret.node_pool.items) |node| {
            if (node.entry == entry) {
                node.depth = std.math.max(node.depth, q_node.data.from.depth + 1);
                break node;
            }
        } else blk: {
            const ptr = try ret.arena.allocator.create(Node);
            ptr.* = Node{
                .entry = entry,
                .depth = q_node.data.from.depth + 1,
                .edges = std.ArrayListUnmanaged(*Edge){},
            };

            try ret.node_pool.append(ptr);
            const dependencies = try entry.getDeps(&ret.arena);
            for (dependencies) |*dep| {
                var new_node = try gpa.create(DepQueue.Node);
                new_node.data = .{ .from = ptr, .dep = dep };
                queue.append(new_node);
            }

            break :blk ptr;
        };

        var edge = try ret.arena.allocator.create(Edge);
        edge.* = Edge{
            .from = q_node.data.from,
            .to = node,
            .dep = q_node.data.dep,
        };

        try q_node.data.from.edges.append(gpa, edge);
        try ret.validate();
    }

    return ret;
}

fn validate(self: Self) !void {
    for (self.node_pool.items) |node| {
        for (node.edges.items) |edge| {
            if (node.depth >= edge.to.depth) return error.CircularDependency;
        }
    }
}

pub fn destroy(self: *Self) void {
    const gpa = self.arena.child_allocator;
    self.root.edges.deinit(gpa);

    for (self.node_pool.items) |node| node.edges.deinit(gpa);
    self.node_pool.deinit();

    self.arena.deinit();
    gpa.destroy(self);
}

pub fn assemblePkgs(self: *Self, seed: std.build.Pkg) ![]std.build.Pkg {
    var ret = try self.arena.allocator.alloc(std.build.Pkg, self.root.edges.items.len + 1);
    ret[0] = seed;
    for (ret[1..]) |*pkg, i| {
        pkg.* = try recursiveBuildPkg(&self.arena, self.root.edges.items[i]);
    }

    return ret;
}

fn recursiveBuildPkg(arena: *std.heap.ArenaAllocator, edge: *Edge) anyerror!std.build.Pkg {
    var ret = std.build.Pkg{
        .name = edge.dep.alias,
        .path = try edge.to.entry.getRootPath(arena),
        .dependencies = null,
    };

    if (edge.to.edges.items.len > 0) {
        var pkgs = try arena.allocator.alloc(std.build.Pkg, edge.to.edges.items.len);
        for (pkgs) |*pkg, i| {
            pkg.* = try recursiveBuildPkg(arena, edge.to.edges.items[i]);
        }

        ret.dependencies = pkgs;
    }

    return ret;
}

pub fn printZig(self: *Self, writer: anytype) !void {
    try writer.writeAll(
        \\const std = @import("std");
        \\const build = std.build;
        \\
        \\pub fn addAllTo(artifact: *build.LibExeObjStep) void {
        \\    for (packages) |pkg| {
        \\        artifact.addPackage(pkg);
        \\    }
        \\}
        \\
        \\
    );

    if (self.root.edges.items.len > 0) {
        try writer.writeAll("pub const pkgs = struct {");

        for (self.root.edges.items) |edge| {
            try writer.writeAll("\n");

            try indent(0, writer);
            try writer.print("pub const {s} = build.Pkg{{\n", .{
                std.zig.fmtId(edge.dep.alias),
            });

            try self.recursivePrintZig(0, edge, writer);

            try indent(0, writer);
            try writer.writeAll("};\n");
        }

        try writer.writeAll("};\n\n");

        try writer.writeAll("pub const packages = &[_]build.Pkg{\n");

        for (self.root.edges.items) |edge| {
            try indent(0, writer);
            try writer.print("pkgs.{},\n", .{
                std.zig.fmtId(edge.dep.alias),
            });
        }

        try writer.writeAll("};\n");
    } else {
        try writer.writeAll("pub const pkgs = struct {};\n\n");
        try writer.writeAll("pub const packages = &[_]build.Pkg{};\n");
    }
}

fn indent(depth: usize, writer: anytype) !void {
    try writer.writeByteNTimes(' ', 4 * (depth + 1));
}

fn recursivePrintZig(
    self: *Self,
    depth: usize,
    edge: *const Edge,
    writer: anytype,
) anyerror!void {
    if (depth != 0) {
        try indent(depth, writer);
        try writer.writeAll("build.Pkg{\n");
    }

    try indent(depth + 1, writer);
    try writer.print(".name = \"{s}\",\n", .{
        std.zig.fmtEscapes(edge.dep.alias),
    });

    try indent(depth + 1, writer);
    try writer.print(".path = \"{s}\",\n", .{
        std.zig.fmtEscapes(try edge.to.entry.getRootPath(&self.arena)),
    });

    if (edge.to.edges.items.len > 0) {
        try indent(depth + 1, writer);
        try writer.writeAll(".dependencies = &[_]build.Pkg{\n");

        for (edge.to.edges.items) |e| {
            try self.recursivePrintZig(depth + 2, e, writer);
        }

        try indent(depth + 1, writer);
        try writer.writeAll("},\n");
    }

    if (depth != 0) {
        try indent(depth, writer);
        try writer.writeAll("},\n");
    }
}
