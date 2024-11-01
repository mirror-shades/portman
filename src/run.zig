//this is the file that will run the portman executable
// it should check args and run the appropriate command

const std = @import("std");

// Define the root structure
const PackageFile = struct {
    package: []Package,
};

const PackageSource = enum {
    Exe,
    Dir,
    Compressed,
    URL,
    Unknown,
};

// Update Package struct to match your JSON structure
const Package = struct {
    name: []const u8,
    path: []const u8,
    keyword: []const u8,
    description: []const u8,
    global: bool,
};

fn getline() ![]const u8 {
    var buffer: [240]u8 = undefined;
    const stdin = std.io.getStdIn();
    var buffered = std.io.bufferedReader(stdin.reader());
    var reader = buffered.reader();
    
    if (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
        // Make a copy of the trimmed input
        const trimmed = std.mem.trim(u8, line, &[_]u8{ '\r', '\n', ' ', '\t' });
        // Return just the valid part of the input
        return trimmed[0..trimmed.len];
    }
    
    return error.EndOfStream;
}

fn parse_package_info(allocator: std.mem.Allocator, keyword: []const u8) !?Package {
    // Create buffer for executable path
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
    
    const packages_path = try std.fs.path.join(allocator, &[_][]const u8{exe_dir, "..", "lib", "packages.json"});
    defer allocator.free(packages_path);
    
    const file = try std.fs.cwd().openFile(packages_path, .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    // Parse the JSON content
    const parsed = try std.json.parseFromSlice(
        PackageFile,
        allocator,
        content,
        .{},
    );
    defer parsed.deinit();

    // Search through packages for matching keyword
    for (parsed.value.package) |package| {
        if (std.mem.eql(u8, package.keyword, keyword)) {
            // Create a new Package with duplicated strings
            return Package{
                .name = try allocator.dupe(u8, package.name),
                .path = try allocator.dupe(u8, package.path),
                .keyword = try allocator.dupe(u8, package.keyword),
                .description = try allocator.dupe(u8, package.description),
                .global = package.global,  // Add this field
            };
        }
    }
    
    return null;
}

fn add_package_info(allocator: std.mem.Allocator, package: Package) !void {
    // Get executable directory path
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
    
    // Construct path to packages.json
    const packages_path = try std.fs.path.join(allocator, &[_][]const u8{exe_dir, "..", "lib", "packages.json"});
    defer allocator.free(packages_path);
    
    // Read existing file
    const file = try std.fs.cwd().openFile(packages_path, .{ .mode = .read_write });
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    // Parse existing JSON
    const parsed = try std.json.parseFromSlice(
        PackageFile,
        allocator,
        content,
        .{},
    );
    defer parsed.deinit();

    // Create new packages array with one more slot
    var new_packages = try allocator.alloc(Package, parsed.value.package.len + 1);
    defer allocator.free(new_packages);

    // Copy existing packages
    @memcpy(new_packages[0..parsed.value.package.len], parsed.value.package);

    // Add new package
    new_packages[new_packages.len - 1] = package;

    // Create new PackageFile with updated packages
    const new_package_file = PackageFile{ .package = new_packages };

    // Convert to JSON string
    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();
    try std.json.stringify(new_package_file, .{}, string.writer());

    // Write back to file
    try file.seekTo(0);
    try file.writeAll(string.items);
    try file.setEndPos(string.items.len);
}

fn remove_package_info(allocator: std.mem.Allocator, package: Package) !void {
    // Get executable directory path
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
    
    // Construct path to packages.json
    const packages_path = try std.fs.path.join(allocator, &[_][]const u8{exe_dir, "..", "lib", "packages.json"});
    defer allocator.free(packages_path);
    
    // Read existing file
    const file = try std.fs.cwd().openFile(packages_path, .{ .mode = .read_write });
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    // Parse existing JSON
    const parsed = try std.json.parseFromSlice(
        PackageFile,
        allocator,
        content,
        .{},
    );
    defer parsed.deinit();

    // Create new packages array with one less slot
    var new_packages = try allocator.alloc(Package, parsed.value.package.len - 1);
    defer allocator.free(new_packages);

    // Copy packages except the one to remove
    var new_index: usize = 0;
    for (parsed.value.package) |existing_package| {
        if (!std.mem.eql(u8, existing_package.keyword, package.keyword)) {
            new_packages[new_index] = existing_package;
            new_index += 1;
        }
    }

    // Create new PackageFile with updated packages
    const new_package_file = PackageFile{ .package = new_packages };

    // Convert to JSON string
    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();
    try std.json.stringify(new_package_file, .{}, string.writer());

    // Write back to file
    try file.seekTo(0);
    try file.writeAll(string.items);
    try file.setEndPos(string.items.len);

    // If package is global, remove the batch file
    if (package.global) {
        const batch_path = try std.fs.path.join(allocator, &[_][]const u8{
            exe_dir, 
            "..", 
            "bin", 
            try std.fmt.allocPrint(allocator, "{s}.cmd", .{package.keyword})
        });
        defer allocator.free(batch_path);
        
        std.fs.deleteFileAbsolute(batch_path) catch |err| {
            std.debug.print("Warning: Could not delete batch file: {any}\n", .{err});
        };
    }

    // Remove package directory from lib
    const lib_path = try std.fs.path.join(allocator, &[_][]const u8{
        exe_dir,
        "..",
        "lib",
        package.name,
    });
    defer allocator.free(lib_path);

    std.fs.deleteTreeAbsolute(lib_path) catch |err| {
        std.debug.print("Warning: Could not delete package directory: {any}\n", .{err});
    };
}

fn get_packages(allocator: std.mem.Allocator) ![][]const u8 {
    std.debug.print("Getting packages...\n", .{});
    
    // Create buffer for executable path
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
    
    const packages_path = try std.fs.path.join(allocator, &[_][]const u8{exe_dir, "..", "lib", "packages.json"});
    defer allocator.free(packages_path);
    
    const file = try std.fs.cwd().openFile(packages_path, .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    // Parse the JSON content
    const parsed = try std.json.parseFromSlice(
        PackageFile,
        allocator,
        content,
        .{},
    );
    defer parsed.deinit();

    // Access the parsed data through the package field
    const packages = parsed.value.package;
    var keywords = try allocator.alloc([]const u8, packages.len);
    
    // Get keywords from Package objects using parse_package_info
    for (packages, 0..) |package, i| {
        if (try parse_package_info(allocator, package.keyword)) |pkg| {
            keywords[i] = pkg.keyword;
        }
    }
    
    return keywords;
}

fn copyPackageFiles(allocator: std.mem.Allocator, source_path: []const u8, dest_dir: []const u8) !void {
    // Create the destination directory if it doesn't exist
    try std.fs.cwd().makePath(dest_dir);

    var source_dir = try std.fs.cwd().openDir(source_path, .{ .iterate = true });
    defer source_dir.close();

    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const source_file_path = try std.fs.path.join(allocator, &[_][]const u8{ source_path, entry.path });
        defer allocator.free(source_file_path);
        
        const dest_file_path = try std.fs.path.join(allocator, &[_][]const u8{ dest_dir, entry.path });
        defer allocator.free(dest_file_path);

        switch (entry.kind) {
            .file => {
                // Create parent directory if needed
                const dest_parent = std.fs.path.dirname(dest_file_path);
                if (dest_parent) |parent| {
                    try std.fs.cwd().makePath(parent);
                }

                // Copy the file
                try std.fs.copyFileAbsolute(source_file_path, dest_file_path, .{});
            },
            .directory => {
                try std.fs.cwd().makePath(dest_file_path);
            },
            else => {},
        }
    }
}

fn findExecutables(allocator: std.mem.Allocator, dir: std.fs.Dir, package_path: []const u8) !std.ArrayList([]const u8) {
    var exe_paths = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (exe_paths.items) |path| {
            allocator.free(path);
        }
        exe_paths.deinit();
    }

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ package_path, entry.path });
            defer allocator.free(full_path);
            
            if (std.mem.endsWith(u8, entry.path, ".exe") or 
                std.mem.endsWith(u8, entry.path, ".sh") or 
                !std.mem.containsAtLeast(u8, entry.path, 1, ".")) {
                try exe_paths.append(try allocator.dupe(u8, entry.path));
            }
        }
    }

    return exe_paths;
}

