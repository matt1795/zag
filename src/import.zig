const std = @import("std");
const builtin = @import("builtin");
const net = @import("net");
const ssl = @import("ssl");
const http = @import("http");
const Uri = @import("uri").Uri;
const tar = @import("tar.zig");
const zzz = @import("zzz");

const Allocator = std.mem.Allocator;
const gzipStream = std.compress.gzip.gzipStream;

const github_pem = @embedFile("github-com-chain.pem");

pub const Import = struct {
    name: []const u8,
    root: []const u8,
    src: Source,
    integrity: ?Integrity = null,

    const Self = @This();
    const Hasher = std.crypto.hash.blake2.Blake2b128;

    const Source = union(enum) {
        github: Github,
        url: []const u8,

        const Github = struct {
            user: []const u8,
            repo: []const u8,
            ref: []const u8,
        };

        fn addToZNode(source: Source, root: *zzz.ZNode, tree: anytype) !void {
            if (@typeInfo(@TypeOf(tree)) != .Pointer) {
                @compileError("tree must be pointer");
            }

            switch (source) {
                .github => |github| {
                    var node = try tree.addNode(root, .{ .String = "github" });
                    var repo_key = try tree.addNode(node, .{ .String = "repo" });
                    _ = try tree.addNode(repo_key, .{ .String = github.repo });
                    var user_key = try tree.addNode(node, .{ .String = "user" });
                    _ = try tree.addNode(user_key, .{ .String = github.user });
                    var ref_key = try tree.addNode(node, .{ .String = "ref" });
                    _ = try tree.addNode(ref_key, .{ .String = github.ref });
                },
                .url => |url| {
                    var node = try tree.addNode(root, .{ .String = "url" });
                    _ = try tree.addNode(node, .{ .String = url });
                },
            }
        }

        fn fromZNode(node: *const zzz.ZNode) !Source {
            const key = try getZNodeString(node);
            return if (std.mem.eql(u8, "github", key)) blk: {
                var repo: ?[]const u8 = null;
                var user: ?[]const u8 = null;
                var ref: ?[]const u8 = null;

                var child = node.*.child;
                while (child) |elem| : (child = child.?.sibling) {
                    const gh_key = try getZNodeString(elem);

                    if (std.mem.eql(u8, "repo", gh_key)) {
                        repo = try getZNodeString(elem.child orelse return error.MissingRepo);
                    } else if (std.mem.eql(u8, "user", gh_key)) {
                        user = try getZNodeString(elem.child orelse return error.MissingUser);
                    } else if (std.mem.eql(u8, "ref", gh_key)) {
                        ref = try getZNodeString(elem.child orelse return error.MissingRef);
                    } else {
                        return error.UnknownKey;
                    }
                }

                break :blk Source{
                    .github = .{
                        .repo = repo orelse return error.MissingRepo,
                        .user = user orelse return error.MissingUser,
                        .ref = ref orelse return error.MissingRef,
                    },
                };
            } else if (std.mem.eql(u8, "url", key))
                Source{ .url = try getZNodeString(node.*.child orelse return error.MissingUrl) }
            else {
                return error.UnknownKey;
            };
        }
    };

    const Integrity = struct {
        hash_type: HashType,
        digest: []const u8,

        const HashType = @TagType(HashEngine);

        // TODO: compiler bug if we try to do smart comptime stuff
        const HashEngine = union(enum) {
            md5: std.crypto.hash.Md5,
            sha1: std.crypto.hash.Sha1,
            sha224: std.crypto.hash.sha2.Sha224,
            sha256: std.crypto.hash.sha2.Sha256,
            sha384: std.crypto.hash.sha2.Sha384,
            sha512: std.crypto.hash.sha2.Sha512,
            blake2b512: std.crypto.hash.blake2.Blake2b512,
        };

        fn fromZNode(node: *const zzz.ZNode) !Integrity {
            const key = try getZNodeString(node);

            const hash_type_str = try getZNodeString(node);
            const hash_type = inline for (std.meta.fields(HashType)) |field| {
                if (std.mem.eql(u8, field.name, hash_type_str))
                    break @field(HashType, field.name);
            } else return error.UnknownHashType;

            const digest = try getZNodeString(node.*.child orelse return error.MissingDigest);

            return Integrity{
                .hash_type = hash_type,
                .digest = digest,
            };
        }
    };

    const Checker = struct {
        engine: ?Integrity.HashEngine,
        connection: Connection.Reader,

        const Self = @This();
        const ReadError = Connection.Reader.Error;
        pub const Reader = std.io.Reader(*Checker, ReadError, read);

        fn init(integrity: ?Integrity, connection: Connection.Reader) !Checker {
            return Checker{
                .connection = connection,
                .engine = if (integrity) |integ| switch (integ.hash_type) {
                    .md5 => Integrity.HashEngine{ .md5 = std.crypto.hash.Md5.init(.{}) },
                    .sha1 => Integrity.HashEngine{ .sha1 = std.crypto.hash.Sha1.init(.{}) },
                    .sha224 => Integrity.HashEngine{ .sha224 = std.crypto.hash.sha2.Sha224.init(.{}) },
                    .sha256 => Integrity.HashEngine{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) },
                    .sha384 => Integrity.HashEngine{ .sha384 = std.crypto.hash.sha2.Sha384.init(.{}) },
                    .sha512 => Integrity.HashEngine{ .sha512 = std.crypto.hash.sha2.Sha512.init(.{}) },
                    .blake2b512 => Integrity.HashEngine{ .blake2b512 = std.crypto.hash.blake2.Blake2b512.init(.{}) },
                } else null,
            };
        }

        fn read(self: *Checker, buf: []u8) ReadError!usize {
            const n = try self.connection.read(buf);

            if (self.engine) |engine| {
                switch (engine) {
                    .md5 => self.engine.?.md5.update(buf[0..n]),
                    .sha1 => self.engine.?.sha1.update(buf[0..n]),
                    .sha224 => self.engine.?.sha224.update(buf[0..n]),
                    .sha256 => self.engine.?.sha256.update(buf[0..n]),
                    .sha384 => self.engine.?.sha384.update(buf[0..n]),
                    .sha512 => self.engine.?.sha512.update(buf[0..n]),
                    .blake2b512 => self.engine.?.blake2b512.update(buf[0..n]),
                }
            }

            return n;
        }

        fn reader(self: *Checker) Reader {
            return .{ .context = self };
        }

        fn compareDigest(engine: anytype, digest: []const u8) !bool {
            var out: [@TypeOf(engine.*).digest_length]u8 = undefined;
            var fmted: [@TypeOf(engine.*).digest_length * 2]u8 = undefined;

            engine.final(&out);
            var fixed_buffer = std.io.fixedBufferStream(&fmted);
            for (out) |i| try std.fmt.format(fixed_buffer.writer(), "{x:0>2}", .{i});

            return std.mem.eql(u8, &fmted, digest);
        }

        fn check(self: *Checker, digest: ?[]const u8) !void {
            // TODO: make generic for when there are more
            var out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            var fmted: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
            if (self.engine) |engine| {
                if (digest == null) return error.MissingDigest;
                if (!switch (engine) {
                    .md5 => try compareDigest(&self.engine.?.md5, digest.?),
                    .sha1 => try compareDigest(&self.engine.?.sha1, digest.?),
                    .sha224 => try compareDigest(&self.engine.?.sha224, digest.?),
                    .sha256 => try compareDigest(&self.engine.?.sha256, digest.?),
                    .sha384 => try compareDigest(&self.engine.?.sha384, digest.?),
                    .sha512 => try compareDigest(&self.engine.?.sha512, digest.?),
                    .blake2b512 => try compareDigest(&self.engine.?.blake2b512, digest.?),
                }) return error.FailedHash;
            }
        }
    };

    fn getZNodeString(node: *const zzz.ZNode) ![]const u8 {
        return switch (node.value) {
            .String => |str| str,
            else => return error.NotAString,
        };
    }

    pub fn fromZNode(node: *const zzz.ZNode) !Import {
        const name = switch (node.value) {
            .String => |str| str,
            else => return error.MissingName,
        };

        var root_path: ?[]const u8 = null;
        var src: ?Source = null;
        var integrity: ?Integrity = null;

        var child = node.*.child;
        while (child) |elem| : (child = child.?.sibling) {
            const key = try getZNodeString(elem);

            if (std.mem.eql(u8, "root", key)) {
                root_path = if (elem.child) |child_node| try getZNodeString(child_node) else null;
            } else if (std.mem.eql(u8, "src", key)) {
                src = try Source.fromZNode(elem.child orelse return error.MissingSourceType);
            } else if (std.mem.eql(u8, "integrity", key)) {
                integrity = try Integrity.fromZNode(elem.child orelse return error.MissingHashType);
            } else {
                return error.UnknownKey;
            }
        }

        return Import{
            .name = name,
            .root = root_path orelse "src/main.zig",
            .src = src orelse return error.MissingSource,
            .integrity = integrity,
        };
    }

    pub fn addToZNode(self: Self, root: *zzz.ZNode, tree: anytype) !void {
        if (@typeInfo(@TypeOf(tree)) != .Pointer) {
            @compileError("tree must be pointer");
        }

        const import = try tree.addNode(root, .{ .String = self.name });
        const root_path = try tree.addNode(import, .{ .String = "root" });
        _ = try tree.addNode(root_path, .{ .String = self.root });

        const src = try tree.addNode(import, .{ .String = "src" });
        try self.src.addToZNode(src, tree);

        if (self.integrity) |integrity| {
            const integ_node = try tree.addNode(import, .{ .String = "integrity" });
            const hash_type = try tree.addNode(integ_node, .{
                .String = inline for (std.meta.fields(Integrity.HashType)) |field| {
                    if (integrity.hash_type == @field(Integrity.HashType, field.name)) break field.name;
                } else unreachable,
            });
            _ = try tree.addNode(hash_type, .{ .String = integrity.digest });
        }
    }

    pub fn urlToSource(url: []const u8) !Source {
        const prefix = "https://github.com/";
        if (!std.mem.startsWith(u8, url, prefix)) return error.SorryOnlyGithubOverHttps;

        var it = std.mem.tokenize(url[prefix.len..], "/");
        const user = it.next() orelse return error.MissingUser;
        const repo = it.next() orelse return error.MissingRepo;
        return Source{
            .github = .{
                .user = user,
                .repo = repo,
                .ref = "master",
            },
        };
    }

    pub fn toUrl(self: Import, allocator: *Allocator) ![]const u8 {
        return switch (self.src) {
            .github => |github| try std.mem.join(allocator, "/", &[_][]const u8{
                "https://api.github.com/repos",
                github.user,
                github.repo,
                "tarball",
                github.ref,
            }),
            .url => |url| try allocator.dupe(u8, url),
        };
    }

    pub fn path(self: Self, allocator: *Allocator, base_path: []const u8) ![]const u8 {
        const file_proto = "file://";
        switch (self.src) {
            .url => |url| {
                if (std.mem.startsWith(u8, url, file_proto))
                    return url[file_proto.len..];
            },
            else => {},
        }

        const digest = try self.hash();
        return try std.fs.path.join(allocator, &[_][]const u8{ base_path, &digest });
    }

    pub fn hash(self: Self) ![Hasher.digest_length * 2]u8 {
        var tree = zzz.ZTree(1, 100){};
        var root = try tree.addNode(null, .Null);
        try self.src.addToZNode(root, &tree);

        var buf: [std.mem.page_size]u8 = undefined;
        var digest: [Hasher.digest_length]u8 = undefined;
        var ret: [Hasher.digest_length * 2]u8 = undefined;
        var fixed_buffer = std.io.fixedBufferStream(&buf);

        try root.stringify(fixed_buffer.writer());
        Hasher.hash(fixed_buffer.getWritten(), &digest, .{});

        // TODO: format properly
        const lookup = [_]u8{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };
        for (digest) |val, i| {
            ret[2 * i] = lookup[val >> 4];
            ret[(2 * i) + 1] = lookup[@truncate(u4, val)];
        }

        return ret;
    }

    pub fn fetch(self: Self, allocator: *Allocator, deps_path: []const u8) !void {
        // don't need to fetch if it's a file://
        switch (self.src) {
            .url => |url| {
                if (std.mem.startsWith(u8, url, "file://")) {
                    if (self.integrity != null)
                        std.log.warn("integrity is not checked for '{}', importing directly through the filesystem", .{self.name});

                    return;
                }
            },
            else => {},
        }
        var source = try HttpsSource.init(allocator, self);
        defer source.deinit();

        var checker = try Checker.init(self.integrity, source.reader());
        var gzip = try gzipStream(allocator, checker.reader());
        defer gzip.deinit();

        var deps_dir = try std.fs.cwd().makeOpenPath(deps_path, .{ .access_sub_paths = true });
        defer deps_dir.close();

        const digest = try self.hash();
        var dest_dir = try deps_dir.makeOpenPath(&digest, .{ .access_sub_paths = true });

        try tar.instantiate(allocator, dest_dir, gzip.reader(), 1);
        checker.check(if (self.integrity) |integ| integ.digest else null) catch |err| {
            if (err == error.FailedHash) {
                // delete dest_dir and its contents
                dest_dir.close();
                try deps_dir.deleteTree(&digest);
            }

            return err;
        };

        defer dest_dir.close();
    }

    pub fn getBranchHead(self: Self, allocator: *Allocator) !?[]const u8 {
        var source = try HttpsSource.init(allocator, self);
        defer source.deinit();

        var gzip = try gzipStream(allocator, source.reader());
        defer gzip.deinit();

        const header = try gzip.reader().readStruct(tar.Header);
        if (header.typeflag != .pax_global) return null;
        const body = try gzip.reader().readUntilDelimiterAlloc(
            allocator,
            0,
            try std.fmt.parseUnsigned(usize, &header.size, 8),
        );

        const commit_key = "comment=";
        const commit_idx = (std.mem.indexOf(u8, body, commit_key) orelse return null) + commit_key.len;

        const end_idx = for (body[commit_idx..]) |c, i| {
            switch (c) {
                'A'...'F', 'a'...'f', '0'...'9' => continue,
                else => break commit_idx + i,
            }
        } else body.len;

        return try allocator.dupe(u8, body[commit_idx..end_idx]);
    }
};

