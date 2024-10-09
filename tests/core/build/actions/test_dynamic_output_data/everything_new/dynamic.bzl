# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

def _basic_f_impl(actions: AnalysisActions, artifact_values, dynamic_values, outputs, arg):
    _unused = dynamic_values  # buildifier: disable=unused-variable
    src = artifact_values[arg.input].read_string()
    assert_eq(src, "42")
    actions.write(outputs[arg.output], src)
    return []

_basic_f = dynamic_actions(impl = _basic_f_impl)

# Basic test
def _basic(ctx: AnalysisContext) -> list[Provider]:
    input = ctx.actions.write("input", str(7 * 6))
    output = ctx.actions.declare_output("output")

    ctx.actions.dynamic_output_new(_basic_f(
        artifact_values = [input],
        outputs = [output.as_output()],
        arg = struct(input = input, output = output),
    ))
    return [DefaultInfo(default_output = output)]

def _two_f_impl(actions: AnalysisActions, artifact_values, dynamic_values, outputs, arg):
    _unused = dynamic_values  # buildifier: disable=unused-variable
    src = artifact_values[arg.input].read_string()
    actions.write(outputs[arg.output1], "output1_" + src)
    actions.write(outputs[arg.output2], "output2_" + src)
    return []

_two_f = dynamic_actions(impl = _two_f_impl)

# Produce two output files
def _two(ctx: AnalysisContext) -> list[Provider]:
    input = ctx.actions.write("input", "test")
    output1 = ctx.actions.declare_output("output1")
    output2 = ctx.actions.declare_output("output2")

    ctx.actions.dynamic_output_new(_two_f(
        artifact_values = [input],
        outputs = [output1.as_output(), output2.as_output()],
        arg = struct(input = input, output1 = output1, output2 = output2),
    ))
    sub_targets = {
        "output1": [DefaultInfo(default_output = output1)],
        "output2": [DefaultInfo(default_output = output2)],
    }
    return [DefaultInfo(
        sub_targets = sub_targets,
    )]

def _nested_f_impl(actions: AnalysisActions, artifact_values, dynamic_values, outputs, arg):
    _unused = dynamic_values  # buildifier: disable=unused-variable
    src = artifact_values[arg.input].read_string()
    output1 = actions.declare_output("output1")
    output2 = actions.declare_output("output2")
    actions.write(output1, "output1_" + src)
    actions.write(output2, "output2_" + src)
    symlink_tree = {
        "output1": output1,
        "output2": output2,
    }
    nested_output = actions.declare_output("nested_output")

    actions.dynamic_output_new(_nested_f2(
        artifact_values = [output1, output2],
        outputs = [nested_output.as_output()],
        arg = struct(output1 = output1, output2 = output2, nested_output = nested_output),
    ))

    symlink_tree["nested_output"] = nested_output
    actions.symlinked_dir(outputs[arg.symlinked_dir], symlink_tree)
    return []

def _nested_f2_impl(actions: AnalysisActions, artifact_values, dynamic_values, outputs, arg):
    _unused = dynamic_values  # buildifier: disable=unused-variable
    nested_src1 = artifact_values[arg.output1].read_string()
    nested_src2 = artifact_values[arg.output2].read_string()
    actions.write(outputs[arg.nested_output], [nested_src1, nested_src2])
    return []

_nested_f = dynamic_actions(impl = _nested_f_impl)
_nested_f2 = dynamic_actions(impl = _nested_f2_impl)

# Nested dynamic outputs
def _nested(ctx: AnalysisContext) -> list[Provider]:
    input = ctx.actions.write("input", "test")
    symlinked_dir = ctx.actions.declare_output("output1_symlinked_dir", dir = True)

    ctx.actions.dynamic_output_new(_nested_f(
        artifact_values = [input],
        outputs = [symlinked_dir.as_output()],
        arg = struct(input = input, symlinked_dir = symlinked_dir),
    ))
    return [DefaultInfo(default_output = symlinked_dir)]

def _command_f_impl(actions: AnalysisActions, artifact_values, dynamic_values, outputs, arg):
    _unused = dynamic_values  # buildifier: disable=unused-variable
    src = artifact_values[arg.hello].read_string().strip()
    assert_eq(src, "Hello")
    actions.run(
        cmd_args(["python3", arg.script, src, outputs[arg.world].as_output(), outputs[arg.universe].as_output()]),
        category = "dynamic_check",
    )
    return []

_command_f = dynamic_actions(impl = _command_f_impl)