fn selectExecutable(exe_paths: std.ArrayList([]const u8)) ![]const u8 {
    if (exe_paths.items.len == 0) {
        return error.NoExecutablesFound;
    }

    while (true) {
        std.debug.print("Available executables\n", .{});
        std.debug.print("if you are unsure refer to the tools documentation\n", .{});
        for (exe_paths.items, 0..) |exe, i| {
            std.debug.print("{d}: {s}\n", .{ i + 1, exe });
        }

        std.debug.print("Enter the number of the executable to use (1-{d}): ", .{exe_paths.items.len});
        const input = getline() catch {
            std.debug.print("Error reading input. Please try again.\n", .{});
            continue;
        };
        
        const selection = std.fmt.parseInt(usize, input, 10) catch {
            std.debug.print("Please enter a number between 1 and {d}\n", .{exe_paths.items.len});
            continue;
        };
        
        if (selection < 1 or selection > exe_paths.items.len) {
            std.debug.print("Please enter a number between 1 and {d}\n", .{exe_paths.items.len});
            continue;
        }

        return exe_paths.items[selection - 1];
    }
}

fn createGlobalScript(allocator: std.mem.Allocator, exe_dir: []const u8, keyword: []const u8, package_name: []const u8, exe_path: []const u8) !void {
    const script_path = try std.fs.path.join(allocator, &[_][]const u8{
        exe_dir, "..", "bin", 
        try std.fmt.allocPrint(allocator, "{s}.cmd", .{keyword})
    });
    defer allocator.free(script_path);

    // For linked packages, use the path directly from package.json
    const script_content = if (std.mem.startsWith(u8, package_name, "link@")) 
        try std.fmt.allocPrint(allocator,
            \\@echo off
            \\set "EXE_PATH={s}"
            \\"%EXE_PATH%" %*
            \\
        , .{exe_path})  // Use the full path from package.json
        else try std.fmt.allocPrint(allocator,
            \\@echo off
            \\set "EXE_PATH=%~dp0..\lib\{s}\{s}"
            \\"%EXE_PATH%" %*
            \\
        , .{ package_name, exe_path });
    defer allocator.free(script_content);

    const script_file = try std.fs.cwd().createFile(script_path, .{});
    defer script_file.close();
    try script_file.writeAll(script_content);
}