const Connection = struct {
    ssl_client: ssl.Client,
    ssl_socket: SslStream,
    socket: net.Socket,
    socket_reader: net.Socket.Reader,
    socket_writer: net.Socket.Writer,
    http_buf: [std.mem.page_size]u8,
    http_client: HttpClient,
    window: []const u8,

    const SslStream = ssl.Stream(*net.Socket.Reader, *net.Socket.Writer);
    const HttpClient = http.base.client.BaseClient(SslStream.DstInStream, SslStream.DstOutStream);
    const Self = @This();

    pub fn init(allocator: *Allocator, hostname: [:0]const u8, port: u16, x509: *ssl.x509.Minimal) !*Self {
        var ret = try allocator.create(Self);
        errdefer allocator.destroy(ret);

        ret.window = &[_]u8{};
        ret.ssl_client = ssl.Client.init(x509.getEngine());
        ret.ssl_client.relocate();
        try ret.ssl_client.reset(hostname, false);

        ret.socket = try net.connectToHost(allocator, hostname, port, .tcp);
        errdefer ret.socket.close();

        ret.socket_reader = ret.socket.reader();
        ret.socket_writer = ret.socket.writer();

        ret.ssl_socket = ssl.initStream(
            ret.ssl_client.getEngine(),
            &ret.socket_reader,
            &ret.socket_writer,
        );
        errdefer ret.ssl_socket.close catch {};

        ret.http_client = http.base.client.create(
            &ret.http_buf,
            ret.ssl_socket.inStream(),
            ret.ssl_socket.outStream(),
        );

        return ret;
    }

    pub fn deinit(self: *Self) void {
        self.ssl_socket.close() catch {};
        self.socket.close();
    }

    pub const Reader = HttpClient.PayloadReader;

    pub fn reader(self: *Self) Reader {
        return self.http_client.reader();
    }
};

