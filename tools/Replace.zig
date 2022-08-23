//! Do a naive search and replace on a file
const std = @import("std");

const KB = 1024;
const MB = 1024 * KB;

const ReplaceStep = @This();

pub const Replacement = struct {
    search: []const u8,
    replacement: []const u8,
};

step: std.build.Step,
builder: *std.build.Builder,
source_path: std.build.FileSource,
replacements: []const Replacement,
output_dir: std.build.InstallDir,
output_name: []const u8,
output: std.build.GeneratedFile,

pub fn create(b: *std.build.Builder, opt: struct {
    source_path: std.build.FileSource,
    replacements: []const Replacement,
    output_dir: std.build.InstallDir,
    output_name: []const u8,
}) *@This() {
    var result = b.allocator.create(ReplaceStep) catch @panic("memory");
    result.* = ReplaceStep{
        .step = std.build.Step.init(.custom, "search and replace values in a file at build time", b.allocator, make),
        .builder = b,
        .source_path = opt.source_path,
        .replacements = opt.replacements,
        .output_dir = opt.output_dir,
        .output_name = opt.output_name,
        .output = undefined,
    };
    result.*.output = std.build.GeneratedFile{ .step = &result.*.step };
    return result;
}

fn make(step: *std.build.Step) !void {
    const this = @fieldParentPtr(ReplaceStep, "step", step);

    const allocator = this.builder.allocator;
    const cwd = std.fs.cwd();

    // Get path to source and output
    const source_src = this.source_path.getPath(this.builder);
    const output = this.builder.getInstallPath(.lib, this.output_name);

    // Open file
    const source_file = try cwd.openFile(source_src, .{});
    defer source_file.close();
    const source = try source_file.readToEndAlloc(allocator, 10 * MB);
    defer allocator.free(source);

    var replaced_data = try allocator.dupe(u8, source);
    defer allocator.free(replaced_data);
    for (this.replacements) |replacement| {
        var new_data = try std.mem.replaceOwned(u8, allocator, replaced_data, replacement.search, replacement.replacement);
        allocator.free(replaced_data);
        replaced_data = new_data;
    }

    // Open output file and write data into it
    cwd.makePath(this.builder.getInstallPath(this.output_dir, "")) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const install_path = this.builder.getInstallPath(this.output_dir, this.output_name);
    try cwd.writeFile(install_path, replaced_data);

    this.output.path = output;
}