fn determine_if_local_dir(package_path: []const u8) !PackageSource {
    // Check if it's a local directory
    var dir = std.fs.cwd().openDir(package_path, .{ .iterate = true }) catch {
        return PackageSource.Unknown;
    };
    dir.close();
    return PackageSource.Dir;

}

fn determine_source_type(package_path: []const u8) !PackageSource {
    if (std.mem.startsWith(u8, package_path, "http://") or 
        std.mem.startsWith(u8, package_path, "https://")) {
        std.debug.print("Package is a url\n", .{});
        return PackageSource.URL;
    }
    else if (std.mem.endsWith(u8, package_path, ".zip") or 
             std.mem.endsWith(u8, package_path, ".tar") or 
             std.mem.endsWith(u8, package_path, ".gz") or 
             std.mem.endsWith(u8, package_path, ".7z") or 
             std.mem.endsWith(u8, package_path, ".rar")) {
        return PackageSource.Compressed;
    }
    else if (std.mem.endsWith(u8, package_path, ".exe") or
             std.mem.endsWith(u8, package_path, ".sh") or
             std.mem.endsWith(u8, package_path, ".cmd") or
             std.mem.endsWith(u8, package_path, ".bat")) {
        return PackageSource.Exe;
    }
    else {
        return PackageSource.Unknown;
    }
}