const HttpsSource = struct {
    allocator: *Allocator,
    trust_anchor: ssl.TrustAnchorCollection,
    x509: ssl.x509.Minimal,
    connection: *Connection,

    const Self = @This();

    pub fn init(allocator: *Allocator, import: Import) !Self {
        var url = try import.toUrl(allocator);
        defer allocator.free(url);

        var trust_anchor = ssl.TrustAnchorCollection.init(allocator);
        errdefer trust_anchor.deinit();

        switch (builtin.os.tag) {
            .linux => pem: {
                const file = std.fs.openFileAbsolute("/etc/ssl/cert.pem", .{ .read = true }) catch |err| {
                    if (err == error.FileNotFound) {
                        try trust_anchor.appendFromPEM(github_pem);
                        break :pem;
                    } else return err;
                };
                defer file.close();

                const certs = try file.readToEndAlloc(allocator, 500000);
                defer allocator.free(certs);

                try trust_anchor.appendFromPEM(certs);
            },
            else => {
                try trust_anchor.appendFromPEM(github_pem);
            },
        }

        var x509 = ssl.x509.Minimal.init(trust_anchor);

        var conn: *Connection = undefined;
        redirect: while (true) {
            const uri = try Uri.parse(url, true);
            const port = uri.port orelse 443;

            if (!std.mem.eql(u8, uri.scheme, "https")) {
                return if (uri.scheme.len == 0)
                    error.PutQuotesAroundUrl
                else
                    error.HttpsOnly;
            }

            const hostname = try std.cstr.addNullByte(allocator, uri.host.name);
            defer allocator.free(hostname);

            conn = try Connection.init(allocator, hostname, port, &x509);
            try conn.http_client.writeStatusLine("GET", uri.path);
            try conn.http_client.writeHeaderValue("Host", hostname);
            try conn.http_client.writeHeaderValue("User-Agent", "gyro");
            try conn.http_client.writeHeaderValue("Accept", "*/*");
            try conn.http_client.finishHeaders();
            try conn.ssl_socket.flush();

            var redirect = false;
            while (try conn.http_client.next()) |event| {
                switch (event) {
                    .status => |status| switch (status.code) {
                        200 => {},
                        302 => redirect = true,
                        else => {
                            std.log.err("got an HTTP return code: {}", .{status.code});
                            return error.HttpFailed;
                        },
                    },
                    .header => |header| {
                        if (redirect and std.mem.eql(u8, "location", header.name)) {
                            allocator.free(url);
                            url = try allocator.dupe(u8, header.value);
                            conn.deinit();
                            continue :redirect;
                        }
                    },
                    .head_done => break :redirect,
                    else => |val| std.debug.print("got other: {}\n", .{val}),
                }
            }
        }

        std.log.info("fetching {}", .{url});

        return Self{
            .allocator = allocator,
            .trust_anchor = trust_anchor,
            .x509 = x509,
            .connection = conn,
        };
    }

    pub fn deinit(self: *Self) void {
        self.connection.deinit();
        self.trust_anchor.deinit();
    }

    pub fn reader(self: *Self) Connection.Reader {
        return self.connection.reader();
    }
};
