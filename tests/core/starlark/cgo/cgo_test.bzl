load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@io_bazel_rules_go//go:def.bzl", "go_binary", "go_cross_binary", "go_library", "go_test")
load("@io_bazel_rules_go//go/private:providers.bzl", "GoArchive", "GoInfo")
load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "feature", "tool_path")  # buildifier: disable=deprecated-function
load("@rules_cc//cc:defs.bzl", "cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")
load("@with_cfg.bzl", "with_cfg")

pure_on_go_library, _pure_on_go_library_internal = (
    with_cfg(
        go_library,
        extra_providers = [GoArchive, GoInfo],
    )
        .set(Label("@io_bazel_rules_go//go/config:pure"), "on")
        .build()
)

pure_off_go_library, _pure_off_go_library_internal = (
    with_cfg(
        go_library,
        extra_providers = [GoArchive, GoInfo],
    )
        .set(Label("@io_bazel_rules_go//go/config:pure"), "off")
        .build()
)

def _test_cc_config_impl(ctx):
    tool_paths = [
        tool_path(name = name, path = "/bin/false")
        for name in [
            "ar",
            "cpp",
            "dwp",
            "gcc",
            "gcov",
            "ld",
            "nm",
            "objcopy",
            "objdump",
            "strip",
        ]
    ]

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "runtime-libs-test-toolchain",
        host_system_name = "local",
        target_system_name = "local",
        target_cpu = "local",
        target_libc = "local",
        compiler = "gcc",
        abi_version = "local",
        abi_libc_version = "local",
        tool_paths = tool_paths,
        features = [
            feature(name = "static_link_cpp_runtimes", enabled = True),
        ],
    )

test_cc_config = rule(
    implementation = _test_cc_config_impl,
    provides = [CcToolchainConfigInfo],
)

def _missing_cc_toolchain_explicit_pure_off_test(ctx):
    env = analysistest.begin(ctx)

    asserts.expect_failure(env, "has pure explicitly set to off, but no C++ toolchain could be found for its platform")

    return analysistest.end(env)

missing_cc_toolchain_explicit_pure_off_test = analysistest.make(
    _missing_cc_toolchain_explicit_pure_off_test,
    expect_failure = True,
    config_settings = {
        "//command_line_option:extra_toolchains": str(Label("//tests/core/starlark/cgo:fake_go_toolchain")),
    },
)

def _pure_constraint_failure_test(ctx):
    env = analysistest.begin(ctx)

    asserts.expect_failure(env, "The go_library pure attribute is a constraint")

    return analysistest.end(env)

pure_constraint_failure_test = analysistest.make(
    _pure_constraint_failure_test,
    expect_failure = True,
)

pure_constraint_failure_in_auto_test = analysistest.make(
    _pure_constraint_failure_test,
    expect_failure = True,
    config_settings = {
        "//command_line_option:extra_toolchains": str(Label("//tests/core/starlark/cgo:runtime_libs_test_cc_toolchain")),
        str(Label("@io_bazel_rules_go//go/config:pure")): "auto",
    },
)

pure_constraint_failure_in_on_test = analysistest.make(
    _pure_constraint_failure_test,
    expect_failure = True,
    config_settings = {
        str(Label("@io_bazel_rules_go//go/config:pure")): "on",
    },
)

def _inconsistent_pure_transition_test(ctx):
    env = analysistest.begin(ctx)

    asserts.expect_failure(env, "Archive mode does not match")

    return analysistest.end(env)

inconsistent_pure_transition_from_auto_test = analysistest.make(
    _inconsistent_pure_transition_test,
    expect_failure = True,
    config_settings = {
        "//command_line_option:extra_toolchains": str(Label("//tests/core/starlark/cgo:runtime_libs_test_cc_toolchain")),
        str(Label("@io_bazel_rules_go//go/config:pure")): "auto",
    },
)

inconsistent_pure_transition_from_on_test = analysistest.make(
    _inconsistent_pure_transition_test,
    expect_failure = True,
    config_settings = {
        str(Label("@io_bazel_rules_go//go/config:pure")): "on",
    },
)

def _pure_mode_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    asserts.equals(env, ctx.attr.expected_pure, target[GoInfo].mode.pure)

    return analysistest.end(env)

_pure_mode_test_attrs = {
    "expected_pure": attr.bool(mandatory = True),
}

pure_auto_with_cc_mode_test = analysistest.make(
    _pure_mode_test_impl,
    attrs = _pure_mode_test_attrs,
    config_settings = {
        "//command_line_option:extra_toolchains": str(Label("//tests/core/starlark/cgo:runtime_libs_test_cc_toolchain")),
        str(Label("@io_bazel_rules_go//go/config:pure")): "auto",
    },
)