fn install_local_dir(allocator: std.mem.Allocator, package_path: []const u8, is_global: bool) !void {
    // Open and verify package directory
    var dir = std.fs.cwd().openDir(package_path, .{ .iterate = true }) catch |err| {
        if (err == error.NotDir or err == error.FileNotFound) {
            std.debug.print("Package directory does not exist: {s}\n", .{package_path});
            return;
        }
        std.debug.print("Error opening directory: {any}\n", .{err});
        return err;
    };
    defer dir.close();

    const package_name = std.fs.path.basename(package_path);
    std.debug.print("Package name: {s}\n", .{package_name});

    // Find executables
    var exe_paths = try findExecutables(allocator, dir, package_path);
    defer {
        for (exe_paths.items) |path| {
            allocator.free(path);
        }
        exe_paths.deinit();
    }

    // Select executable
    const selected_exe = selectExecutable(exe_paths) catch |err| {
        switch (err) {
            error.NoExecutablesFound => {
                std.debug.print("No executable files found in the package\n", .{});
                return;
            },
            else => return err,
        }
    };

    // Get package metadata
    var keyword_copy: []u8 = undefined;
    while (true) {
        std.debug.print("Enter the keyword for the package: ", .{});
        const keyword = try getline();
        if (keyword.len == 0) {
            std.debug.print("Keyword cannot be empty. Please try again.\n", .{});
            continue;
        }
        keyword_copy = try allocator.dupe(u8, keyword);
        break;
    }
    defer allocator.free(keyword_copy);

    std.debug.print("Enter the description for the package: ", .{});
    const description = try getline();
    const desc_copy = try allocator.dupe(u8, description);
    defer allocator.free(desc_copy);

    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
    
    // Create the destination path in the lib directory
    const lib_path = try std.fs.path.join(allocator, &[_][]const u8{ exe_dir, "..", "lib", package_name });
    defer allocator.free(lib_path);

    // Copy all package files to the lib directory
    std.debug.print("Copying package files to {s}...\n", .{lib_path});
    try copyPackageFiles(allocator, package_path, lib_path);
    
    if (is_global) {
        // Create the command script only if global
        try createGlobalScript(allocator, exe_dir, keyword_copy, package_name, selected_exe);
    }

    // Create and save package metadata
    const new_package = Package{
        .name = try allocator.dupe(u8, package_name),
        .path = try allocator.dupe(u8, selected_exe),
        .keyword = keyword_copy,
        .description = desc_copy,
        .global = is_global,
    };
    try add_package_info(allocator, new_package);
}

fn download_package(allocator: std.mem.Allocator, package_path: []const u8) !void {
    // Create a temporary directory for downloads if it doesn't exist
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
    
    const temp_dir = try std.fs.path.join(allocator, &[_][]const u8{ exe_dir, "..", "temp" });
    defer allocator.free(temp_dir);
    
    try std.fs.cwd().makePath(temp_dir);

    // Extract filename from URL
    const url_basename = std.fs.path.basename(package_path);
    const output_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, url_basename });
    defer allocator.free(output_path);

    // Prepare curl command
    const args = [_][]const u8{
        "curl",
        "-L", // Follow redirects
        "-o",
        output_path,
        package_path,
    };

    // Execute curl
    var child = std.process.Child.init(&args, allocator);
    const term = try child.spawnAndWait();
    
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Failed to download package: {s}\n", .{package_path});
        return error.DownloadFailed;
    }

    // Now that we have the file, determine its type and install it
    const source_type = try determine_source_type(output_path);
    switch (source_type) {
        .Exe => try install_exe(allocator, output_path, false),
        .Compressed => try install_compressed(allocator, output_path, false),
        else => {
            std.debug.print("Downloaded file is not a recognized package type\n", .{});
            return error.InvalidPackageType;
        },
    }

    // Clean up the temporary file
    std.fs.deleteFileAbsolute(output_path) catch |err| {
        std.debug.print("Warning: Could not delete temporary file: {any}\n", .{err});
    };
}

