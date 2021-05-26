const std = @import("std");
const Message = @import("message.zig").Message;

fn sigemptyset(set: *std.os.sigset_t) void {
    for (set) |*val| {
        val.* = 0;
    }
}

const InnerPollFdList = std.ArrayList(std.os.pollfd);

const PollFdList = struct {
    inner_pollfd_list: InnerPollFdList,

    const Self = @This();

    pub fn init(allocator: *std.mem.Allocator) Self {
        return Self{
            .inner_pollfd_list = InnerPollFdList.init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.inner_pollfd_list.deinit();
    }

    pub fn addFd(self: *Self, fd: std.os.fd_t) !void {
        try self.inner_pollfd_list.append(std.os.pollfd{
            .fd = fd,
            .events = std.os.POLLIN,
            .revents = 0,
        });
    }

    pub fn pollOnce(self: Self) !usize {
        std.log.info("polling {d} sockets", .{self.inner_pollfd_list.items.len});
        return try std.os.poll(self.inner_pollfd_list.items, -1);
    }
};

const ClientState = struct {
    address: std.net.Address,
    stream: std.net.Stream,
    nick: ?[]const u8 = null,

    const Self = @This();

    pub fn onMessage(self: *Self, message: Message) !void {
        switch (message.command) {
            .NICK => {
                std.log.info("set nick to {s}", .{message.params});
                self.nick = message.params;

                try self.stream.writer().print("001 AAAA :Welcome to sex, {s}\r\n", .{self.nick});
            },
            else => {
                std.log.info("ignored command {}", .{message.command});
            },
        }
    }
};

const ClientStateMap = std.AutoHashMap(std.os.fd_t, *ClientState);

const State = struct {
    allocator: *std.mem.Allocator,
    sockets: *PollFdList,
    server: *std.net.StreamServer,
    client_state_map: ClientStateMap,

    const Self = @This();

    pub fn init(
        allocator: *std.mem.Allocator,
        server: *std.net.StreamServer,
        sockets: *PollFdList,
    ) Self {
        return Self{
            .sockets = sockets,
            .server = server,
            .allocator = allocator,
            .client_state_map = ClientStateMap.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.sockets.deinit();

        var it = self.client_state_map.iterator();
        while (it.next()) |entry| {
            self.allocator.destroy(entry.value);
        }

        self.client_state_map.deinit();
    }

    pub fn onNewClient(self: *Self) !void {
        var conn = try self.server.accept();
        std.log.info("new client fd={d}", .{conn.stream.handle});
        try self.sockets.addFd(conn.stream.handle);

        var state_ptr = try self.allocator.create(ClientState);
        state_ptr.* = .{
            .address = conn.address,
            .stream = conn.stream,
        };
        try self.client_state_map.put(conn.stream.handle, state_ptr);
    }

    pub fn onClientMessage(self: *Self, client_fd: std.os.fd_t) !void {
        var buf: [2048]u8 = undefined;
        var sock = std.net.Stream{ .handle = client_fd };
        const read = try sock.read(&buf);
        if (read == 0) return error.Closed;
        const message_data = buf[0..read];
        std.log.info("client fd={d} sent message: '{s}'", .{ client_fd, message_data });

        var state = self.client_state_map.get(client_fd).?;

        var it = std.mem.split(message_data, "\r\n");
        while (it.next()) |line| {
            if (line.len == 0) continue;

            // parse message_data into message struct
            const message = try Message.parse(line);
            std.log.info("parsed message: {}", .{message});

            std.log.info("state pre: {}", .{state});
            try state.onMessage(message);
            std.log.info("state post: {}", .{state});
        }
    }
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = &gpa.allocator;

    std.log.info("main!", .{});

    // setup signalfd for things like ctrl-c (because we're good citizens of city 17)
    var mask: std.os.sigset_t = undefined;
    sigemptyset(&mask);
    std.os.linux.sigaddset(&mask, std.os.SIGTERM);
    std.os.linux.sigaddset(&mask, std.os.SIGINT);
    _ = std.os.linux.sigprocmask(std.os.SIG_BLOCK, &mask, null);

    const signal_fd = try std.os.signalfd(-1, &mask, 0);
    defer std.os.close(signal_fd);
    std.log.info("opened signalfd at fd {d}", .{signal_fd});

    // setup tcp server socket
    var server = std.net.StreamServer.init(.{
        .reuse_address = true,
    });
    defer server.deinit();

    var addr = try std.net.Address.parseIp4("0.0.0.0", 6667);
    try server.listen(addr);

    std.log.info("opened server in addr {s} on fd {d}", .{ addr, server.sockfd });

    var sockets = PollFdList.init(allocator);
    try sockets.addFd(server.sockfd.?);
    try sockets.addFd(signal_fd);

    var state = State.init(allocator, &server, &sockets);
    defer state.deinit();

    while (true) {
        const available = try sockets.pollOnce();
        std.debug.assert(available > 0);

        for (sockets.inner_pollfd_list.items) |pollfd, idx| {
            if (pollfd.revents == 0) continue;
            std.log.info("fd {d} is available", .{pollfd.fd});
            if (pollfd.fd == server.sockfd.?) {
                try state.onNewClient();
            } else if (pollfd.fd == signal_fd) {

                //state.onSignalFd(signal_fd);
            } else {
                try state.onClientMessage(pollfd.fd);
            }
        }
    }
}
