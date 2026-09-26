const std = @import("std");
const builtin = @import("builtin");

// build.zig is compiled before build.zig.zon's minimum_zig_version is consulted,
// so an older compiler dies on an unrecognised std.Build API rather than saying
// what is actually wrong. Fail with a legible reason instead.
comptime {
    const ok = builtin.zig_version.major > 0 or builtin.zig_version.minor >= 17;
    if (!ok) @compileError(
        "buru requires Zig 0.17.0-dev or newer; found " ++ builtin.zig_version_string ++
            "\nThe 0.17 std moved filesystem I/O behind an explicit Io instance and" ++
            "\nreplaced b.args with Run.addPassthruArgs; neither exists in 0.16.",
    );
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // build.zig.zon is the single source of truth for the version. The Homebrew
    // formula asserts `buru --version` matches the release tag.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/buru.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "buru",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run buru").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