# Produce two output files, using a command
def _command(ctx: AnalysisContext) -> list[Provider]:
    hello = ctx.actions.declare_output("hello.txt")
    write_hello = ctx.actions.write(
        "hello.py",
        [
            cmd_args(["with open(r'", hello, "', 'w') as f:"], delimiter = ""),
            "  f.write('Hello\\n')",
        ],
    )
    ctx.actions.run(cmd_args(["python3", write_hello], hidden = hello.as_output()), category = "test_category")

    world = ctx.actions.declare_output("world")
    universe = ctx.actions.declare_output("universe")

    script = ctx.actions.write(
        "script.py",
        [
            "import sys",
            "with open(sys.argv[2], 'w') as f:",
            "  f.write(sys.argv[1] + ' world\\n')",
            "with open(sys.argv[3], 'w') as f:",
            "  f.write(sys.argv[1] + ' universe\\n')",
        ],
    )

    ctx.actions.dynamic_output_new(_command_f(
        artifact_values = [hello],
        outputs = [world.as_output(), universe.as_output()],
        arg = struct(hello = hello, world = world, universe = universe, script = script),
    ))
    return [DefaultInfo(default_output = world, other_outputs = [universe])]

def _create_f_impl(actions: AnalysisActions, artifact_values, dynamic_values, outputs, arg):
    _unused = dynamic_values  # buildifier: disable=unused-variable
    src = artifact_values[arg.input].read_string()
    new_file = actions.write("new_file", src)
    actions.copy_file(outputs[arg.output], new_file)
    return []

_create_f = dynamic_actions(impl = _create_f_impl)

# Create a fresh output inside the dynamic
def _create(ctx: AnalysisContext) -> list[Provider]:
    input = ctx.actions.write("input", str(7 * 6))
    output = ctx.actions.declare_output("output")

    ctx.actions.dynamic_output_new(_create_f(
        artifact_values = [input],
        outputs = [output.as_output()],
        arg = struct(input = input, output = output),
    ))
    return [DefaultInfo(default_output = output)]

def _create_duplicate_f_impl(actions: AnalysisActions, artifact_values, dynamic_values, outputs, arg):
    _unused = dynamic_values  # buildifier: disable=unused-variable

    src = artifact_values[arg.input].read_string()

    # Deliberately reuse the names input/output
    new_output = actions.write("output", src)

    # We can't have two actions that do copy with "output" as the name
    # since then we get conflicting identifiers for category `copy`.
    # I.e. the two copy() actions below can't end "output" and outputs[output].
    # We could allow copy to take an explicit identifier, but this is a corner
    # case and I don't think its a good idea to reuse names heavily anyway.
    new_input = actions.copy_file("input", new_output)
    actions.copy_file(outputs[arg.output], new_input)
    return []

_create_duplicate_f = dynamic_actions(impl = _create_duplicate_f_impl)

# Create a fresh output inside the dynamic, which clashes
def _create_duplicate(ctx: AnalysisContext) -> list[Provider]:
    input = ctx.actions.write("input", str(7 * 6))
    output = ctx.actions.declare_output("output")

    ctx.actions.dynamic_output_new(_create_duplicate_f(
        artifact_values = [input],
        outputs = [output.as_output()],
        arg = struct(input = input, output = output),
    ))
    return [DefaultInfo(default_output = output)]

def _impl(ctx: AnalysisContext) -> list[Provider]:
    if ctx.label.name == "basic":
        return _basic(ctx)
    elif ctx.label.name == "two":
        return _two(ctx)
    elif ctx.label.name == "command":
        return _command(ctx)
    elif ctx.label.name == "create":
        return _create(ctx)
    elif ctx.label.name == "create_duplicate":
        return _create_duplicate(ctx)
    elif ctx.label.name == "nested":
        return _nested(ctx)
    else:
        fail("Unknown test: " + ctx.label.name)

dynamic_check = rule(impl = _impl, attrs = {})

def assert_eq(a, b):
    if a != b:
        fail("Expected equal, but got", a, b)

def _assert_output_value_impl(ctx: AnalysisContext) -> list[Provider]:
    produced = ctx.attrs.dep[DefaultInfo].default_outputs[0]
    value = ctx.actions.write("value", ctx.attrs.value)
    output = ctx.actions.declare_output("output")
    run = ctx.actions.write(
        "run.py",
        [
            "import sys",
            "with open(sys.argv[1]) as f:",
            "  value_content = f.read()",
            "with open(sys.argv[2]) as f:",
            "  produced_content = f.read()",
            "if value_content != produced_content:",
            "  print('Content does not match! Expected:', value_content, 'Got:', produced_content)",
            "  sys.exit(1)",
            "with open(sys.argv[3], 'w') as f:",
            "  f.write('Success\\n')",
        ],
    )
    ctx.actions.run(cmd_args(["python3", run, value, produced, output.as_output()]), category = "test_category")
    return [DefaultInfo(default_output = output)]

assert_output_value = rule(impl = _assert_output_value_impl, attrs = {
    "dep": attrs.dep(),
    "value": attrs.string(),
})

def _proto_genrule_impl(ctx):
    out_artifact = ctx.actions.declare_output(ctx.attrs.out)
    env_vars = {
        "OUT": cmd_args(out_artifact.as_output()),
    }
    ctx.actions.run(
        cmd_args(["python3", "-c", ctx.attrs.python]),
        env = env_vars,
        category = "genrule",
    )
    return [DefaultInfo(default_output = out_artifact)]

proto_genrule = rule(
    impl = _proto_genrule_impl,
    attrs = {
        "out": attrs.string(),
        "python": attrs.option(attrs.arg(), default = None),
    },
)