pure_auto_without_cc_mode_test = analysistest.make(
    _pure_mode_test_impl,
    attrs = _pure_mode_test_attrs,
    config_settings = {
        "//command_line_option:extra_toolchains": str(Label("//tests/core/starlark/cgo:fake_go_toolchain")),
        "//command_line_option:platforms": str(Label("//tests/core/starlark/cgo:platform_has_no_cc_toolchain")),
        str(Label("@io_bazel_rules_go//go/config:pure")): "auto",
    },
)

pure_on_mode_test = analysistest.make(
    _pure_mode_test_impl,
    attrs = _pure_mode_test_attrs,
    config_settings = {
        str(Label("@io_bazel_rules_go//go/config:pure")): "on",
    },
)

def _runtime_lib_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    link_actions = [action for action in actions if action.mnemonic == "GoLink"]
    asserts.equals(env, 1, len(link_actions), "expected exactly one GoLink action")

    inputs = link_actions[0].inputs.to_list()
    for expected in ctx.attr.expected_inputs:
        matching_inputs = [input for input in inputs if input.path.endswith("/" + expected)]
        asserts.equals(
            env,
            ctx.attr.expected_input_count,
            len(matching_inputs),
            "expected {} '{}' inputs, got '{}': '{}'".format(
                ctx.attr.expected_input_count,
                expected,
                matching_inputs,
                inputs,
            ),
        )
    for unexpected in ctx.attr.unexpected_inputs:
        asserts.false(
            env,
            any([input.path.endswith("/" + unexpected) for input in inputs]),
            "did not expect '{}' to be in inputs: '{}'".format(unexpected, inputs),
        )

    compile_actions = [action for action in actions if action.mnemonic == "GoCompilePkg"]
    asserts.equals(env, 1, len(compile_actions), "expected exactly one GoCompilePkg action")
    compile_argv = " ".join(compile_actions[0].argv)
    for expected in ctx.attr.expected_linkopts:
        asserts.true(
            env,
            expected in compile_argv,
            "expected '{}' to be in compile argv: '{}'".format(expected, compile_argv),
        )
    for unexpected in ctx.attr.unexpected_linkopts:
        asserts.false(
            env,
            unexpected in compile_argv,
            "did not expect '{}' to be in compile argv: '{}'".format(unexpected, compile_argv),
        )

    return analysistest.end(env)

runtime_lib_inputs_test = analysistest.make(
    _runtime_lib_inputs_test_impl,
    attrs = {
        "expected_input_count": attr.int(default = 1),
        "expected_inputs": attr.string_list(),
        "expected_linkopts": attr.string_list(),
        "unexpected_inputs": attr.string_list(),
        "unexpected_linkopts": attr.string_list(),
    },
    config_settings = {
        "//command_line_option:extra_toolchains": str(Label("//tests/core/starlark/cgo:runtime_libs_test_cc_toolchain")),
    },
)

