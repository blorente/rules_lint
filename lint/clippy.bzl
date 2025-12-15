"""API for declaring a clippy lint aspect that visits rust_{binary|library|test} rules.

Typical usage:

First, install `rules_rust` into your repository, on at least version 0.67.0: https://bazelbuild.github.io/rules_rust/.
For instance:

```starlark
// MODULE.bazel
bazel_dep(name = "rules_rust", version = "0.67.0")

rust = use_extension("@rules_rust//rust:extensions.bzl", "rust")
rust.toolchain(
    edition = "2021",
    versions = ["1.75.0"],
)
use_repo(rust, "rust_toolchains")

register_toolchains(
    "@rust_toolchains//:all",
)
```

This will install a rust toolchain, which includes rustc and clippy.
Please ignore the `rules_rust` instructions around clippy, as `rules_lint` ignores all `rules_rust` flags.

Next, create a clippy configuration file. We'll assume you've created it in `//:.clippy.toml`.
The file name must be suffixed by either `.clippy.toml` or `clippy.toml`, otherwise clippy will silently ignore it.

Finally, create the linter aspect, typically in `tools/lint/linters.bzl`:

```starlark
load("@aspect_rules_lint//lint:clippy.bzl", "lint_clippy_aspect")

clippy = lint_clippy_aspect(
    config = Label("//:.clippy.toml"),
)
```

Now your targets will be linted with clippy.
If you wish a target to be excluded from linting, you can give them the `noclippy` tag.

Please watch issue https://github.com/aspect-build/rules_lint/issues/385 for updates on this behavior.
"""

load("@rules_rust//rust:defs.bzl", "rust_clippy_action", "rust_common")
load("//lint/private:lint_aspect.bzl", "LintOptionsInfo", "OPTIONAL_SARIF_PARSER_TOOLCHAIN", "OUTFILE_FORMAT", "filter_srcs", "noop_lint_action", "output_files", "parse_to_sarif_action", "patch_and_output_files", "patch_file", "should_visit")

_MNEMONIC = "AspectRulesLintClippy"

def _get_common_clippy_kwargs(ctx, clippy_bin, crate_info, extra_options):
    return {
        "ctx": ctx,
        "clippy_executable": clippy_bin,
        "process_wrapper": ctx.executable._process_wrapper,
        "crate_info": crate_info,
        "config": ctx.file._config_file,
        "forward_clippy_exit_code": False,  # We don't want to crash the process if there are clippy errors, we just want to report them.
        "cap_at_warnings": False,
        "extra_clippy_flags": extra_options,
    }

def _run_clippy_fix(
        ctx,
        srcs,
        clippy_bin,
        crate_info,
        output_set,
        patch,
        extra_options,
        **kwargs):
    extra_options = extra_options + ["--fix"]

    all_kwargs = _get_common_clippy_kwargs(ctx, clippy_bin, crate_info, extra_options)
    all_kwargs.update(kwargs)
    print("BL: _run_clippy_fix(kwargs={})".format(all_kwargs))

    action = rust_clippy_action.create_action(
        #        output = output_set.out,
        #        exit_code_file = output_set.exit_code,
        **all_kwargs
    )

    print("BL: _run_clippy_fix(action={})".format(action))

    patch_cfg_argfile = ctx.actions.declare_file("_{}.patch_cfg.args".format(ctx.label.name))
    ctx.actions.write(
        output = patch_cfg_argfile,
        content = action.arguments[0],
    )

    patch_cfg = ctx.actions.declare_file("_{}.patch_cfg".format(ctx.label.name))
    args = ["--fix"]

    ctx.actions.write(
        output = patch_cfg,
        content = json.encode({
            "linter": action.executable.path,
            "args": "@{}".format(patch_cfg_argfile.path),
            "env": dict(action.env, **{"BAZEL_BINDIR": ctx.bin_dir.path}),
            "files_to_diff": [s.path for s in srcs],
            "output": patch.path,
        }),
    )

    outputs = [patch, output_set.exit_code, output_set.out] + action.outputs
    print("BL: _run_clippy_fix::patcher_action(\n\n  outputs={},\n  tools={},\n  executable={},\n  toolchain={}\n\n)".format(
        outputs,
        action.tools,
        action.executable,
        action.toolchain,
    ))

    ctx.actions.run(
        inputs = depset([patch_cfg, patch_cfg_argfile], transitive = [action.inputs]),
        outputs = outputs,
        executable = ctx.executable._patcher,
        arguments = [patch_cfg.path],
        env = dict(action.env, **{
            "BAZEL_BINDIR": ".",
            "JS_BINARY__EXIT_CODE_OUTPUT_FILE": output_set.exit_code.path,
            "JS_BINARY__STDOUT_OUTPUT_FILE": output_set.out.path,
            #            "JS_BINARY__SILENT_ON_SUCCESS": "0",
            "JS_BINARY__LOG_DEBUG": "true",
        }),
        tools = action.tools + [action.executable],
        toolchain = action.toolchain,
        mnemonic = _MNEMONIC,
        progress_message = "Linting %{label} with Clippy",
    )

