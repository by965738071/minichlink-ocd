const std = @import("std");
const Io = std.Io;

// Run: `zig build`
// Requirements:
// MacOS: install XCode
// Linux: apt install libudev-dev
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = if (b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    )) |mode| mode else .ReleaseFast;

    const minichlink = try buildMinichlink(b, .exe, target, optimize);
    b.installArtifact(minichlink);

    const build_lib = b.step("lib", "Build the minichlink as library");
    const minichlink_lib = try buildMinichlink(b, .lib, target, optimize);
    const install_minichlink_lib = b.addInstallArtifact(minichlink_lib, .{});
    build_lib.dependOn(&install_minichlink_lib.step);

    // Shared translate_c step for the C bindings.
    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const minichlink_dep = b.dependency("ch32fun", .{});
    c_translate.addIncludePath(minichlink_dep.path("minichlink"));
    c_translate.addIncludePath(b.path("src"));

    const minichlink_ocd = try buildMinichlinkOcd(b, target, optimize, minichlink_lib, c_translate);

    const run_step = b.step("run", "Run the minichlink-ocd");
    const ocd_run = b.addRunArtifact(minichlink_ocd);
    run_step.dependOn(&ocd_run.step);

    const test_step = b.step("test", "Run tests");
    const minichlink_ocd_tests = b.addTest(.{
        .name = "test",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "c", .module = c_translate.createModule() },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    // b.installArtifact(minichlink_ocd_tests);
    const minichlink_ocd_tests_run = b.addRunArtifact(minichlink_ocd_tests);
    test_step.dependOn(&minichlink_ocd_tests_run.step);
}

fn buildMinichlink(
    b: *std.Build,
    kind: std.Build.Step.Compile.Kind,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const libusb_dep = b.dependency("libusb", .{});
    const libusb = try createLibusb(b, libusb_dep, target, optimize);

    const minichlink_dep = b.dependency("ch32fun", .{});
    const minichlink = try createMinichlink(b, minichlink_dep, kind, target, optimize);
    minichlink.root_module.linkLibrary(libusb);

    return minichlink;
}

fn createMinichlink(
    b: *std.Build,
    dep: *std.Build.Dependency,
    kind: std.Build.Step.Compile.Kind,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const root_path = dep.path("minichlink");
    const exe = std.Build.Step.Compile.create(b, .{
        .name = "minichlink",
        .kind = kind,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
            .sanitize_thread = false,
        }),
    });

    if (kind == .lib) {
        exe.linkage = .static;
        exe.root_module.addCMacro("MINICHLINK_AS_LIBRARY", "1");
        exe.installHeader(dep.path("minichlink/minichlink.h"), "minichlink.h");
    }

    exe.root_module.link_libc = true;
    exe.root_module.addIncludePath(root_path);
    exe.root_module.addCSourceFiles(.{
        .root = root_path,
        .files = &.{
            "minichlink.c",
            "pgm-wch-linke.c",
            "pgm-esp32s2-ch32xx.c",
            "nhc-link042.c",
            "ardulink.c",
            "serial_dev.c",
            "pgm-b003fun.c",
            "minichgdb.c",
            "ch5xx.c",
            "chips.c",
            "pgm-wch-isp.c",
        },
    });
    exe.root_module.addCMacro("MINICHLINK", "1");
    exe.root_module.addCMacro("CH32V003", "1");
    // Without this, the build fails with "error: unknown register name 'a5' in asm"
    exe.root_module.addCMacro("__DELAY_TINY_DEFINED__", "1");

    switch (target.result.os.tag) {
        .macos => {
            exe.root_module.addCMacro("__MACOSX__", "1");
            exe.root_module.linkFramework("CoreFoundation", .{});
            exe.root_module.linkFramework("IOKit", .{});
        },
        .linux, .netbsd, .openbsd => {
            const rules = b.addInstallBinFile(dep.path("minichlink/99-minichlink.rules"), "99-minichlink.rules");
            exe.step.dependOn(&rules.step);
        },
        .windows => {
            exe.root_module.addCMacro("_WIN32_WINNT", "0x0600");
            exe.root_module.addLibraryPath(dep.path("minichlink"));
            exe.root_module.linkSystemLibrary("setupapi", .{});
            exe.root_module.linkSystemLibrary("ws2_32", .{});
        },
        else => {},
    }

    try addPaths(exe.root_module, target);

    return exe;
}