fn install_exe(allocator: std.mem.Allocator, package_path: []const u8, is_global: bool) !void {
    // Get executable directory path
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);

    // Get the exe name without extension
    const exe_name = std.fs.path.stem(package_path);
    
    // Create the destination path in the lib directory
    const lib_path = try std.fs.path.join(allocator, &[_][]const u8{ exe_dir, "..", "lib", exe_name });
    defer allocator.free(lib_path);

    // Create the lib directory if it doesn't exist
    try std.fs.cwd().makePath(lib_path);

    // Copy the exe to the new directory
    const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ lib_path, std.fs.path.basename(package_path) });
    defer allocator.free(dest_path);

    try std.fs.copyFileAbsolute(package_path, dest_path, .{});

    // Now that we've set up the directory structure, install it as a local dir
    try install_local_dir(allocator, lib_path, is_global);
}

fn install_compressed(allocator: std.mem.Allocator, package_path: []const u8, is_global: bool) !void {
    // Get executable directory path
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
    
    // Create a temporary extraction directory
    const temp_dir = try std.fs.path.join(allocator, &[_][]const u8{ exe_dir, "..", "temp", "extract" });
    defer allocator.free(temp_dir);
    
    try std.fs.cwd().makePath(temp_dir);
    defer std.fs.deleteTreeAbsolute(temp_dir) catch |err| {
        std.debug.print("Warning: Could not delete temporary directory: {any}\n", .{err});
    };

    // Create the output argument
    const output_arg = try std.fmt.allocPrint(allocator, "-o{s}", .{temp_dir});
    defer allocator.free(output_arg);

    // Prepare 7zip command
    const args = [_][]const u8{
        "7zr",
        "x",
        package_path,
        output_arg,
        "-y"  // Auto-answer yes to queries
    };

    // Execute 7zip
    var child = std.process.Child.init(&args, allocator);
    const term = try child.spawnAndWait();
    
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Failed to extract package: {s}\n", .{package_path});
        return error.ExtractionFailed;
    }

    // Now that we've extracted the files, install from the temp directory
    try install_local_dir(allocator, temp_dir, is_global);
}

fn install_package(allocator: std.mem.Allocator, package_path: []const u8, is_global: bool) !void {
    //make an enum for exe, dir, and compressed
    var package_source: PackageSource = try determine_if_local_dir(package_path); // Added try
    std.debug.print("Package source: {}\n", .{package_source});
    if(package_source == PackageSource.Unknown) {
        package_source = try determine_source_type(package_path);
        std.debug.print("Package source: {}\n", .{package_source});
        if (package_source == PackageSource.URL ) {
            try download_package(allocator, package_path);
        }
        else if (package_source == PackageSource.Exe) {
            try install_exe(allocator, package_path, is_global);
        }
        else if (package_source == PackageSource.Compressed) {
            try install_compressed(allocator, package_path, is_global);
        }
        return;
    }
    try install_local_dir(allocator, package_path, is_global);
}