def cgo_test_suite():
    native.genrule(
        name = "configured_dummy_runtime_lib",
        srcs = [":dummy.a"],
        outs = ["configured_dummy.a"],
        cmd = "cp $< $@",
        cmd_bat = "copy /Y $< $@",
    )

    test_cc_config(
        name = "runtime_libs_test_cc_toolchain_config",
    )

    cc_toolchain(
        name = "runtime_libs_test_cc_toolchain_impl",
        all_files = ":empty",
        compiler_files = ":empty",
        dwp_files = ":empty",
        dynamic_runtime_lib = ":dummy.so",
        linker_files = ":empty",
        objcopy_files = ":empty",
        static_runtime_lib = ":configured_dummy_runtime_lib",
        strip_files = ":empty",
        supports_param_files = 0,
        toolchain_config = ":runtime_libs_test_cc_toolchain_config",
        toolchain_identifier = "runtime-libs-test-toolchain",
    )

    native.toolchain(
        name = "runtime_libs_test_cc_toolchain",
        toolchain = ":runtime_libs_test_cc_toolchain_impl",
        toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    )

    go_binary(
        name = "cross_impure",
        srcs = ["main.go"],
        pure = "off",
        tags = ["manual"],
    )

    go_cross_binary(
        name = "go_cross_impure_cgo",
        platform = ":platform_has_no_cc_toolchain",
        target = ":cross_impure",
        tags = ["manual"],
    )

    missing_cc_toolchain_explicit_pure_off_test(
        name = "missing_cc_toolchain_explicit_pure_off_test",
        target_under_test = ":go_cross_impure_cgo",
    )

    go_library(
        name = "cross_impure_library",
        srcs = ["main.go"],
        importpath = "example.com/cross_impure_library",
        pure = "off",
        tags = ["manual"],
    )

    go_binary(
        name = "cross_auto_impure_consumer",
        srcs = ["main.go"],
        deps = [":cross_impure_library"],
        tags = ["manual"],
    )

    go_cross_binary(
        name = "go_cross_transitive_impure_cgo",
        platform = ":platform_has_no_cc_toolchain",
        target = ":cross_auto_impure_consumer",
        tags = ["manual"],
    )

    missing_cc_toolchain_explicit_pure_off_test(
        name = "missing_cc_toolchain_transitive_pure_off_test",
        target_under_test = ":go_cross_transitive_impure_cgo",
    )

    go_library(
        name = "pure_off_library",
        srcs = ["main.go"],
        importpath = "example.com/pure_off_library",
        pure = "off",
        tags = ["manual"],
    )

    go_library(
        name = "normal_library",
        srcs = ["main.go"],
        importpath = "example.com/normal_library",
        tags = ["manual"],
    )

    go_library(
        name = "pure_on_library",
        srcs = ["main.go"],
        importpath = "example.com/pure_on_library",
        pure = "on",
        tags = ["manual"],
    )

    go_library(
        name = "pure_off_transitive_library",
        srcs = ["main.go"],
        deps = [":pure_off_library"],
        importpath = "example.com/pure_off_transitive_library",
        tags = ["manual"],
    )

    dependency_shapes = [
        ("direct", [":pure_off_library"]),
        ("mixed", [":normal_library", ":pure_off_transitive_library"]),
        ("transitive", [":pure_off_transitive_library"]),
    ]
    for shape, deps in dependency_shapes:
        go_binary(
            name = "pure_on_binary_" + shape,
            srcs = ["main.go"],
            deps = deps,
            pure = "on",
            tags = ["manual"],
        )
        go_test(
            name = "pure_on_test_" + shape,
            srcs = ["main.go"],
            deps = deps,
            pure = "on",
            tags = ["manual"],
        )

    go_binary(
        name = "pure_on_binary_embed",
        embed = [":pure_off_library"],
        pure = "on",
        tags = ["manual"],
    )
    go_test(
        name = "pure_on_test_embed",
        embed = [":pure_off_library"],
        pure = "on",
        tags = ["manual"],
    )

    pure_on_failure_targets = [
        "pure_on_{}_{}".format(rule_kind, shape)
        for rule_kind in ["binary", "test"]
        for shape in ["direct", "embed", "mixed", "transitive"]
    ]
    for target_name in pure_on_failure_targets:
        pure_constraint_failure_test(
            name = target_name + "_test",
            target_under_test = ":" + target_name,
        )

    # Explicit library modes are constraints on the graph-wide configuration,
    # not transitions. Auto keeps the legacy behavior: impure when a C++
    # toolchain is available, pure otherwise.
    pure_constraint_failure_in_auto_test(
        name = "pure_on_library_in_auto_mode_test",
        target_under_test = ":pure_on_library",
    )

    pure_constraint_failure_in_on_test(
        name = "pure_off_library_in_on_mode_test",
        target_under_test = ":pure_off_library",
    )

    go_binary(
        name = "incompatible_library_constraints",
        srcs = ["main.go"],
        deps = [
            ":pure_off_library",
            ":pure_on_library",
        ],
        tags = ["manual"],
    )

    pure_constraint_failure_in_auto_test(
        name = "incompatible_library_constraints_in_auto_mode_test",
        target_under_test = ":incompatible_library_constraints",
    )

    pure_constraint_failure_in_on_test(
        name = "incompatible_library_constraints_in_on_mode_test",
        target_under_test = ":incompatible_library_constraints",
    )

    pure_auto_with_cc_mode_test(
        name = "auto_library_with_cc_is_impure_test",
        expected_pure = False,
        target_under_test = ":normal_library",
    )

    pure_auto_with_cc_mode_test(
        name = "pure_off_library_matches_auto_impure_test",
        expected_pure = False,
        target_under_test = ":pure_off_library",
    )

    pure_auto_without_cc_mode_test(
        name = "auto_library_without_cc_is_pure_test",
        expected_pure = True,
        target_under_test = ":normal_library",
    )

    pure_on_mode_test(
        name = "auto_library_in_on_mode_is_pure_test",
        expected_pure = True,
        target_under_test = ":normal_library",
    )

    pure_on_mode_test(
        name = "pure_on_library_matches_on_mode_test",
        expected_pure = True,
        target_under_test = ":pure_on_library",
    )

    # The cgo build constraint affects these sources even though the library
    # does not set cgo = True and has no C dependencies.
    go_library(
        name = "pure_transition_leaf",
        srcs = [
            "pure_transition_leaf_cgo.go",
            "pure_transition_leaf_pure.go",
        ],
        importpath = "example.com/pure_transition_leaf",
        tags = ["manual"],
    )

    pure_on_go_library(
        name = "pure_on_transitioned_intermediate",
        srcs = ["pure_transition_intermediate.go"],
        deps = [":pure_transition_leaf"],
        importpath = "example.com/pure_on_transitioned_intermediate",
        pure = "on",
        tags = ["manual"],
    )

    pure_off_go_library(
        name = "pure_off_transitioned_intermediate",
        srcs = ["pure_transition_intermediate.go"],
        deps = [":pure_transition_leaf"],
        importpath = "example.com/pure_off_transitioned_intermediate",
        pure = "off",
        tags = ["manual"],
    )

    pure_transition_failure_tests = []
    for rule_kind, rule in [("binary", go_binary), ("test", go_test)]:
        for consumer_mode, dependency, analysis_test in [
            ("auto", ":pure_on_transitioned_intermediate", inconsistent_pure_transition_from_auto_test),
            ("on", ":pure_off_transitioned_intermediate", inconsistent_pure_transition_from_on_test),
        ]:
            target_name = "pure_{}_{}_with_transitioned_library".format(consumer_mode, rule_kind)
            rule(
                name = target_name,
                srcs = ["main.go"],
                deps = [dependency],
                tags = ["manual"],
            )
            analysis_test(
                name = target_name + "_test",
                target_under_test = ":" + target_name,
            )
            pure_transition_failure_tests.append(target_name + "_test")

    go_binary(
        name = "runtime_libs_static_binary",
        srcs = [
            "runtime_libs.cc",
            "runtime_libs.go",
        ],
        cgo = True,
        pure = "off",
        tags = ["manual"],
    )

    runtime_lib_inputs_test(
        name = "static_runtime_lib_inputs_test",
        expected_inputs = ["configured_dummy.a"],
        expected_linkopts = ["configured_dummy.a"],
        target_under_test = ":runtime_libs_static_binary",
        unexpected_inputs = ["dummy.so"],
        unexpected_linkopts = ["dummy.so"],
    )

    go_binary(
        name = "stdlib_runtime_lib_inputs_binary",
        srcs = [
            "runtime_libs.cc",
            "runtime_libs.go",
        ],
        cgo = True,
        # go_stdlib_transition removes tags that do not affect the standard
        # library, so this target and its stdlib dependency use different
        # configurations of the generated C++ runtime archive above.
        gotags = ["not_a_stdlib_tag"],
        pure = "off",
        tags = ["manual"],
    )

    runtime_lib_inputs_test(
        name = "stdlib_runtime_lib_inputs_test",
        expected_input_count = 2,
        expected_inputs = ["configured_dummy.a"],
        target_under_test = ":stdlib_runtime_lib_inputs_binary",
    )

    go_binary(
        name = "runtime_libs_dynamic_binary",
        srcs = [
            "runtime_libs.cc",
            "runtime_libs.go",
        ],
        cgo = True,
        linkmode = "c-shared",
        pure = "off",
        tags = ["manual"],
    )

    runtime_lib_inputs_test(
        name = "dynamic_runtime_lib_inputs_test",
        expected_input_count = 2,
        expected_inputs = ["dummy.so"],
        expected_linkopts = ["dummy.so"],
        target_under_test = ":runtime_libs_dynamic_binary",
        unexpected_inputs = ["dummy.a"],
        unexpected_linkopts = ["dummy.a"],
    )

    """Creates the test targets and test suite for cgo.bzl tests."""
    native.test_suite(
        name = "cgo_tests",
        tests = [
            ":auto_library_in_on_mode_is_pure_test",
            ":auto_library_with_cc_is_impure_test",
            ":auto_library_without_cc_is_pure_test",
            ":dynamic_runtime_lib_inputs_test",
            ":incompatible_library_constraints_in_auto_mode_test",
            ":incompatible_library_constraints_in_on_mode_test",
            ":missing_cc_toolchain_explicit_pure_off_test",
            ":missing_cc_toolchain_transitive_pure_off_test",
            ":pure_off_library_in_on_mode_test",
            ":pure_off_library_matches_auto_impure_test",
            ":pure_on_library_in_auto_mode_test",
            ":pure_on_library_matches_on_mode_test",
            ":static_runtime_lib_inputs_test",
            ":stdlib_runtime_lib_inputs_test",
        ] + [
            ":" + test_name
            for test_name in [target_name + "_test" for target_name in pure_on_failure_targets] + pure_transition_failure_tests
        ],
    )