fn defineBool(b: bool) ?u1 {
    return if (b) 1 else null;
}

fn createLibusb(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const is_posix = target.result.os.tag != .windows;
    // libusb source archives from GitHub don't include the generated
    // version_describe.h. We provide it here with only LIBUSB_DESCRIBE;
    // the numeric macros come from version.h / version_nano.h.
    const version_header = b.addConfigHeader(.{ .style = .blank, .include_path = "version_describe.h" }, .{
        .LIBUSB_DESCRIBE = "\"ac8abbae\"",
    });

    const config_header = b.addConfigHeader(.{ .style = .blank }, .{
        ._GNU_SOURCE = 1,
        .DEFAULT_VISIBILITY = .@"__attribute__ ((visibility (\"default\")))",
        .@"PRINTF_FORMAT(a, b)" = .@"/* */",
        .PLATFORM_POSIX = defineBool(is_posix),
        .PLATFORM_WINDOWS = defineBool(target.result.os.tag == .windows),
        // .ENABLE_DEBUG_LOGGING = defineBool(optimize == .Debug),
        .ENABLE_LOGGING = 1,
        .HAVE_CLOCK_GETTIME = defineBool(target.result.os.tag != .windows),
        .HAVE_EVENTFD = null,
        .HAVE_TIMERFD = null,
        .USE_SYSTEM_LOGGING_FACILITY = null,
        .HAVE_PTHREAD_CONDATTR_SETCLOCK = null,
        .HAVE_PTHREAD_SETNAME_NP = null,
        .HAVE_PTHREAD_THREADID_NP = null,
    });

    const lib = std.Build.Step.Compile.create(b, .{
        .name = "usb",
        .version = .{ .major = 1, .minor = 0, .patch = 27 },
        .kind = .lib,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
            .sanitize_thread = false,
        }),
    });
    lib.installHeader(dep.path("libusb/libusb.h"), "libusb.h");
    lib.root_module.link_libc = true;
    lib.root_module.addIncludePath(dep.path("libusb"));
    lib.root_module.addConfigHeader(config_header);
    lib.root_module.addConfigHeader(version_header);
    lib.root_module.addCSourceFiles(.{
        .root = dep.path("libusb"),
        .files = &.{
            "core.c",
            "descriptor.c",
            "hotplug.c",
            "io.c",
            "strerror.c",
            "sync.c",
        },
    });

    switch (target.result.os.tag) {
        .macos => {
            lib.root_module.addIncludePath(dep.path("Xcode"));
        },
        .windows => {
            lib.root_module.addIncludePath(dep.path("msvc"));
        },
        else => {},
    }

    if (is_posix) {
        lib.root_module.addCSourceFiles(.{
            .root = dep.path("libusb/os"),
            .files = &.{
                "events_posix.c",
                "threads_posix.c",
            },
        });
    } else {
        lib.root_module.addCSourceFiles(.{
            .root = dep.path("libusb/os"),
            .files = &.{
                "events_windows.c",
                "threads_windows.c",
            },
        });
    }
    if (target.result.abi.isAndroid()) {
        lib.root_module.addIncludePath(dep.path("android"));
    }

    switch (target.result.os.tag) {
        .macos => {
            lib.root_module.addCSourceFiles(.{
                .root = dep.path("libusb/os"),
                .files = &.{"darwin_usb.c"},
            });
            lib.root_module.linkFramework("IOKit", .{});
            lib.root_module.linkFramework("CoreFoundation", .{});
            lib.root_module.linkFramework("Security", .{});
        },
        .linux => {
            lib.root_module.addCSourceFiles(.{
                .root = dep.path("libusb/os"),
                .files = &.{
                    "linux_usbfs.c",
                    "linux_netlink.c",
                    "linux_udev.c",
                },
            });
            lib.root_module.linkSystemLibrary("udev", .{ .use_pkg_config = .no });
        },
        .windows => {
            lib.root_module.addCSourceFiles(.{
                .root = dep.path("libusb/os"),
                .files = &.{
                    "windows_common.c",
                    "windows_usbdk.c",
                    "windows_winusb.c",
                },
            });
            lib.root_module.addWin32ResourceFile(.{ .file = dep.path("libusb/libusb-1.0.rc") });
        },
        .netbsd => {
            lib.root_module.addCSourceFiles(.{
                .root = dep.path("libusb/os"),
                .files = &.{"netbsd_usb.c"},
            });
        },
        .openbsd => {
            lib.root_module.addCSourceFiles(.{
                .root = dep.path("libusb/os"),
                .files = &.{"openbsd_usb.c"},
            });
        },
        else => {},
    }

    try addPaths(lib.root_module, target);

    return lib;
}