fn globalize_package(allocator: std.mem.Allocator, keyword: []const u8, is_add: bool) !void {
    // Get package info
    if (try parse_package_info(allocator, keyword)) |package| {
        // Get executable directory path
        var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);

        if (is_add) {
            // Create the batch file using the full path from package info
            try createGlobalScript(allocator, exe_dir, package.keyword, package.name, package.path);
            std.debug.print("Added global script for: {s}\n", .{package.keyword});
        } else {
            // Remove the batch file
            const batch_path = try std.fs.path.join(allocator, &[_][]const u8{
                exe_dir,
                "..",
                "bin",
                try std.fmt.allocPrint(allocator, "{s}.cmd", .{package.keyword})
            });
            defer allocator.free(batch_path);

            std.fs.deleteFileAbsolute(batch_path) catch |err| {
                std.debug.print("Warning: Could not delete batch file: {any}\n", .{err});
                return err;
            };
            std.debug.print("Removed global script for: {s}\n", .{package.keyword});
        }
    } else {
        std.debug.print("Package not found: {s}\n", .{keyword});
        return error.PackageNotFound;
    }
}

fn remove_package(allocator: std.mem.Allocator, keyword: []const u8) !void {
    // Get the package info first
    if (try parse_package_info(allocator, keyword)) |package| {
        try remove_package_info(allocator, package);
        std.debug.print("Successfully removed package: {s}\n", .{keyword});
    } else {
        std.debug.print("Package not found: {s}\n", .{keyword});
        return error.PackageNotFound;
    }
}

fn link_package(allocator: std.mem.Allocator, path: []const u8, is_global: bool) !void {
    std.debug.print("Linking package from: {s}\n", .{path});
    
    // Open and verify package directory
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        if (err == error.NotDir or err == error.FileNotFound) {
            std.debug.print("Package directory does not exist: {s}\n", .{path});
            return;
        }
        std.debug.print("Error opening directory: {any}\n", .{err});
        return err;
    };
    defer dir.close();

    // Get the base directory name and create the linked name
    const base_name = std.fs.path.basename(path);
    const linked_name = try std.fmt.allocPrint(allocator, "link@{s}", .{base_name});
    defer allocator.free(linked_name);

    // Find executables
    var exe_paths = try findExecutables(allocator, dir, path);
    defer {
        for (exe_paths.items) |exe_path| {
            allocator.free(exe_path);
        }
        exe_paths.deinit();
    }

    // Select executable
    const selected_exe = selectExecutable(exe_paths) catch |err| {
        switch (err) {
            error.NoExecutablesFound => {
                std.debug.print("No executable files found in the package\n", .{});
                return;
            },
            else => return err,
        }
    };

    // Get package metadata
    var keyword_copy: []u8 = undefined;
    while (true) {
        std.debug.print("Enter the keyword for the package: ", .{});
        const keyword = try getline();
        if (keyword.len == 0) {
            std.debug.print("Keyword cannot be empty. Please try again.\n", .{});
            continue;
        }
        keyword_copy = try allocator.dupe(u8, keyword);
        break;
    }
    defer allocator.free(keyword_copy);

    std.debug.print("Enter the description for the package: ", .{});
    const description = try getline();
    const desc_copy = try allocator.dupe(u8, description);
    defer allocator.free(desc_copy);

    // Get absolute path for the linked package
    const abs_path = try std.fs.realpathAlloc(allocator, path);
    defer allocator.free(abs_path);

    if (is_global) {
        var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
        
        // Create the global script with the full absolute path
        const full_exe_path = try std.fs.path.join(allocator, &[_][]const u8{ abs_path, selected_exe });
        try createGlobalScript(allocator, exe_dir, keyword_copy, linked_name, full_exe_path);
    }

    // Create and save package metadata
    const new_package = Package{
        .name = try allocator.dupe(u8, linked_name),
        .path = try std.fs.path.join(allocator, &[_][]const u8{ abs_path, selected_exe }),
        .keyword = keyword_copy,
        .description = desc_copy,
        .global = is_global,
    };
    try add_package_info(allocator, new_package);

    std.debug.print("Successfully linked package: {s}\n", .{linked_name});
}

