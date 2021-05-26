const std = @import("std");

const CRLF = "\r\n";
const SEPARATOR = " ";

const CommandType = enum(u8) {
    CAP,
    NICK,
    USER,
    MODE,
    WHOIS,
    PING,
    PONG,
    QUIT,
};

pub const Message = struct {
    tags: ?[]const u8,
    source: ?[]const u8,
    command: CommandType,
    params: []const u8,

    const Self = @This();

    pub fn parse(data: []const u8) !Self {
        const first_space = std.mem.indexOf(u8, data, SEPARATOR).?;
        const command = std.meta.stringToEnum(CommandType, data[0..first_space]) orelse return error.UnknownCommand;
        const params = data[first_space + 1 ..];

        return Self{
            .tags = null,
            .source = null,
            .command = command,
            .params = params,
        };
    }
};

test "message parsing works" {
    const s =
        "CAP REQ :sasl\r\n";
    const m = try Message.parse(s);
    try std.testing.expectEqual(CommandType.CAP, m.command);
    try std.testing.expectEqualStrings("REQ :sasl", m.params);
}