fn buildMinichlinkOcd(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    minichlink_lib: *std.Build.Step.Compile,
    c_translate: *std.Build.Step.TranslateC,
) !*std.Build.Step.Compile {
    const minichlink_dep = b.dependency("ch32fun", .{});
    const minichlink_root_path = minichlink_dep.path("minichlink");

    const ocd = b.addExecutable(.{
        .name = "minichlink-ocd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
            .sanitize_thread = false,
            .imports = &.{
                .{ .name = "c", .module = c_translate.createModule() },
            },
        }),
    });
    ocd.root_module.linkLibrary(minichlink_lib);
    ocd.root_module.addAnonymousImport("build_zig_zon", .{ .root_source_file = b.path("build.zig.zon") });

    // Patch minichlink.c at configure time: copy the entire file and rename
    // main() to orig_main(), so all helper functions and struct definitions
    // are available to the patched file.
    const dep_root = minichlink_dep.builder.root;
    const abs_path = try dep_root.joinString(b.allocator, "minichlink/minichlink.c");
    const patched_rel = "src/minichlink-patched.c";
    const io = b.graph.io;

    {
        const cwd = std.Io.Dir.cwd();
        const content = try std.Io.Dir.readFileAlloc(cwd, io, abs_path, b.allocator, .unlimited);
        defer b.allocator.free(content);

        // Replace "int main(" with "int orig_main(" so the entry point is renamed.
        // This ensures all functions and structs from minichlink.c are available.
        const search = "int main(";
        const replace_s = "int orig_main(";

        // Count occurrences to allocate the right sized buffer.
        var count: usize = 0;
        {
            var search_from: usize = 0;
            while (std.mem.indexOf(u8, content[search_from..], search)) |pos| {
                count += 1;
                search_from += pos + search.len;
            }
        }

        // Also fix the include path: minichlink.c uses "#include "../ch32fun/ch32fun.h"
        // which resolves within the ch32fun package, but our patched copy is in src/
        // and needs to find ch32fun.h via -I flags instead.
        const inc_search = "#include \"../ch32fun/ch32fun.h\"";
        const inc_replace = "#include \"ch32fun.h\"";

        var inc_count: usize = 0;
        {
            var search_from: usize = 0;
            while (std.mem.indexOf(u8, content[search_from..], inc_search)) |pos| {
                inc_count += 1;
                search_from += pos + inc_search.len;
            }
        }

        // replace_s is longer: "int main(" (10) -> "int orig_main(" (14): +4
        // inc_replace is shorter: "#include \"../ch32fun/ch32fun.h\"" (29) -> "#include \"ch32fun.h\"" (19): -10
        const delta_main: isize = @as(isize, @intCast(replace_s.len)) - @as(isize, @intCast(search.len));
        const delta_inc: isize = @as(isize, @intCast(inc_replace.len)) - @as(isize, @intCast(inc_search.len));
        const extra: isize = @as(isize, @intCast(count)) * delta_main + @as(isize, @intCast(inc_count)) * delta_inc;
        const new_len = @as(usize, @intCast(@as(isize, @intCast(content.len)) + extra));
        const patched = try b.allocator.alloc(u8, new_len);

        // Perform replacements.
        {
            var src_idx: usize = 0;
            var dst_idx: usize = 0;

            // Helper: replace next occurrence of any of the two search strings.
            while (true) {
                const main_pos = std.mem.indexOf(u8, content[src_idx..], search);
                const inc_pos = std.mem.indexOf(u8, content[src_idx..], inc_search);

                const do_main = main_pos != null;
                const do_inc = inc_pos != null;

                if (!do_main and !do_inc) break;

                const use_main = if (do_main and do_inc) main_pos.? < inc_pos.? else do_main;

                if (use_main) {
                    const pos = main_pos.?;
                    @memcpy(patched[dst_idx..][0..pos], content[src_idx..][0..pos]);
                    dst_idx += pos;
                    src_idx += pos;
                    @memcpy(patched[dst_idx..][0..replace_s.len], replace_s);
                    dst_idx += replace_s.len;
                    src_idx += search.len;
                } else {
                    const pos = inc_pos.?;
                    @memcpy(patched[dst_idx..][0..pos], content[src_idx..][0..pos]);
                    dst_idx += pos;
                    src_idx += pos;
                    @memcpy(patched[dst_idx..][0..inc_replace.len], inc_replace);
                    dst_idx += inc_replace.len;
                    src_idx += inc_search.len;
                }
            }
            const remaining = content.len - src_idx;
            @memcpy(patched[dst_idx..][0..remaining], content[src_idx..]);
        }

        const dest_file = try std.Io.Dir.createFile(cwd, io, patched_rel, .{ .truncate = true });
        defer std.Io.File.close(dest_file, io);

        try std.Io.File.writeStreamingAll(dest_file, io, patched);
    }

    ocd.root_module.addIncludePath(minichlink_root_path);
    ocd.root_module.addIncludePath(b.path("src"));
    // Add include path so that the patched file can find "ch32fun.h"
    // (the original include "#include "../ch32fun/ch32fun.h"" is rewritten
    // to "#include "ch32fun.h"" during the patching step above).
    ocd.root_module.addIncludePath(minichlink_dep.path("ch32fun"));
    ocd.root_module.addCSourceFile(.{ .file = b.path(patched_rel) });

    // Same macros as createMinichlink — minichlink-patched.c (a copy of minichlink.c)
    // needs these to compile correctly.
    ocd.root_module.addCMacro("MINICHLINK", "1");
    ocd.root_module.addCMacro("CH32V003", "1");
    ocd.root_module.addCMacro("__DELAY_TINY_DEFINED__", "1");
    switch (target.result.os.tag) {
        .macos => {
            ocd.root_module.addCMacro("__MACOSX__", "1");
        },
        else => {},
    }

    try addPaths(ocd.root_module, target);

    b.getInstallStep().dependOn(&b.addInstallArtifact(ocd, .{}).step);
    {
        const install_dir = try std.fs.path.join(b.allocator, &.{ "share", "openocd", "scripts", "board" });
        b.getInstallStep().dependOn(
            &b.addInstallFileWithDir(
                b.addWriteFiles().add("wch-riscv.cfg", ""),
                .{ .custom = install_dir },
                "wch-riscv.cfg",
            ).step,
        );
    }

    return ocd;
}

pub fn addPaths(mod: *std.Build.Module, target: std.Build.ResolvedTarget) !void {
    const b = mod.owner;
    const graph = b.graph;
    const io = graph.io;

    const paths = try std.zig.system.NativePaths.detect(b.allocator, io, &target.result, &b.graph.environ_map);

    for (paths.lib_dirs.items) |item| {
        Io.Dir.cwd().access(io, item, .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };

        mod.addLibraryPath(.{ .cwd_relative = item });
    }
    for (paths.include_dirs.items) |item| {
        Io.Dir.cwd().access(io, item, .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };

        mod.addSystemIncludePath(.{ .cwd_relative = item });
    }
    for (paths.framework_dirs.items) |item| {
        Io.Dir.cwd().access(io, item, .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };

        mod.addSystemFrameworkPath(.{ .cwd_relative = item });
    }
    for (paths.rpaths.items) |item| {
        Io.Dir.cwd().access(io, item, .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };

        mod.addRPath(.{ .cwd_relative = item });
    }
}