pub fn run_portman() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Get command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    
    // Skip the executable name
    _ = args.skip();

    // Check if there are any arguments
    if (args.next()) |command| {
        if (std.mem.eql(u8, command, "install")) {
            if (args.next()) |package| {
                var is_global = false;
                // Check for -g flag
                if (args.next()) |flag| {
                    if (std.mem.eql(u8, flag, "-g")) {
                        is_global = true;
                    }
                }
                try install_package(allocator, package, is_global);
            } else {
                std.debug.print("Error: Package path is required\n", .{});
                std.debug.print("Usage: portman install <package path> [-g]\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, command, "global")) {
            if (args.next()) |package| {
                if (args.next()) |flag| {
                    if (std.mem.eql(u8, flag, "-a")) {
                        try globalize_package(allocator, package, true);
                    } 
                    else if (std.mem.eql(u8, flag, "-r")) {
                        try globalize_package(allocator, package, false);
                    }
                    else {
                        std.debug.print("Use -a or -r to add or remove\n", .{});
                        std.debug.print("portman global <package> -a\n", .{});
                        std.debug.print("portman global <package> -r\n", .{});
                        return;
                    }
                }
            }
        } else if (std.mem.eql(u8, command, "remove")) {
            if (args.next()) |package| {
                try remove_package(allocator, package);
            } else {
                std.debug.print("Error: Package name is required\n", .{});
                std.debug.print("Usage: portman remove <package-name>\n", .{});
            }
        } else if (std.mem.eql(u8, command, "link")) {
            var is_global: bool = false;
            if (args.next()) |path| {
                if (args.next()) |flag| {
                    if (std.mem.eql(u8, flag, "-g")) {
                        is_global = true;
                    }
                }
                try link_package(allocator, path, is_global);
            } else {
                std.debug.print("Error: Path is required\n", .{});
                std.debug.print("Usage: portman link <path>\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, command, "list")) {
            const packages = try get_packages(allocator);
            if (args.next()) |flag| {
                if (std.mem.eql(u8, flag, "-v")) {
                    std.debug.print("Available packages with descriptions:\n", .{});
            for (packages) |keyword| {
                if (try parse_package_info(allocator, keyword)) |package| {
                        std.debug.print("\n({s}\\{s}) {s} \nGlobal: {}\nDescription: {s}\n", .{
                            package.name, 
                            package.path,
                            package.keyword, 
                            package.global,
                            package.description
                            });
                        }
                    }
                }
            } else {
                for (packages) |keyword| {
                    std.debug.print("Available package: {s}\n", .{keyword});
                }
            }
        } else if (try parse_package_info(allocator, command)) |package| {
            // Found the package, now execute it
            var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
            
            // Construct the full path to the executable
            const exe_path = if (std.mem.startsWith(u8, package.name, "link@"))
                try allocator.dupe(u8, package.path)  // Use the absolute path directly
            else try std.fs.path.join(allocator, &[_][]const u8{
                exe_dir, "..", "lib", package.name, package.path
            });
            defer allocator.free(exe_path);

            // Collect remaining arguments
            var child_args = std.ArrayList([]const u8).init(allocator);
            defer child_args.deinit();
            
            // Add the executable path as the first argument
            try child_args.append(exe_path);
            
            // Add any remaining arguments
            while (args.next()) |arg| {
                try child_args.append(arg);
            }

            // Create child process
            var child = std.process.Child.init(child_args.items, allocator);
            _ = try child.spawnAndWait();
        } else {
            // No arguments provided, show help
            std.debug.print("Usage: portman <command> [options]\n", .{});
            std.debug.print("Commands:\n", .{});
            std.debug.print("  install <package>     Install a package\n", .{});
            std.debug.print("  install <package> -g  Install a package globally\n", .{});
            std.debug.print("  global <package> -a   Add package to global list\n", .{});
            std.debug.print("  global <package> -r   Remove package from global list\n", .{});
            std.debug.print("  remove <package>      Remove a package\n", .{});
            std.debug.print("  link <path>           Link a package from elsewhere\n", .{});
            std.debug.print("  list                  List all available packages\n", .{});
            std.debug.print("  list -v               List all available packages with descriptions\n", .{});
        }
    }
}