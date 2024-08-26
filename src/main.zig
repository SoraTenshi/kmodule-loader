const std = @import("std");
const zigwin = @import("zigwin32");
const args = @import("args");

const win = std.os.windows;

const services = zigwin.system.services;
const zt = zigwin.zig;

const GetLastError = win.GetLastError;

fn unloadDriver(alloc: std.mem.Allocator, driver_name: []const u8) !void {
    const log = std.log.scoped(.Unload);
    const name_as_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, driver_name);
    defer alloc.free(name_as_utf16);

    const service_mgr = services.OpenSCManagerW(null, null, services.SC_MANAGER_ALL_ACCESS);
    defer _ = services.CloseServiceHandle(service_mgr);
    if (service_mgr == 0) {
        log.err("OpenSCManager failed with code: {any}", .{GetLastError()});
        return error.UnloadDriverFailed;
    }

    const service = services.OpenServiceW(service_mgr, name_as_utf16, services.SC_MANAGER_ALL_ACCESS);
    defer _ = services.CloseServiceHandle(service);
    if (service == 0) {
        log.err("OpenService failed with code: {any}", .{GetLastError()});
        return error.UnloadDriverFailed;
    }

    const delete = @as(win.BOOL, services.DeleteService(service));
    if (delete == win.FALSE) {
        log.err("Deletion failed with: {any}", .{GetLastError()});
        return error.UnloadDriverFailed;
    }
}

fn loadDriver(
    alloc: std.mem.Allocator,
    driver_name: []const u8,
    driver_path: []const u8,
) !void {
    const log = std.log.scoped(.Load);
    log.info("Params: name: {s}, driver_path: {s}", .{ driver_name, driver_path });
    const name_as_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, driver_name);
    defer alloc.free(name_as_utf16);
    const path_as_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, driver_path);
    defer alloc.free(path_as_utf16);

    var driver_image_path: [win.MAX_PATH:0]u16 = undefined;

    _ = win.kernel32.GetFullPathNameW(path_as_utf16.ptr, driver_image_path.len, &driver_image_path, null);

    const service_mgr = services.OpenSCManagerW(null, null, services.SC_MANAGER_ALL_ACCESS);
    defer _ = services.CloseServiceHandle(service_mgr);
    if (service_mgr == 0) {
        log.err("OpenSCManager failed with code: {any}", .{GetLastError()});
        return error.LoadDriverFailed;
    }

    const service_ddk = services.CreateServiceW(
        service_mgr,
        name_as_utf16,
        name_as_utf16,
        services.SERVICE_ALL_ACCESS,
        services.SERVICE_KERNEL_DRIVER,
        services.SERVICE_DEMAND_START,
        services.SERVICE_ERROR_IGNORE,
        &driver_image_path,
        null,
        null,
        null,
        null,
        null,
    );
    defer _ = services.CloseServiceHandle(service_ddk);
    errdefer unloadDriver(alloc, driver_name) catch {};

    if (service_ddk == 0) {
        switch (GetLastError()) {
            .SERVICE_EXISTS => {
                log.err("The driver is already loaded!", .{});
                return error.LoadDriverFailed;
            },
            else => {
                log.err("CreateService failed with: {}", .{GetLastError()});
                return error.LoadDriverFailed;
            },
        }

        return error.LoadDriverFailed;
    }

    const start_service = @as(win.BOOL, services.StartServiceW(service_ddk, 0, null));
    if (start_service == win.FALSE) {
        log.err("StartService failed with: {any}", .{GetLastError()});
        return error.LoadDriverFailed;
    }

    log.info("Driver loaded!", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const options = args.parseForCurrentProcess(Arguments, alloc, .print) catch return error.WrongArgs;
    defer options.deinit();

    const parsed = options.options;

    if (parsed.help or parsed.hasArgs()) {
        try args.printHelp(Arguments, options.executable_name orelse "kmodule-loader", std.io.getStdOut().writer());
        return;
    }

    if (parsed.checkLoad()) {
        std.log.scoped(.Args).err("Load and Name require both to be set.", .{});
        return error.MissingArgs;
    }

    if (parsed.unload) |driver| {
        try unloadDriver(alloc, driver);
        return;
    } else {
        try loadDriver(alloc, parsed.name.?, parsed.load.?);
        return;
    }

    try args.printHelp(Arguments, options.executable_name orelse "kmodule-loader", std.io.getStdOut().writer());
}

const Arguments = struct {
    name: ?[]const u8 = null,
    load: ?[]const u8 = null,
    unload: ?[]const u8 = null,
    help: bool = false,

    pub fn hasArgs(self: Arguments) bool {
        return self.name == null and self.load == null and self.unload == null;
    }

    pub fn checkLoad(self: Arguments) bool {
        return (self.load == null or self.name == null) and self.unload == null;
    }

    pub const shorthands = .{
        .n = "name",
        .l = "load",
        .u = "unload",
        .h = "help",
    };

    pub const meta = .{
        .option_docs = .{
            .name = "The name of the driver",
            .load = "The path to the *.sys file",
            .unload = "The driver name to unload",
            .help = "Shows this on screen",
        },
    };
};