def _run_clippy_lint(ctx, clippy_bin, crate_info, output_set, extra_options, **kwargs):
    all_kwargs = _get_common_clippy_kwargs(ctx, clippy_bin, crate_info, extra_options)
    all_kwargs.update(kwargs)
    print("BL: _run_clippy_lint(kwargs={})".format(all_kwargs))
    rust_clippy_action.action(
        output = output_set.out,
        exit_code_file = output_set.exit_code,
        **all_kwargs
    )

# buildifier: disable=function-docstring
def _clippy_aspect_impl(target, ctx):
    if not should_visit(ctx.rule, ctx.attr._rule_kinds):
        return []

    clippy_bin = ctx.toolchains[Label("@rules_rust//rust:toolchain_type")].clippy_driver

    files_to_lint = filter_srcs(ctx.rule)
    if ctx.attr._options[LintOptionsInfo].fix:
        print("WARNING: `fix` is not supported yet for clippy. Please follow https://github.com/aspect-build/rules_lint/issues/385 for updates.")

    if ctx.attr._options[LintOptionsInfo].fix:
        outputs, info = patch_and_output_files(_MNEMONIC, target, ctx)
    else:
        outputs, info = output_files(_MNEMONIC, target, ctx)

    if len(files_to_lint) == 0:
        noop_lint_action(ctx, outputs)
        return [info]

    crate_info = rust_clippy_action.get_clippy_ready_crate_info(target, ctx)
    if not crate_info:
        noop_lint_action(ctx, outputs)
        return [info]

    extra_options = [
        # If we don't pass any clippy options, rules_rust will (rightly) default to -Dwarnings, which turns all warnings into errors.
        # They do this to force Bazel to re-run targets on failures.
        # However, we don't need to do that because we keep track of output files and exit codes separately.
        "-Wwarnings",
    ]

    # FIXME: Implement support for --fix mode. Clippy has a --fix flag, but our patcher doesn't currently support running an action through a macro.
    #        We have to either
    #           (1) modify the patcher so that it can run an action through a macro, or
    #           (2) modify rules_rust so that it gives us a struct with a command line we can run it with the patcher.

    if ctx.attr._options[LintOptionsInfo].fix:
        _run_clippy_fix(
            ctx = ctx,
            srcs = files_to_lint,
            clippy_bin = clippy_bin,
            crate_info = crate_info,
            output_set = outputs.human,
            patch = outputs.patch,
            extra_options = extra_options,
        )
    else:
        _run_clippy_lint(
            ctx = ctx,
            clippy_bin = clippy_bin,
            crate_info = crate_info,
            output_set = outputs.human,
            extra_options = extra_options,
        )

    _run_clippy_lint(
        ctx = ctx,
        clippy_bin = clippy_bin,
        crate_info = crate_info,
        output_set = outputs.machine,
        extra_options = extra_options,
        error_format = "json",
    )

    # FIXME: Rustc only gives us JSON output, which we can't turn into SARIF yet.
    # clippy uses rustc's IO format, which doesn't have a SARIF output mode built in,
    # and they're not planning to add one.
    # We could use clippy-sarif, which seems to be relatively maintained.
    #
    # Refs:
    #  - https://github.com/rust-lang/rust-clippy/issues/8122
    #  - https://github.com/psastras/sarif-rs/tree/main/clippy-sarif
    # parse_to_sarif_action(ctx, _MNEMONIC, raw_machine_report, outputs.machine.out)

    return [info]

DEFAULT_RULE_KINDS = ["rust_binary", "rust_library", "rust_test"]

def lint_clippy_aspect(config, rule_kinds = DEFAULT_RULE_KINDS):
    """A factory function to create a linter aspect.

    The Clippy binary will be read from the Rust toolchain.

    Args:
        config (File): Label of the desired Clippy configuration file to use. Reference: https://doc.rust-lang.org/clippy/configuration.html
        rule_kinds (List[str]): List of rule kinds to lint. Defaults to {default_rule_kinds}.
    """.format(default_rule_kinds = DEFAULT_RULE_KINDS)
    attrs = {
        "_options": attr.label(
            default = "//lint:options",
            providers = [LintOptionsInfo],
        ),
        "_config_file": attr.label(
            default = config,
            allow_single_file = True,
        ),
        "_rule_kinds": attr.string_list(
            default = rule_kinds,
        ),
        "_process_wrapper": attr.label(
            doc = "A process wrapper for running clippy on all platforms",
            default = Label("@rules_rust//util/process_wrapper"),
            executable = True,
            cfg = "exec",
        ),
        "_patcher": attr.label(
            default = "@aspect_rules_lint//lint/private:patcher",
            executable = True,
            cfg = "exec",
        ),
    }
    return aspect(
        fragments = ["cpp"],
        implementation = _clippy_aspect_impl,
        attrs = attrs,
        toolchains = [
            OPTIONAL_SARIF_PARSER_TOOLCHAIN,
            Label("@rules_rust//rust:toolchain_type"),
            "@bazel_tools//tools/cpp:toolchain_type",
        ],
    )
