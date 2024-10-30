// # verify that the directory is set up right
// # /
// # /lib
// # /lib/packages.toml
// # /bin
// # /bin/main.exe <- this is the main executable the code will be compiled to
// # if the directory is not set up right, make a new directory in the same place as the main.exe file called portman and set everything up

const std = @import("std");

fn create_portman_directory(_root_dir: []const u8) !void {
    std.debug.print("Installing Portman to {s}\n", .{_root_dir});
    // Use an arena allocator for all our temporary allocations
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Get current executable path
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&buffer);
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";

    // Convert _root_dir to absolute path if provided
    const base_dir = if (_root_dir.len > 0) 
        try std.fs.cwd().realpathAlloc(allocator, _root_dir)
    else 
        exe_dir;

    // Always create a portman subdirectory
    const root_dir = if (std.mem.eql(u8, std.fs.path.basename(base_dir), "bin"))
        std.fs.path.dirname(base_dir) orelse "."
    else
        try std.fs.path.join(allocator, &[_][]const u8{base_dir, "portman"});

    std.debug.print("Creating directory structure in: {s}\n", .{root_dir});

    // Create root dir if needed
    std.fs.makeDirAbsolute(root_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Error creating root dir: {any}\n", .{err});
            return err;
        }
    };

    // Create lib and bin directories
    const lib_path = try std.fs.path.join(allocator, &[_][]const u8{root_dir, "lib"});
    const bin_path = try std.fs.path.join(allocator, &[_][]const u8{root_dir, "bin"});
    
    std.debug.print("Creating lib directory: {s}\n", .{lib_path});
    std.fs.makeDirAbsolute(lib_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Error creating lib dir: {any}\n", .{err});
            return err;
        }
    };

    std.debug.print("Creating bin directory: {s}\n", .{bin_path});
    std.fs.makeDirAbsolute(bin_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Error creating bin dir: {any}\n", .{err});
            return err;
        }
    };

    // Create packages.toml
    const packages_path = try std.fs.path.join(allocator, &[_][]const u8{lib_path, "packages.toml"});
    std.debug.print("Creating packages.toml: {s}\n", .{packages_path});
    const file = std.fs.createFileAbsolute(packages_path, .{ .exclusive = true }) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Error creating packages.toml: {any}\n", .{err});
            return err;
        } else {
            std.debug.print("packages.toml already exists\n", .{});
            return;
        }
    };
    file.close();

    // Copy executable if needed
    if (!std.mem.eql(u8, std.fs.path.basename(exe_dir), "bin")) {
        const new_exe_path = try std.fs.path.join(
            allocator,
            &[_][]const u8{bin_path, "portman.exe"}
        );
        std.debug.print("Copying executable to: {s}\n", .{new_exe_path});
        try std.fs.copyFileAbsolute(exe_path, new_exe_path, .{});
    }

    std.debug.print("Directory structure verified/created at: {s}\n", .{root_dir});
}

// checks to see if portman is alreadyinstalled
fn verify_install() !bool {
    // Use arena allocator instead of page_allocator directly
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&buffer);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidPath;
    const parent_dir = std.fs.path.dirname(exe_dir) orelse return error.InvalidPath;
    
    const packages_path = try std.fs.path.join(
        allocator, 
        &[_][]const u8{parent_dir, "lib", "packages.toml"}
    );
    
    // Check if both the file exists and is accessible
    const file = std.fs.cwd().openFile(packages_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return false,
            error.AccessDenied => {
                std.debug.print("Warning: Found packages.toml but cannot access it\n", .{});
                return false;
            },
            else => return err,
        }
    };
    defer file.close();
    
    return true;
}

// set up the install process
fn install_portman() !void {
    var root_dir: []const u8 = ""; // Default install path
    // Use arena allocator for args
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // Skip executable name
        
    if (args.next()) |arg| {
        // Check if directory exists
        std.fs.cwd().access(arg, .{}) catch {
            std.debug.print("Error: Directory '{s}' does not exist\n", .{arg});
            return error.InvalidInstallPath;
        };
        
        // Check if portman directory already exists in the specified path
        const portman_path = try std.fs.path.join(allocator, &[_][]const u8{arg, "portman"});
        if (std.fs.cwd().access(portman_path, .{}) catch null != null) {
            std.debug.print("Error: Directory '{s}' already contains a 'portman' directory\n", .{arg});
            return error.PortmanDirectoryExists;
        }
        
        // Set custom install path
        root_dir = arg;
    }
        
    std.debug.print("Installing Portman...\n", .{});
    try create_portman_directory(root_dir);
}


pub fn main() !void {
    // check if portman is installed
    const installed: bool = try verify_install();
    
    if(installed) {
        std.debug.print("Portman is already installed.\n", .{});
        // run portman
    } else {
        try install_portman();
    }
}
